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

systemctl enable fraud-worker.service
systemctl start fraud-worker.service

RETRIES=6
for i in $(seq 1 $RETRIES); do
  if systemctl is-active --quiet fraud-worker.service; then
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] fraud-worker.service is active"
    break
  fi
  if [ "$i" -eq "$RETRIES" ]; then
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] fraud-worker.service failed to start after $RETRIES attempts"
    journalctl -u fraud-worker.service --no-pager -n 20
    exit 1
  fi
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] Waiting for fraud-worker ($i/$RETRIES)..."
  sleep 10
done

echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] user-data complete"
