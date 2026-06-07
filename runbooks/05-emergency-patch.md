# Runbook 05 — Emergency Patch

**Severity:** P1 — Security  
**Owner:** Cloud Operations  
**Last reviewed:** 2026-05-01

---

## Trigger

One of:

- **Critical CVE** disclosed (CVSS ≥ 7.0) affecting AL2023 base, kernel, OpenSSL, glibc, or another component baked into the Golden AMI.
- **Active exploitation** observed (your security team mandates same-day patch).
- **Vendor advisory** for a component your application links against.

If the patch is non-urgent, prefer the next monthly Image Builder run via [Runbook 02](02-rotate-golden-ami.md) instead.

## Prerequisites

- IAM: same as [Runbook 02](02-rotate-golden-ami.md), plus `ssm:SendCommand` for in-place patching
- CVE identifier and affected package name (from advisory)
- AWS CLI v2 with SSM plugin
- Maintenance window agreement (or break-glass change approval)

## Impact

- **Path A (rebuild AMI):** ~15–20 min total. Brief workload downtime during instance refresh (~5 min).
- **Path B (in-place via SSM Run Command):** ~3–5 min. No instance replacement. Patch is **lost on next ASG replacement** unless also baked into the next AMI.
- **Path A is preferred** for durable fixes. Use Path B only when the rebuild path is too slow.

---

## Procedure — Path A (rebuild AMI, preferred)

### Step A.1 — Confirm the package is in the AMI

From the live instance (SSM session — [Runbook 01](01-access-instance-via-ssm.md)):

```bash
rpm -qa | grep -i <package-name>
```

If the package is not present, no action needed — close the ticket.

### Step A.2 — Trigger the Image Builder pipeline

The `update-linux` AWS-managed component runs `dnf update -y` during build, which pulls the patched package automatically.

```bash
aws imagebuilder start-image-pipeline-execution \
  --image-pipeline-arn arn:aws:imagebuilder:us-east-1:<account-id>:image-pipeline/cloudops-dev-ibpipe-golden-al2023-arm64 \
  --region us-east-1
```

### Step A.3 — Verify the patch in the new AMI

When the build reaches `Available`, get the new AMI ID and launch a one-off verification instance from it (or use the build-time test phase).

Fastest verification — wait until the ASG instance refresh runs (Step A.4), then SSM in and run:

```bash
rpm -q <package-name>
# Expect version >= advisory's fixed version
```

### Step A.4 — Roll forward

Follow [Runbook 02](02-rotate-golden-ami.md) Steps 2–5 (capture AMI ID, update SSM Parameter, update Launch Template, instance refresh).

---

## Procedure — Path B (in-place SSM Run Command, hot-fix only)

Use this only when Path A's 15–20 min window is too slow.

### Step B.1 — Send the patch command

**Console:**

1. **Systems Manager → Run Command → Run command**.
2. **Document:** `AWS-RunShellScript`.
3. **Targets:** select instance manually, or **Specify instance tags** with `Workload=fraud-worker`.
4. **Command parameters:**
   ```
   sudo dnf install -y <package-name>
   sudo dnf update -y <package-name>
   rpm -q <package-name>
   ```
5. **Output options:** S3 bucket = `cloudops-dev-s3-diagnostics-<account-id>`, prefix = `ssm-patch-output/`.
6. **Run**.

**CLI:**

```bash
aws ssm send-command \
  --instance-ids <instance-id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo dnf update -y <package-name>","rpm -q <package-name>"]' \
  --output-s3-bucket-name cloudops-dev-s3-diagnostics-<account-id> \
  --output-s3-key-prefix ssm-patch-output/ \
  --region us-east-1
```

### Step B.2 — Verify

```bash
aws ssm get-command-invocation \
  --command-id <command-id> \
  --instance-id <instance-id> \
  --query '[Status,StandardOutputContent]' \
  --output table \
  --region us-east-1
```

Expect `Status = Success` and the `rpm -q` line in stdout matches the advisory's fixed version.

### Step B.3 — Restart the workload service if needed

If the patched library is loaded by `fraud-worker`:

```bash
aws ssm send-command \
  --instance-ids <instance-id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo systemctl restart fraud-worker"]' \
  --region us-east-1
```

For kernel patches, the instance must be rebooted — do this via instance refresh (Path A) instead of a manual reboot.

### Step B.4 — Schedule a follow-up AMI rebuild

**This is mandatory.** Path B is ephemeral — the next ASG replacement (instance refresh, scaling event, hardware failure) reverts to the unpatched AMI.

Within 24 hours, run Path A so the patch is durable. Open a tracking issue with the CVE ID and the Path B command-id.

---

## Validation

- `rpm -q <package>` reports the fixed version.
- For Path A: ASG instance refresh status `Successful`, `post-deploy-checks.sh` passes.
- For Path B: SSM command Status = `Success` on all targeted instances.
- No new alarms firing post-patch (CPU/Memory/Disk should remain in baseline).
- CloudTrail confirms the `SendCommand` (Path B) or `StartImagePipelineExecution` (Path A) entry.

## Rollback

**Path A:** Launch Template → previous version as default → instance refresh. Same as [Runbook 02](02-rotate-golden-ami.md) rollback.

**Path B:** Re-run `dnf` with the previous version pinned:

```bash
sudo dnf downgrade -y <package-name>-<previous-version>
sudo systemctl restart fraud-worker
```

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `dnf update` fails with `Cannot download repodata` | Egress blocked — instance has no DNS to repos | AL2023 dnf repos are reached via S3 gateway endpoint; verify the workload SG egress to S3 prefix list is intact |
| Path B succeeded, alarm still firing | Service didn't reload patched library | Restart `fraud-worker`; for glibc/openssl, only a reboot guarantees reload |
| Path A pipeline failed in update-linux phase | Upstream AL2023 mirror temporarily unavailable | Retry; if persistent, escalate via AWS Support |
| Patch reverted overnight | Instance was replaced by ASG before Path A completed | This is the entire reason Path B is ephemeral. Always follow Path B with Path A within 24h |

## Related

- [Runbook 02 — Rotate Golden AMI](02-rotate-golden-ami.md)
- [Runbook 04 — Investigate Failed Alarm](04-investigate-failed-alarm.md)
- [docs/security-baseline.md](../docs/security-baseline.md) — patching policy
- [docs/decision-records/0003-al2023-graviton-base.md](../docs/decision-records/0003-al2023-graviton-base.md) — base image choice
