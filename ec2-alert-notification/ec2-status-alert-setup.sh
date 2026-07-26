#!/bin/bash
# ============================================================================
# EC2 Status Check Alerts — All-in-One Setup Script
# Cloudly DevOps
#
# What this script builds, per AWS account/region it is run in:
#   1. A "raw" internal SNS topic that CloudWatch alarms publish to
#   2. A formatter Lambda that turns a raw alarm into a readable email
#      (Instance Name / Instance ID / System / Instance / Attached-EBS status)
#   3. The "public" SNS topic that actually emails your team (existing topic
#      is reused if ALARM_EMAIL_TOPIC_NAME already exists in this account)
#   4. One CloudWatch alarm per currently-running EC2 instance, watching the
#      aggregate StatusCheckFailed metric (covers 1/3 and 2/3 check failures)
#   5. A second Lambda + EventBridge rule that auto-creates the same alarm
#      for any NEW instance the moment it reaches "running" — no manual step
#      needed for future instances
#
# ALERT SPEED: alarms use period=60s / evaluation-periods=5 / datapoints-to-
# alarm=4 — an "M-out-of-N" model: at least 4 of the last 5 one-minute
# checks must show a failure before an email is sent (roughly 4-5 minutes
# of a genuinely sustained problem). This was raised from a simple
# consecutive-check model after two real incidents where a brief ~1-2
# minute "impaired" blip self-resolved on its own and still triggered an
# email — the M-out-of-N model tolerates one good reading mixed in with
# bad ones, which a strict consecutive-check count cannot. If you need
# faster alerts and can tolerate more false positives from routine
# restarts, lower --evaluation-periods / --datapoints-to-alarm in both
# Step 5 below and the auto-create Lambda code in Step 6 (e.g. 2/2 for
# ~2 minutes, or 1/1 for ~60 seconds — not recommended, see incident above).
#
# EMAIL ACCURACY: the formatter Lambda reads System/Instance/Attached-EBS
# status from CloudWatch metric HISTORY (last 10 minutes), not a live
# describe_instance_status snapshot. This matters because by the time the
# Lambda runs, the instance may have already recovered — a live snapshot
# can come back empty right after recovery, silently showing UNKNOWN in
# the email with no visible error. Reading history instead reflects what
# was actually true during the failure window.
#
# HOW TO USE THIS SCRIPT IN A NEW AWS ACCOUNT:
#   Edit ONLY the "CONFIG — EDIT THESE FOR A NEW ACCOUNT" section below,
#   then run:  bash setup-ec2-status-alerts.sh
#   Everything else (account ID, ARNs, resource names) is resolved
#   automatically at runtime — nothing else in this file needs to change.
# ============================================================================

set -e

# ============================================================================
# CONFIG — EDIT THESE FOR A NEW ACCOUNT
# ============================================================================

# AWS region this account's EC2 fleet runs in.
# Leave blank to auto-detect from the region this CloudShell/CLI session is
# currently using (this matches whichever region tab you have open in
# CloudShell — the same convention already used throughout this project).
# Set explicitly only if you need to override that.
REGION=""

# A human-readable label for this account, shown in every alert email so
# recipients instantly know which client/account an alert is about without
# opening the AWS Console.
#
# Leave blank to auto-detect, tried in this order:
#   1. IAM account alias (aws iam list-account-aliases)
#   2. AWS Organizations account name (if this account is part of an Org
#      and the caller has organizations:DescribeAccount permission)
#   3. Falls back to the raw Account ID if neither exists — never blank,
#      never silently wrong, just less readable.
# Set this explicitly only if you want to override the auto-detected value
# (e.g. the IAM alias is a technical slug, not the actual client name).
ACCOUNT_NAME=""

# Name of the SNS topic your team receives emails from.
# If a topic with this name already exists in this account, it is REUSED
# (its existing subscribers are left untouched). If it does not exist yet,
# it is created fresh and the emails below are subscribed to it.
ALARM_EMAIL_TOPIC_NAME="ec2-status-alerts"

# Only used if ALARM_EMAIL_TOPIC_NAME does not already exist in this account.
# One email per line. Each address will receive an AWS confirmation email
# that MUST be clicked before that address starts receiving alerts.
#
# IMPORTANT: this list is only read the FIRST time a topic is created.
# If the topic already exists (which it will on every re-run after the
# first), this list is ignored entirely — adding a name here and re-running
# the script will NOT subscribe them. To add a new person to an EXISTING
# topic, run this one-off command instead:
#
#   aws sns subscribe --topic-arn <public-topic-arn> --protocol email \
#     --notification-endpoint "newperson@cloudly.io" --region <region>
#
SUBSCRIBER_EMAILS=(
  "sadiq@cloudly.io"
  "bhubon@cloudly.io"
  "zuheb@cloudly.io"
  "shaswata.r@cloudly.io"
  "sifat@cloudly.io"
  "h.miraz@cloudly.io"
)

# ============================================================================
# Everything below this line is generic — no per-account edits needed.
# ============================================================================

RAW_TOPIC_NAME="ec2-status-alerts-raw"
FORMATTER_LAMBDA_NAME="ec2-status-alert-formatter"
FORMATTER_ROLE_NAME="ec2-alert-formatter-role"
AUTOCREATE_LAMBDA_NAME="ec2-auto-create-status-alarms"
AUTOCREATE_ROLE_NAME="ec2-alarm-autocreate-role"
EVENTBRIDGE_RULE_NAME="ec2-new-instance-running-rule"

echo "=================================================================="
echo " STEP 0 — Detecting account"
echo "=================================================================="
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

if [ -z "$REGION" ]; then
  # CloudShell sets AWS_REGION/AWS_DEFAULT_REGION as environment variables
  # for whichever region tab is open — it does NOT write this into the CLI
  # config file, so `aws configure get region` alone is unreliable here.
  REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region)}}"
  if [ -z "$REGION" ]; then
    echo "!! Could not auto-detect a region from any source."
    echo "!! Set REGION explicitly at the top of this script and re-run."
    exit 1
  fi
  echo "Region auto-detected: $REGION"
fi

echo "Account:      $ACCOUNT_ID"
echo "Region:       $REGION"

if [ -z "$ACCOUNT_NAME" ]; then
  ACCOUNT_NAME=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null)
  if [ "$ACCOUNT_NAME" == "None" ] || [ -z "$ACCOUNT_NAME" ]; then
    ACCOUNT_NAME=$(aws organizations describe-account --account-id "$ACCOUNT_ID" \
      --query 'Account.Name' --output text 2>/dev/null)
  fi
  if [ "$ACCOUNT_NAME" == "None" ] || [ -z "$ACCOUNT_NAME" ]; then
    ACCOUNT_NAME="$ACCOUNT_ID"
    echo "Account name: could not auto-detect (no IAM alias or Organizations"
    echo "              access) — falling back to using the Account ID."
  else
    echo "Account name: $ACCOUNT_NAME (auto-detected)"
  fi
else
  echo "Account name: $ACCOUNT_NAME"
fi
echo ""
echo ">> Confirm the values above match the account you intend to change."
echo ">> Press Ctrl+C now to abort, or wait 8 seconds to continue..."
sleep 8
echo ""

# ----------------------------------------------------------------------------
# STEP 1 — Public (email-facing) SNS topic: reuse if it exists, else create it
# ----------------------------------------------------------------------------
echo "=================================================================="
echo " STEP 1 — Public SNS topic (email delivery)"
echo "=================================================================="
PUBLIC_TOPIC_ARN=$(aws sns list-topics --region "$REGION" \
  --query "Topics[?ends_with(TopicArn, ':${ALARM_EMAIL_TOPIC_NAME}')].TopicArn" --output text)

if [ -z "$PUBLIC_TOPIC_ARN" ]; then
  echo "Topic '$ALARM_EMAIL_TOPIC_NAME' not found — creating it."
  PUBLIC_TOPIC_ARN=$(aws sns create-topic --name "$ALARM_EMAIL_TOPIC_NAME" \
    --region "$REGION" --query 'TopicArn' --output text)
  for email in "${SUBSCRIBER_EMAILS[@]}"; do
    echo "Subscribing $email — they must click the confirmation email AWS sends them."
    aws sns subscribe --topic-arn "$PUBLIC_TOPIC_ARN" --protocol email \
      --notification-endpoint "$email" --region "$REGION" > /dev/null
  done
else
  echo "Reusing existing topic: $PUBLIC_TOPIC_ARN"
fi
echo "Public topic ARN: $PUBLIC_TOPIC_ARN"
echo ""

# ----------------------------------------------------------------------------
# STEP 2 — Raw (internal) SNS topic: alarms publish here, never seen by humans
# ----------------------------------------------------------------------------
echo "=================================================================="
echo " STEP 2 — Raw internal SNS topic (alarm -> formatter Lambda only)"
echo "=================================================================="
RAW_TOPIC_ARN=$(aws sns create-topic --name "$RAW_TOPIC_NAME" \
  --region "$REGION" --query 'TopicArn' --output text)
echo "Raw topic ARN: $RAW_TOPIC_ARN"
echo ""

# ----------------------------------------------------------------------------
# STEP 3 — Formatter Lambda: turns a raw alarm into a readable email
# ----------------------------------------------------------------------------
echo "=================================================================="
echo " STEP 3 — Formatter Lambda"
echo "=================================================================="

if ! aws iam get-role --role-name "$FORMATTER_ROLE_NAME" --region "$REGION" >/dev/null 2>&1; then
  cat > /tmp/formatter-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
  aws iam create-role --role-name "$FORMATTER_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/formatter-trust-policy.json > /dev/null

  cat > /tmp/formatter-permissions.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["cloudwatch:GetMetricStatistics"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["sns:Publish"],
      "Resource": "$PUBLIC_TOPIC_ARN"
    },
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:*"
    }
  ]
}
EOF
  aws iam put-role-policy --role-name "$FORMATTER_ROLE_NAME" \
    --policy-name ec2-alert-formatter-policy \
    --policy-document file:///tmp/formatter-permissions.json
  echo "IAM role created: $FORMATTER_ROLE_NAME"
  sleep 10
else
  echo "IAM role already exists: $FORMATTER_ROLE_NAME (reusing)"
fi

FORMATTER_ROLE_ARN=$(aws iam get-role --role-name "$FORMATTER_ROLE_NAME" --query 'Role.Arn' --output text)

mkdir -p /tmp/formatter && cd /tmp/formatter
cat > lambda_function.py << PYEOF
import boto3
import json
import datetime

ec2 = boto3.client('ec2')
sns = boto3.client('sns')
cw = boto3.client('cloudwatch')

PUBLIC_TOPIC_ARN = "${PUBLIC_TOPIC_ARN}"
ACCOUNT_ID = "${ACCOUNT_ID}"
ACCOUNT_NAME = "${ACCOUNT_NAME}"

def get_check_status(instance_id, metric_name):
    # Reads the actual status-check history from CloudWatch rather than a
    # live snapshot. This matters because by the time this Lambda runs, the
    # instance may have already recovered — a live describe_instance_status
    # call can come back empty right after recovery, silently leaving the
    # field as UNKNOWN. Reading the last 10 minutes of the metric itself
    # instead reflects what was actually true during the failure window.
    try:
        end = datetime.datetime.utcnow()
        start = end - datetime.timedelta(minutes=10)
        m = cw.get_metric_statistics(
            Namespace='AWS/EC2',
            MetricName=metric_name,
            Dimensions=[{'Name': 'InstanceId', 'Value': instance_id}],
            StartTime=start,
            EndTime=end,
            Period=300,
            Statistics=['Maximum']
        )
        points = m.get('Datapoints', [])
        if points:
            latest = sorted(points, key=lambda x: x['Timestamp'])[-1]
            return "IMPAIRED" if latest['Maximum'] >= 1 else "OK"
    except Exception as e:
        print(f"Could not fetch {metric_name} for {instance_id}: {e}")
    return "UNKNOWN"

def lambda_handler(event, context):
    record = event['Records'][0]['Sns']
    message = json.loads(record['Message'])
    alarm_name = message.get('AlarmName', 'unknown-alarm')
    trigger = message.get('Trigger', {})
    dimensions = trigger.get('Dimensions', [])

    instance_id = 'unknown'
    for d in dimensions:
        if d.get('name') == 'InstanceId':
            instance_id = d.get('value')
            break

    name = instance_id
    try:
        tag_resp = ec2.describe_instances(InstanceIds=[instance_id])
        tags = tag_resp['Reservations'][0]['Instances'][0].get('Tags', [])
        for tag in tags:
            if tag['Key'] == 'Name':
                name = tag['Value']
    except Exception as e:
        print(f"Could not fetch instance name for {instance_id}: {e}")

    system_status = get_check_status(instance_id, 'StatusCheckFailed_System')
    instance_status = get_check_status(instance_id, 'StatusCheckFailed_Instance')
    attached_ebs_status = get_check_status(instance_id, 'StatusCheckFailed_AttachedEBS')

    subject = f"CRITICAL: {name} STATUS CHECK FAILED"[:100]

    message_body = (
        f"EC2 STATUS CHECK FAILED\n"
        f"===============================\n\n"
        f"ACCOUNT NAME: {ACCOUNT_NAME}\n"
        f"ACCOUNT ID: {ACCOUNT_ID}\n"
        f"INSTANCE NAME: {name}\n"
        f"INSTANCE ID: {instance_id}\n"
        f"SYSTEM STATUS CHECK: {system_status}\n"
        f"INSTANCE STATUS CHECK: {instance_status}\n"
        f"ATTACHED EBS STATUS CHECK: {attached_ebs_status}\n\n"
        f"TRIGGERED BY ALARM: {alarm_name}\n"
        f"===============================\n"
        f"ACTION REQUIRED - Please investigate immediately.\n"
    )

    sns.publish(
        TopicArn=PUBLIC_TOPIC_ARN,
        Subject=subject,
        Message=message_body
    )

    return {"statusCode": 200, "instance": instance_id}
PYEOF

zip -q function.zip lambda_function.py

if aws lambda get-function --function-name "$FORMATTER_LAMBDA_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "Lambda already exists — updating code."
  aws lambda update-function-code --function-name "$FORMATTER_LAMBDA_NAME" \
    --zip-file fileb://function.zip --region "$REGION" > /dev/null
else
  aws lambda create-function \
    --function-name "$FORMATTER_LAMBDA_NAME" \
    --runtime python3.12 \
    --role "$FORMATTER_ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file fileb://function.zip \
    --timeout 30 \
    --region "$REGION" > /dev/null
  echo "Lambda created: $FORMATTER_LAMBDA_NAME"
fi

FORMATTER_LAMBDA_ARN=$(aws lambda get-function --function-name "$FORMATTER_LAMBDA_NAME" \
  --region "$REGION" --query 'Configuration.FunctionArn' --output text)
echo ""

# ----------------------------------------------------------------------------
# STEP 4 — Wire raw topic -> formatter Lambda
# ----------------------------------------------------------------------------
echo "=================================================================="
echo " STEP 4 — Subscribe formatter Lambda to the raw topic"
echo "=================================================================="

EXISTING_SUB=$(aws sns list-subscriptions-by-topic --topic-arn "$RAW_TOPIC_ARN" \
  --region "$REGION" --query "Subscriptions[?Endpoint=='${FORMATTER_LAMBDA_ARN}'].SubscriptionArn" --output text)

if [ -z "$EXISTING_SUB" ]; then
  aws sns subscribe --topic-arn "$RAW_TOPIC_ARN" --protocol lambda \
    --notification-endpoint "$FORMATTER_LAMBDA_ARN" --region "$REGION" > /dev/null
  echo "Subscribed formatter Lambda to raw topic."
else
  echo "Subscription already exists — skipping."
fi

aws lambda add-permission \
  --function-name "$FORMATTER_LAMBDA_NAME" \
  --statement-id sns-invoke \
  --action lambda:InvokeFunction \
  --principal sns.amazonaws.com \
  --source-arn "$RAW_TOPIC_ARN" \
  --region "$REGION" > /dev/null 2>&1 || echo "Permission already granted — skipping."
echo ""

# ----------------------------------------------------------------------------
# STEP 5 — Backfill: one alarm per currently-running instance -> raw topic
# ----------------------------------------------------------------------------
echo "=================================================================="
echo " STEP 5 — Backfill alarms for currently-running instances"
echo "=================================================================="

INSTANCE_IDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].InstanceId' --output text)

COUNT=0
for id in $INSTANCE_IDS; do
  aws cloudwatch put-metric-alarm \
    --alarm-name "StatusCheckFailed-$id" \
    --namespace AWS/EC2 \
    --metric-name StatusCheckFailed \
    --dimensions Name=InstanceId,Value="$id" \
    --statistic Maximum \
    --period 60 \
    --evaluation-periods 5 \
    --datapoints-to-alarm 4 \
    --threshold 1 \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --alarm-actions "$RAW_TOPIC_ARN" \
    --region "$REGION"
  COUNT=$((COUNT+1))
done
echo "Created/updated $COUNT alarm(s)."
echo ""

# ----------------------------------------------------------------------------
# STEP 6 — Auto-create Lambda: same alarm, for future instances
# ----------------------------------------------------------------------------
echo "=================================================================="
echo " STEP 6 — Auto-create Lambda for future instances"
echo "=================================================================="

if ! aws iam get-role --role-name "$AUTOCREATE_ROLE_NAME" --region "$REGION" >/dev/null 2>&1; then
  cat > /tmp/autocreate-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
  aws iam create-role --role-name "$AUTOCREATE_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/autocreate-trust-policy.json > /dev/null

  cat > /tmp/autocreate-permissions.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["cloudwatch:PutMetricAlarm"],
      "Resource": "arn:aws:cloudwatch:${REGION}:${ACCOUNT_ID}:alarm:*"
    },
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:*"
    }
  ]
}
EOF
  aws iam put-role-policy --role-name "$AUTOCREATE_ROLE_NAME" \
    --policy-name alarm-autocreate-policy \
    --policy-document file:///tmp/autocreate-permissions.json
  echo "IAM role created: $AUTOCREATE_ROLE_NAME"
  sleep 10
else
  echo "IAM role already exists: $AUTOCREATE_ROLE_NAME (reusing)"
fi

AUTOCREATE_ROLE_ARN=$(aws iam get-role --role-name "$AUTOCREATE_ROLE_NAME" --query 'Role.Arn' --output text)

mkdir -p /tmp/autoalarm && cd /tmp/autoalarm
cat > lambda_function.py << PYEOF
import boto3

cw = boto3.client('cloudwatch')
RAW_TOPIC_ARN = "${RAW_TOPIC_ARN}"

def lambda_handler(event, context):
    instance_id = event['detail']['instance-id']

    cw.put_metric_alarm(
        AlarmName=f"StatusCheckFailed-{instance_id}",
        Namespace="AWS/EC2",
        MetricName="StatusCheckFailed",
        Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
        Statistic="Maximum",
        Period=60,
        EvaluationPeriods=5,
        DatapointsToAlarm=4,
        Threshold=1,
        ComparisonOperator="GreaterThanOrEqualToThreshold",
        AlarmActions=[RAW_TOPIC_ARN]
    )

    return {"statusCode": 200, "instance": instance_id}
PYEOF

zip -q function.zip lambda_function.py

if aws lambda get-function --function-name "$AUTOCREATE_LAMBDA_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "Lambda already exists — updating code."
  aws lambda update-function-code --function-name "$AUTOCREATE_LAMBDA_NAME" \
    --zip-file fileb://function.zip --region "$REGION" > /dev/null
else
  aws lambda create-function \
    --function-name "$AUTOCREATE_LAMBDA_NAME" \
    --runtime python3.12 \
    --role "$AUTOCREATE_ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file fileb://function.zip \
    --timeout 30 \
    --region "$REGION" > /dev/null
  echo "Lambda created: $AUTOCREATE_LAMBDA_NAME"
fi

AUTOCREATE_LAMBDA_ARN=$(aws lambda get-function --function-name "$AUTOCREATE_LAMBDA_NAME" \
  --region "$REGION" --query 'Configuration.FunctionArn' --output text)
echo ""

# ----------------------------------------------------------------------------
# STEP 7 — EventBridge rule: fire the auto-create Lambda on new "running" instances
# ----------------------------------------------------------------------------
echo "=================================================================="
echo " STEP 7 — EventBridge rule for future instance launches"
echo "=================================================================="

aws events put-rule \
  --name "$EVENTBRIDGE_RULE_NAME" \
  --event-pattern '{"source":["aws.ec2"],"detail-type":["EC2 Instance State-change Notification"],"detail":{"state":["running"]}}' \
  --region "$REGION" > /dev/null

aws events put-targets \
  --rule "$EVENTBRIDGE_RULE_NAME" \
  --targets "Id"="1","Arn"="$AUTOCREATE_LAMBDA_ARN" \
  --region "$REGION" > /dev/null

aws lambda add-permission \
  --function-name "$AUTOCREATE_LAMBDA_NAME" \
  --statement-id eventbridge-invoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/${EVENTBRIDGE_RULE_NAME}" \
  --region "$REGION" > /dev/null 2>&1 || echo "Permission already granted — skipping."

echo "EventBridge rule wired: $EVENTBRIDGE_RULE_NAME"
echo ""

# ----------------------------------------------------------------------------
# DONE
# ----------------------------------------------------------------------------
echo "=================================================================="
echo " SETUP COMPLETE"
echo "=================================================================="
echo "Account:                 $ACCOUNT_ID"
echo "Region:                  $REGION"
echo "Public (email) topic:    $PUBLIC_TOPIC_ARN"
echo "Raw (internal) topic:    $RAW_TOPIC_ARN"
echo "Formatter Lambda:        $FORMATTER_LAMBDA_NAME"
echo "Auto-create Lambda:      $AUTOCREATE_LAMBDA_NAME"
echo "EventBridge rule:        $EVENTBRIDGE_RULE_NAME"
echo "Alarms created:          $COUNT"
echo ""
echo "Next: confirm all subscriber emails on the public topic show 'Confirmed'"
echo "(AWS Console -> SNS -> Topics -> $ALARM_EMAIL_TOPIC_NAME -> Subscriptions)."
echo "=================================================================="

# ============================================================================
# NEW ACCOUNT CHECKLIST
# ============================================================================
# Before running this script in a DIFFERENT AWS account, confirm/edit:
#
#   [ ] REGION                  — leave blank to auto-detect from the current
#                                  CloudShell session's region; only set this
#                                  explicitly if you need to override it
#   [ ] ACCOUNT_NAME             — leave blank to auto-detect (IAM alias,
#                                  then Organizations name, then falls back
#                                  to the Account ID); set explicitly only
#                                  to override with a nicer label
#   [ ] ALARM_EMAIL_TOPIC_NAME  — keep the same name if you want the script
#                                  to auto-detect and reuse an existing topic,
#                                  or pick a new name to force a fresh topic
#   [ ] SUBSCRIBER_EMAILS       — only matters if ALARM_EMAIL_TOPIC_NAME does
#                                  NOT already exist in that account; update
#                                  to that team's recipient list
#
# You do NOT need to edit, provide, or look up:
#   - Account ID              (auto-detected via `aws sts get-caller-identity`)
#   - Any ARNs                (built automatically from the account ID/region)
#   - Instance IDs             (discovered automatically at runtime)
#
# Requirements in the target account before running:
#   [ ] You are running this from AWS CloudShell (or any shell with the AWS
#       CLI configured) logged into the TARGET account — verify with:
#           aws sts get-caller-identity
#   [ ] Your IAM user/role has permission to create: IAM roles/policies,
#       Lambda functions, EventBridge rules, SNS topics/subscriptions, and
#       CloudWatch alarms (an Administrator or equivalent DevOps role covers
#       all of this).
#   [ ] If SUBSCRIBER_EMAILS is used, each new recipient must click the SNS
#       confirmation email before they will receive any alerts — this is a
#       manual step per person, per account, and cannot be scripted.
# ============================================================================
