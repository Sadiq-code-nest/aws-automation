#!/bin/bash
# ============================================================================
# EC2 Status Check Alerts — Verification & Test Script
# Cloudly DevOps
#
# Run this in ANY account's CloudShell after running setup-ec2-status-alerts.sh
# to confirm everything deployed correctly, then safely trigger one real
# test alert end-to-end. No instance is ever stopped, started, or modified —
# this only reads state and flips one CloudWatch alarm's status flag.
# ============================================================================

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region)}}"
if [ -z "$REGION" ]; then
  echo "!! Could not auto-detect a region. Set REGION explicitly at the"
  echo "!! top of this script and re-run."
  exit 1
fi

echo "=================================================================="
echo " 0. Which account/region am I checking?"
echo "=================================================================="
aws sts get-caller-identity
echo ""

echo "=================================================================="
echo " 1. Do both SNS topics exist?"
echo "=================================================================="
aws sns list-topics --region "$REGION" \
  --query "Topics[?contains(TopicArn, 'ec2-status-alerts')].TopicArn" --output table
echo ""

echo "=================================================================="
echo " 2. Are all public-topic subscribers confirmed?"
echo "=================================================================="
PUBLIC_TOPIC_ARN=$(aws sns list-topics --region "$REGION" \
  --query "Topics[?ends_with(TopicArn, ':ec2-status-alerts')].TopicArn" --output text)
aws sns list-subscriptions-by-topic --topic-arn "$PUBLIC_TOPIC_ARN" --region "$REGION" \
  --query 'Subscriptions[*].{Endpoint:Endpoint,Status:SubscriptionArn}' --output table
echo "(Any Status showing 'PendingConfirmation' instead of a full ARN means"
echo " that address has NOT clicked the confirmation email and gets nothing.)"
echo ""

echo "=================================================================="
echo " 3. Do both Lambdas exist and are they healthy?"
echo "=================================================================="
for fn in ec2-status-alert-formatter ec2-auto-create-status-alarms; do
  aws lambda get-function --function-name "$fn" --region "$REGION" \
    --query "Configuration.{Name:FunctionName,State:State,LastUpdate:LastUpdateStatus}" \
    --output table 2>&1
done
echo ""

echo "=================================================================="
echo " 4. Does the EventBridge rule exist and is it enabled?"
echo "=================================================================="
aws events describe-rule --name ec2-new-instance-running-rule --region "$REGION" \
  --query '{Name:Name,State:State}' --output table
echo ""

echo "=================================================================="
echo " 5. How many alarms exist, and what state is each in?"
echo "=================================================================="
aws cloudwatch describe-alarms --alarm-name-prefix StatusCheckFailed --region "$REGION" \
  --query 'length(MetricAlarms)'
aws cloudwatch describe-alarms --alarm-name-prefix StatusCheckFailed --region "$REGION" \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue,Period:Period,EvalPeriods:EvaluationPeriods}' \
  --output table
echo ""

echo "=================================================================="
echo " 6. Picking a safe alarm to test (currently in OK state)"
echo "=================================================================="
TEST_ALARM=$(aws cloudwatch describe-alarms --alarm-name-prefix StatusCheckFailed \
  --region "$REGION" --query "MetricAlarms[?StateValue=='OK'] | [0].AlarmName" --output text)

if [ "$TEST_ALARM" == "None" ] || [ -z "$TEST_ALARM" ]; then
  echo "No alarm currently in OK state was found — every alarm is either"
  echo "already in ALARM or INSUFFICIENT_DATA. Pick one manually from the"
  echo "list above and set TEST_ALARM=\"<name>\" yourself, then re-run from"
  echo "STEP 7 onward."
else
  echo "Selected for testing: $TEST_ALARM"
  echo ""

  echo "=================================================================="
  echo " 7. Triggering it (does NOT touch the underlying EC2 instance)"
  echo "=================================================================="
  aws cloudwatch set-alarm-state \
    --alarm-name "$TEST_ALARM" \
    --state-value ALARM \
    --state-reason "verification script test" \
    --region "$REGION"
  echo "Triggered. Waiting 75 seconds for the alarm -> raw topic -> formatter"
  echo "Lambda -> public topic -> email chain to complete..."
  sleep 75

  echo ""
  echo "=================================================================="
  echo " 8. Did the formatter Lambda actually get invoked?"
  echo "=================================================================="
  aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda --metric-name Invocations \
    --dimensions Name=FunctionName,Value=ec2-status-alert-formatter \
    --start-time "$(date -u -d '3 min ago' +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period 60 --statistics Sum --region "$REGION"
  echo "(Sum >= 1.0 above means it fired. Now check your inbox for a readable"
  echo " email naming this instance, with ACCOUNT NAME / ACCOUNT ID included.)"
  echo ""

  echo "=================================================================="
  echo " 9. Resetting the test alarm back to OK"
  echo "=================================================================="
  aws cloudwatch set-alarm-state \
    --alarm-name "$TEST_ALARM" \
    --state-value OK \
    --state-reason "verification complete" \
    --region "$REGION"
  echo "Done."
fi

echo ""
echo "=================================================================="
echo " VERIFICATION COMPLETE — review each numbered section above."
echo "=================================================================="
