# Runbook 01 — Access Instance via SSM

**Severity:** P3 — Operational  
**Owner:** Cloud Operations  
**Last reviewed:** 2026-05-01

---

## Trigger

You need to access the workload EC2 instance to investigate behavior, check fraud-worker status, run diagnostics, or collect a support bundle.

## Prerequisites

- IAM permissions: `ssm:StartSession` on the target instance, plus `kms:Decrypt` on the platform CMK (for SecureString parameters)
- AWS CLI v2 with the **Session Manager plugin** installed (`session-manager-plugin --version`)
- Access to the AWS account where `cloudops-dev` is deployed

## Impact

- **No service impact.** SSM sessions are read/write at the OS level but do not restart the workload.
- **Audit trail:** every session is logged to CloudWatch Log Group `/aws/ssm/sessions` (30-day retention) and CloudTrail.
- The session is also visible in EventBridge — assumption of break-glass would alert; standard SSM session does not.

---

## Procedure

### Step 1 — Find the instance ID

**Console (preferred):**

1. Navigate to **EC2 → Auto Scaling Groups**.
2. Open `cloudops-dev-asg-workload`.
3. Under **Instance management**, copy the `Instance ID` (single instance — ASG is min=max=1).

**CLI alternative:**

```bash
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names cloudops-dev-asg-workload \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
  --output text)
echo $INSTANCE_ID
```

### Step 2 — Confirm the instance is reachable via SSM

**Console:**

1. Go to **Systems Manager → Fleet Manager**.
2. Filter by Instance ID. The status must show `Online`.

If status is `Connection lost` or the instance is not listed, **stop here** and use [Runbook 04 — Investigate Failed Alarm](04-investigate-failed-alarm.md) to triage SSM agent failure before proceeding.

### Step 3 — Start an interactive shell session

**Console (preferred):**

1. From **Fleet Manager**, select the instance → **Node actions → Start terminal session**.
2. Wait for the in-browser shell to open. You are dropped in as `ssm-user`.

**CLI alternative:**

```bash
aws ssm start-session --target $INSTANCE_ID --region us-east-1
```

### Step 4 — (Optional) Check fraud-worker status

From inside the SSM session, verify the worker is running and polling the queue:

```bash
# Confirm the service is active
sudo systemctl status fraud-worker.service

# Stream live output (Ctrl-C to stop)
sudo journalctl -u fraud-worker.service -f

# Check recent logs for errors
sudo journalctl -u fraud-worker.service --since "1 hour ago" --no-pager | grep -i "error\|warn\|fail"
```

### Step 5 — (Optional) Collect a diagnostic bundle

From inside the SSM session:

```bash
sudo bash -c '
  TS=$(date -u +%Y%m%dT%H%M%SZ)
  BUNDLE=/tmp/diag-$TS.tar.gz
  tar czf $BUNDLE \
    /var/log/messages \
    /var/log/fraud-worker/app.log \
    /var/log/cloud-init-output.log \
    /etc/systemd/system/fraud-worker.service 2>/dev/null
  aws s3 cp $BUNDLE s3://cloudops-dev-s3-diagnostics-<account-id>/diag/ --region us-east-1
  echo "Uploaded $BUNDLE"
'
```

The diagnostics bucket is SSE-KMS encrypted and has a 30-day lifecycle.

---

## Validation

- The interactive shell prompt returns commands successfully (e.g. `whoami` → `ssm-user`).
- Worker status case: `systemctl is-active fraud-worker.service` returns `active`.
- Diagnostic bundle case: object visible under `s3://cloudops-dev-s3-diagnostics-<account-id>/diag/`.
- Audit: confirm session entry exists in CloudWatch Logs `/aws/ssm/sessions`.

## Rollback

None — sessions terminate cleanly on `exit` or Ctrl-D. No persistent change is made by this procedure.

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `TargetNotConnected` | SSM Agent down on instance, or VPC endpoint failure | Trigger ASG instance refresh, then check `cloudops-dev-vpce-ssm` endpoint health |
| `AccessDeniedException` on `StartSession` | IAM principal lacks `ssm:StartSession` for resource | Add session permissions; do **not** assume the break-glass role for routine access |
| `fraud-worker.service` failed | Script missing or SQS/DDB endpoint unreachable | Check `journalctl -u fraud-worker.service -n 50`; confirm `workload_to_vpce` SG rule exists |

## Related

- [Runbook 04 — Investigate Failed Alarm](04-investigate-failed-alarm.md)
- [docs/security-baseline.md](../docs/security-baseline.md) — SSM session logging policy
- [docs/architecture.md](../docs/architecture.md) Section 3.4 — VPC endpoint topology
