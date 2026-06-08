#!/usr/bin/env bash
# pre-destroy.sh — purge resources that terraform destroy cannot remove cleanly.
#
# Run this BEFORE make destroy:
#   ./scripts/pre-destroy.sh
#
# What it does:
#   1. Deletes all AWS Backup recovery points in the platform vault.
#   2. Deregisters all Golden AMIs produced by Image Builder.
#   3. Deletes the EBS snapshots backing those AMIs.
#
# Prerequisites: AWS CLI v2, jq, active SSO session (cloudops-portfolio).

set -euo pipefail

PROFILE="${AWS_PROFILE:-cloudops-portfolio}"
REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-cloudops}"
ENV="${ENVIRONMENT:-dev}"

VAULT_NAME="${PROJECT}-${ENV}-vault-platform"

AWS="aws --profile $PROFILE --region $REGION"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $*"; }
warn() { echo "[$(date '+%H:%M:%S')] ⚠ $*"; }

# ---------------------------------------------------------------------------
# 1. Delete Backup recovery points
# ---------------------------------------------------------------------------
log "Listing recovery points in vault: $VAULT_NAME"

RECOVERY_POINTS=$($AWS backup list-recovery-points-by-backup-vault \
  --backup-vault-name "$VAULT_NAME" \
  --query 'RecoveryPoints[].RecoveryPointArn' \
  --output text 2>/dev/null || echo "")

if [[ -z "$RECOVERY_POINTS" || "$RECOVERY_POINTS" == "None" ]]; then
  ok "No recovery points found in vault."
else
  for RP_ARN in $RECOVERY_POINTS; do
    log "Deleting recovery point: $RP_ARN"
    $AWS backup delete-recovery-point \
      --backup-vault-name "$VAULT_NAME" \
      --recovery-point-arn "$RP_ARN" || warn "Could not delete $RP_ARN — may already be deleting."
  done
  ok "Recovery points deletion initiated."
fi

# ---------------------------------------------------------------------------
# 2. Deregister Golden AMIs + delete backing snapshots
# ---------------------------------------------------------------------------
log "Looking for Golden AMIs (ManagedBy=image-builder, GoldenAMI=true, Environment=$ENV)..."

AMI_IDS=$($AWS ec2 describe-images \
  --owners self \
  --filters \
    "Name=tag:ManagedBy,Values=image-builder" \
    "Name=tag:GoldenAMI,Values=true" \
    "Name=tag:Environment,Values=$ENV" \
  --query 'Images[].ImageId' \
  --output text 2>/dev/null || echo "")

if [[ -z "$AMI_IDS" || "$AMI_IDS" == "None" ]]; then
  ok "No Golden AMIs found."
else
  for AMI_ID in $AMI_IDS; do
    log "Collecting snapshots for AMI: $AMI_ID"
    SNAPSHOT_IDS=$($AWS ec2 describe-images \
      --image-ids "$AMI_ID" \
      --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' \
      --output text 2>/dev/null || echo "")

    log "Deregistering AMI: $AMI_ID"
    $AWS ec2 deregister-image --image-id "$AMI_ID" || warn "Could not deregister $AMI_ID"

    for SNAP_ID in $SNAPSHOT_IDS; do
      [[ -z "$SNAP_ID" || "$SNAP_ID" == "None" ]] && continue
      log "Deleting snapshot: $SNAP_ID"
      $AWS ec2 delete-snapshot --snapshot-id "$SNAP_ID" || warn "Could not delete $SNAP_ID"
    done
  done
  ok "Golden AMIs and snapshots removed."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
log "pre-destroy complete. Run 'make destroy' now."
