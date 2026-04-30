#!/usr/bin/env bash
# user_data.sh.tpl
# First-boot configuration for ${workload_name} on ${project}-${environment}

set -euo pipefail

LOG="/var/log/user-data.log"
exec > >(tee -a "$LOG") 2>&1

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Starting user-data for ${project}-${environment}-${workload_name}"

systemctl is-active --quiet amazon-ssm-agent \
  || { echo "SSM Agent not running — aborting"; exit 1; }

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c "ssm:/${project}/${environment}/cloudwatch-agent/config/standard" \
  -s

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] CloudWatch Agent configured and started"

systemctl enable heartbeat-api.service
systemctl start heartbeat-api.service

RETRIES=5
for i in $(seq 1 $RETRIES); do
  if curl -sf http://127.0.0.1:8080/health > /dev/null 2>&1; then
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] heartbeat-api /health OK"
    break
  fi
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Waiting for heartbeat-api ($i/$RETRIES)..."
  sleep 10
done

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] user-data complete"
