#!/usr/bin/env bash
# fraud-worker — SQS consumer / fraud screening decision simulator
#
# Reads runtime config from SSM Parameter Store at startup (SSM-first pattern).
# Config file /etc/fraud-worker/config.env is baked into the AMI by Image Builder
# and sets SSM_PREFIX to the correct parameter path for this environment.
#
# Flow per message:
#   ReceiveMessage → apply fraud rules → PutItem (DynamoDB) → DeleteMessage
#   On DynamoDB failure: leave message in queue → becomes visible after timeout → DLQ after 3 attempts

set -uo pipefail

source /etc/fraud-worker/config.env

log() { logger -t fraud-worker "$*"; }

# ---------------------------------------------------------------------------
# Startup: resolve region via IMDSv2, then fetch runtime config from SSM
# ---------------------------------------------------------------------------
IMDS_TOKEN=$(curl -sf -X PUT 'http://169.254.169.254/latest/api/token' \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' || true)
REGION=$(curl -sf \
  -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  'http://169.254.169.254/latest/meta-data/placement/region' 2>/dev/null || echo "us-east-1")

QUEUE_URL=""
for attempt in 1 2 3; do
  QUEUE_URL=$(aws ssm get-parameter \
    --name "${SSM_PREFIX}/sqs-queue-url" \
    --query Parameter.Value --output text \
    --region "${REGION}" 2>/dev/null) && [ -n "${QUEUE_URL}" ] && break
  log "SSM attempt ${attempt}/3 failed, retrying in 15s..."
  sleep 15
done
[ -z "${QUEUE_URL}" ] && { log "FATAL: Cannot read queue URL from SSM after 3 attempts"; exit 1; }

TABLE_NAME=$(aws ssm get-parameter \
  --name "${SSM_PREFIX}/dynamodb-table-name" \
  --query Parameter.Value --output text \
  --region "${REGION}" 2>/dev/null) || { log "FATAL: Cannot read DynamoDB table name from SSM"; exit 1; }

log "Startup complete | region=${REGION} | table=${TABLE_NAME}"

# ---------------------------------------------------------------------------
# Main polling loop — long-polling (10s) keeps SQS API costs minimal
# ---------------------------------------------------------------------------
while true; do
  MSG=$(aws sqs receive-message \
    --queue-url "${QUEUE_URL}" \
    --max-number-of-messages 1 \
    --wait-time-seconds 10 \
    --output json \
    --region "${REGION}" 2>/dev/null || echo "{}")

  RECEIPT=$(echo "${MSG}" | python3 -c "
import sys, json
msgs = json.load(sys.stdin).get('Messages', [])
print(msgs[0]['ReceiptHandle'] if msgs else '')
" 2>/dev/null || echo "")
  [ -z "${RECEIPT}" ] && continue

  BODY=$(echo "${MSG}" | python3 -c "
import sys, json
msgs = json.load(sys.stdin).get('Messages', [])
print(msgs[0].get('Body', '{}') if msgs else '{}')
" 2>/dev/null || echo "{}")

  CARD_ID=$(echo "${BODY}" | python3 -c "
import sys, json
print(json.loads(sys.stdin.read()).get('card_id', 'UNKNOWN'))
" 2>/dev/null || echo "UNKNOWN")

  AMOUNT=$(echo "${BODY}" | python3 -c "
import sys, json
print(json.loads(sys.stdin.read()).get('amount', '0.00'))
" 2>/dev/null || echo "0.00")

  # Fraud scoring: random 0-99; in a real system this calls a rules engine or ML model.
  # Thresholds: >75 = DENY (high risk), >50 = REVIEW (manual check), <=50 = APPROVE.
  SCORE=$(( RANDOM % 100 ))
  if [ "${SCORE}" -gt 75 ]; then
    DECISION="DENY"
  elif [ "${SCORE}" -gt 50 ]; then
    DECISION="REVIEW"
  else
    DECISION="APPROVE"
  fi

  TXN_ID="txn-$(python3 -c 'import uuid; print(uuid.uuid4())')"
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  EXPIRES_AT=$(python3 -c "import time; print(int(time.time()) + 7776000)")  # 90 days TTL

  # Build DynamoDB item JSON cleanly via Python to avoid manual escaping
  ITEM=$(python3 -c "
import json
print(json.dumps({
  'txn_id':     {'S': '${TXN_ID}'},
  'card_id':    {'S': '${CARD_ID}'},
  'amount':     {'S': '${AMOUNT}'},
  'score':      {'N': '${SCORE}'},
  'decision':   {'S': '${DECISION}'},
  'ts':         {'S': '${TS}'},
  'expires_at': {'N': '${EXPIRES_AT}'}
}))
")

  if aws dynamodb put-item \
    --table-name "${TABLE_NAME}" \
    --item "${ITEM}" \
    --region "${REGION}" 2>/dev/null; then

    aws sqs delete-message \
      --queue-url "${QUEUE_URL}" \
      --receipt-handle "${RECEIPT}" \
      --region "${REGION}" 2>/dev/null || \
      log "WARN: delete-message failed for ${TXN_ID} — duplicate processing possible"

    log "PROCESSED txn=${TXN_ID} card=${CARD_ID} amount=${AMOUNT} score=${SCORE} decision=${DECISION}"

    # Emit business-level metrics to CloudWatch — non-critical; failures are warned but do not
    # affect transaction processing. Namespace FraudPlatform/Worker separates application
    # observability from infrastructure metrics (CloudOpsPlatform/EC2).
    METRIC_DATA=$(python3 -c "
import json
print(json.dumps([
  {'MetricName': 'Decisions',   'Dimensions': [{'Name': 'Decision', 'Value': '${DECISION}'}], 'Value': 1,          'Unit': 'Count'},
  {'MetricName': 'FraudScore',  'Value': ${SCORE}, 'Unit': 'None'},
]))
")
    aws cloudwatch put-metric-data \
      --namespace "FraudPlatform/Worker" \
      --metric-data "${METRIC_DATA}" \
      --region "${REGION}" 2>/dev/null || log "WARN: metric emission failed — non-critical"
  else
    log "ERROR: DynamoDB write failed for ${TXN_ID} — message returns to queue after visibility timeout"
  fi

done
