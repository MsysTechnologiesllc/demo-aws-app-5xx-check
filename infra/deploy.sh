#!/usr/bin/env bash
# deploy.sh — Deploy and manage demo-aws-app-5xx-check
# Usage:
#   ./infra/deploy.sh deploy               — deploy/update CloudFormation stack
#   ./infra/deploy.sh bad-deploy           — update Lambda to broken v2 + simulate 5xx traffic
#   ./infra/deploy.sh rollback             — restore stable v1
#   ./infra/deploy.sh set-webhook <url>    — update forwarder Lambda with Aziron webhook URL
#   ./infra/deploy.sh status               — show stack outputs and alarm state
#   ./infra/deploy.sh destroy              — delete the CloudFormation stack

set -euo pipefail

STACK_NAME="demo-aws-5xx-check"
REGION="us-east-1"
FUNCTION_NAME="demo-aws-5xx-app"
ALIAS_NAME="live"

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

case "${1:-}" in

  deploy)
    echo "==> Deploying CloudFormation stack: $STACK_NAME"
    aws cloudformation deploy \
      --stack-name "$STACK_NAME" \
      --template-file "$(dirname "$0")/cloudformation.yaml" \
      --capabilities CAPABILITY_NAMED_IAM \
      --region "$REGION"
    echo ""
    echo "==> Stack outputs:"
    aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" \
      --region "$REGION" \
      --query "Stacks[0].Outputs" \
      --output table
    ;;

  bad-deploy)
    echo "==> Deploying broken v2 to Lambda: $FUNCTION_NAME"
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    APP_DIR="$(dirname "$SCRIPT_DIR")/app"

    # Package broken version
    TMPDIR=$(mktemp -d)
    cp "$APP_DIR/lambda_function_broken.py" "$TMPDIR/index.py"
    cd "$TMPDIR" && zip -q code.zip index.py && cd -

    # Update Lambda code
    aws lambda update-function-code \
      --function-name "$FUNCTION_NAME" \
      --zip-file "fileb://$TMPDIR/code.zip" \
      --region "$REGION" \
      --query "FunctionName" --output text

    # Wait for update to complete
    aws lambda wait function-updated \
      --function-name "$FUNCTION_NAME" \
      --region "$REGION"

    # Publish new version
    echo "==> Publishing broken version..."
    VERSION=$(aws lambda publish-version \
      --function-name "$FUNCTION_NAME" \
      --description "v2-broken" \
      --region "$REGION" \
      --query "Version" --output text)
    echo "Published version: $VERSION"

    # Update alias to point to broken version
    aws lambda update-alias \
      --function-name "$FUNCTION_NAME" \
      --name "$ALIAS_NAME" \
      --function-version "$VERSION" \
      --region "$REGION" \
      --query "AliasArn" --output text

    echo "==> Alias '$ALIAS_NAME' → v$VERSION (broken)"

    # Generate 5xx traffic to trigger CloudWatch alarm
    API_URL=$(get_output "ApiGatewayUrl")
    echo "==> Sending 15 requests to /api/checkout to trigger 5xx alarm..."
    echo "    API URL: $API_URL"
    PASS=0; FAIL=0
    for i in $(seq 1 15); do
      CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_URL/api/checkout" \
        -H "Content-Type: application/json" -d '{"item_id":1,"qty":1}')
      if [ "$CODE" -ge 500 ]; then
        FAIL=$((FAIL+1)); echo "  [$i] $CODE ✗ (5xx)"
      else
        PASS=$((PASS+1)); echo "  [$i] $CODE ✓"
      fi
      sleep 1
    done
    echo ""
    echo "Results: $PASS passed, $FAIL failed (5xx)"
    echo ""
    echo "==> CloudWatch alarm will fire within ~1 minute if 5xx count > 3"
    echo "    Watch: https://console.aws.amazon.com/cloudwatch/home?region=$REGION#alarmsV2:alarm/demo-5xx-ApiGw5xxAlarm"
    ;;

  rollback)
    echo "==> Rolling back to stable v1"
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    APP_DIR="$(dirname "$SCRIPT_DIR")/app"

    TMPDIR=$(mktemp -d)
    cp "$APP_DIR/lambda_function.py" "$TMPDIR/index.py"
    cd "$TMPDIR" && zip -q code.zip index.py && cd -

    aws lambda update-function-code \
      --function-name "$FUNCTION_NAME" \
      --zip-file "fileb://$TMPDIR/code.zip" \
      --region "$REGION" \
      --query "FunctionName" --output text

    aws lambda wait function-updated \
      --function-name "$FUNCTION_NAME" \
      --region "$REGION"

    VERSION=$(aws lambda publish-version \
      --function-name "$FUNCTION_NAME" \
      --description "v1-stable-rollback" \
      --region "$REGION" \
      --query "Version" --output text)

    aws lambda update-alias \
      --function-name "$FUNCTION_NAME" \
      --name "$ALIAS_NAME" \
      --function-version "$VERSION" \
      --region "$REGION" \
      --query "AliasArn" --output text

    echo "==> Alias '$ALIAS_NAME' → v$VERSION (stable)"
    ;;

  set-webhook)
    WEBHOOK_URL="${2:-}"
    if [ -z "$WEBHOOK_URL" ]; then
      echo "Usage: $0 set-webhook <aziron_webhook_url>"
      exit 1
    fi
    echo "==> Updating forwarder Lambda with webhook URL..."
    aws lambda update-function-configuration \
      --function-name "demo-5xx-aziron-forwarder" \
      --environment "Variables={AZIRON_WEBHOOK_URL=$WEBHOOK_URL}" \
      --region "$REGION" \
      --query "Environment.Variables.AZIRON_WEBHOOK_URL" --output text
    echo "==> Webhook URL updated"
    ;;

  status)
    echo "==> Stack: $STACK_NAME"
    aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" \
      --region "$REGION" \
      --query "Stacks[0].{Status:StackStatus,Updated:LastUpdatedTime}" \
      --output table 2>/dev/null || echo "Stack not deployed"

    echo ""
    echo "==> Outputs:"
    aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" \
      --region "$REGION" \
      --query "Stacks[0].Outputs" \
      --output table 2>/dev/null || true

    echo ""
    echo "==> Alarm state:"
    aws cloudwatch describe-alarms \
      --alarm-names "demo-5xx-ApiGw5xxAlarm" \
      --region "$REGION" \
      --query "MetricAlarms[0].{State:StateValue,Reason:StateReason}" \
      --output table 2>/dev/null || echo "Alarm not found"
    ;;

  destroy)
    echo "==> Deleting stack: $STACK_NAME"
    read -r -p "Are you sure? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
      aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
      echo "Stack deletion initiated."
    else
      echo "Aborted."
    fi
    ;;

  *)
    echo "Usage: $0 {deploy|bad-deploy|rollback|set-webhook <url>|status|destroy}"
    exit 1
    ;;
esac
