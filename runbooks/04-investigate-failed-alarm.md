# Runbook 04 — Investigate Failed Alarm

**Severity:** Variable (P1–P3) — depends on alarm  
**Owner:** Cloud Operations  
**Last reviewed:** 2026-05-01

---

## Trigger

A CloudWatch alarm transitioned to `ALARM` and you received an SNS email. Common alarms in this platform:

| Alarm name | Severity | Likely root cause |
|---|---|---|
| `cloudops-dev-alarm-cpu-high` | P3 | Runaway process, sustained workload spike |
| `cloudops-dev-alarm-mem-high` | P3 | Memory leak in fraud-worker, log buffer growth |
| `cloudops-dev-alarm-disk-root-high` | P2 | Log rotation broken, journald accumulation |
| `cloudops-dev-alarm-status-check-failed` | P1 | Instance hardware/network failure — ASG replacement imminent |
| `cloudops-dev-alarm-cwagent-missing` | P1 | CloudWatch Agent crashed, instance frozen, or VPC endpoint failure |
| `cloudops-dev-alarm-log-ingestion-app-high` | P3 | Logging loop, debug level left on, application error spam |

## Prerequisites

- IAM: `cloudwatch:DescribeAlarms`, `logs:StartQuery`, `logs:GetQueryResults`, `ssm:StartSession`
- AWS CLI v2 with Session Manager plugin
- AWS Console access

## Impact

- **No direct impact** from investigation. Confirm the alarm is real before taking action — false positives happen when CloudWatch Agent dimension labels drift.

---

## Procedure

### Step 1 — Confirm the alarm is still firing

**Console:**

1. **CloudWatch → All alarms** → filter by name from the email.
2. Check **State** = `In alarm`. If `OK`, the issue self-resolved. Document and close.
3. Open the alarm → **History** tab. Note the start time and any prior flap pattern.

**CLI:**

```bash
aws cloudwatch describe-alarms \
  --alarm-names cloudops-dev-alarm-<name> \
  --query 'MetricAlarms[0].[StateValue,StateReason,StateUpdatedTimestamp]' \
  --output table \
  --region us-east-1
```

### Step 2 — Pull the dashboard

**Console: CloudWatch → Dashboards → `cloudops-dev-dashboard-overview`**. Note correlated movement across CPU/Memory/Disk/Status — this often reveals root cause faster than the single alarm graph.

### Step 3 — Triage by alarm type

#### CPU / Memory high

SSM into the instance ([Runbook 01](01-access-instance-via-ssm.md)) and run:

```bash
top -b -n 1 -o %CPU | head -20
top -b -n 1 -o %MEM | head -20
ps aux --sort=-%mem | head -10
free -h
```

If `fraud-worker` is the offender → restart it (`sudo systemctl restart fraud-worker`) and capture logs from `journalctl -u fraud-worker.service` for the post-mortem.

#### Disk root high

```bash
sudo du -h --max-depth=1 / 2>/dev/null | sort -hr | head -10
sudo journalctl --disk-usage
sudo find /var/log -type f -size +100M
```

Most common: `journald` accumulation. Fix:

```bash
sudo journalctl --vacuum-time=7d
sudo journalctl --vacuum-size=500M
```

#### Status check failed

**Console: EC2 → Instances → select instance → Status checks tab**. Identify whether it is **System** or **Instance** check.

- **System status check failed** = AWS-side hardware/network issue. ASG will replace the instance automatically. Wait 10 minutes and confirm a new instance launched.
- **Instance status check failed** = OS-level problem. ASG replaces it via `health_check_type = EC2`.

If no replacement happened within 10 minutes → check ASG **Activity** for failures (likely IAM, AMI, or launch template misconfiguration).

#### Heartbeat missing

The instance may be alive but the CloudWatch Agent stopped reporting. Try SSM first:

```bash
aws ssm start-session --target <instance-id>
```

If SSM connects:

```bash
sudo systemctl status amazon-cloudwatch-agent
sudo systemctl restart amazon-cloudwatch-agent
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status
```

If SSM does **not** connect → check VPC interface endpoint health (**VPC → Endpoints → `cloudops-dev-vpce-ssm`**, status should be `Available`). If endpoint is healthy and instance is unreachable, force ASG replacement:

```bash
aws autoscaling set-instance-health \
  --instance-id <instance-id> \
  --health-status Unhealthy \
  --region us-east-1
```

#### Log ingestion high

Query Logs Insights to find the noisy source:

**Console: CloudWatch → Logs Insights** → log group `/aws/ec2/fraud-worker/app` → time range = last 24h:

```
fields @timestamp, @message
| stats count() as cnt by bin(5m)
| sort @timestamp desc
```

Then drill into the spike window:

```
fields @timestamp, @message
| filter @message like /ERROR|WARN/
| stats count() by @message
| sort cnt desc
| limit 20
```

Fix at the source — change app log level via `aws ssm put-parameter --name /cloudops/dev/app/fraud-worker/log-level --value warn --overwrite`, then restart `fraud-worker`.

---

## Validation

- Alarm transitions back to `OK` within 2× the evaluation period (e.g. 15 min for a 5-min×2 alarm).
- For replaced instances: new instance ID visible, `post-deploy-checks.sh` passes.
- Logs Insights query confirms the noise source is gone.

## Rollback

- Reverting the workload: `terraform apply` to last known-good state.
- Reverting log level: same SSM `put-parameter` with the previous value, restart service.

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Alarm flaps `OK` ↔ `ALARM` repeatedly | Threshold too tight, or workload pattern crosses boundary | Adjust threshold or evaluation periods; check `cost-model.md` for log volume sizing |
| Heartbeat alarm fires but instance is fine in console | `mem_used_percent` dimension changed (e.g. agent restart) | Confirm metric is still being emitted; if dimension drift is the root cause, file an issue to align Terraform alarm dimensions |
| Disk alarm clears but recurs same day | Log rotation not running | Check `/etc/logrotate.d/fraud-worker`; bake rotation into the next AMI build |

## Related

- [Runbook 01 — Access Instance via SSM](01-access-instance-via-ssm.md)
- [Runbook 05 — Emergency Patch](05-emergency-patch.md)
- [docs/cost-model.md](../docs/cost-model.md) Section 5 — log ingestion guardrails
- [docs/architecture.md](../docs/architecture.md) Section 7 — observability stack
