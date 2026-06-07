# Runbook 02 — Rotate Golden AMI

**Severity:** P3 — Planned maintenance  
**Owner:** Cloud Operations  
**Last reviewed:** 2026-05-01

---

## Trigger

One of:

- **Scheduled monthly rebuild** (first Sunday 06:00 UTC) — Image Builder pipeline ran automatically; you need to validate and roll forward.
- **CVE / out-of-band patch** — you need to rebuild the AMI before the next scheduled run. For CVE-only emergencies, use [Runbook 05 — Emergency Patch](05-emergency-patch.md) instead.
- **Configuration change** — new component version (CloudWatch Agent, fraud-worker script, CIS hardening rule).

## Prerequisites

- IAM permissions: `imagebuilder:StartImagePipelineExecution`, `ec2:DescribeImages`, `autoscaling:StartInstanceRefresh`, `ssm:GetParameter`, `ssm:PutParameter`
- AWS CLI v2 configured
- Access to AWS Console **EC2 Image Builder** and **Auto Scaling Groups**

## Impact

- **Compute:** the workload instance is replaced (ASG min=max=1). Brief downtime is expected — `min_healthy_percentage = 0` in the instance refresh config.
- **Cost:** Image Builder build run costs ~$0.05–0.15 (single t3.medium for ~10 minutes).
- **RTO during refresh:** ~5–7 minutes from refresh start to new instance passing health checks.

---

## Procedure

### Step 1 — Trigger the pipeline (manual rebuild only)

Skip this step if the pipeline ran on schedule. Pipeline schedule: `cron(0 6 ? * SUN#1 *)` (first Sunday, 06:00 UTC).

**Console:**

1. **EC2 Image Builder → Image pipelines → `cloudops-dev-ibpipe-golden-al2023-arm64`**.
2. **Actions → Run pipeline**.
3. Wait until **Image status** transitions: `Building` → `Testing` → `Distributing` → `Available` (~10–15 min total).

**CLI alternative:**

```bash
aws imagebuilder start-image-pipeline-execution \
  --image-pipeline-arn arn:aws:imagebuilder:us-east-1:<account-id>:image-pipeline/cloudops-dev-ibpipe-golden-al2023-arm64 \
  --region us-east-1
```

### Step 2 — Capture the new AMI ID

**Console:**

1. **EC2 Image Builder → Images** → most recent build → copy the **Output AMI ID** (us-east-1).
2. Verify tags include `GoldenAMI=true`, `Environment=dev`.

**CLI:**

```bash
NEW_AMI=$(aws ec2 describe-images \
  --owners self \
  --filters "Name=tag:GoldenAMI,Values=true" "Name=tag:Environment,Values=dev" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' \
  --output text \
  --region us-east-1)
echo "New AMI: $NEW_AMI"
```

### Step 3 — Update the SSM Parameter pointer

The canonical reference is `/cloudops/dev/golden-ami/al2023-arm64/latest`. Other systems read from here.

```bash
aws ssm put-parameter \
  --name /cloudops/dev/golden-ami/al2023-arm64/latest \
  --value $NEW_AMI \
  --type String \
  --overwrite \
  --region us-east-1
```

### Step 4 — Update the Launch Template

The Launch Template AMI is referenced via `var.ami_id` in Terraform. For a non-Terraform manual rotation:

**Console:**

1. **EC2 → Launch Templates → `cloudops-dev-lt-workload`**.
2. **Actions → Modify template (Create new version)**.
3. **AMI ID** → paste `$NEW_AMI`. Leave all other fields unchanged.
4. **Create template version** → set as **Default version**.

**Terraform-managed (preferred long-term):**

Update `terraform/envs/dev/terraform.tfvars` → set `ami_id = "<new-ami-id>"` → `terraform apply`.

### Step 5 — Roll forward via Instance Refresh

**Console:**

1. **EC2 → Auto Scaling Groups → `cloudops-dev-asg-workload`**.
2. **Instance refresh → Start instance refresh**.
3. Settings: **Minimum healthy percentage = 0**, **Instance warmup = 300s**. Confirm.
4. Watch **Activity** tab — the old instance terminates, the new one launches with the new AMI.

**CLI:**

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name cloudops-dev-asg-workload \
  --preferences '{"MinHealthyPercentage":0,"InstanceWarmup":300}' \
  --region us-east-1
```

---

## Validation

After the refresh shows `Successful`:

1. **New instance is using the new AMI:**
   ```bash
   aws ec2 describe-instances \
     --filters "Name=tag:aws:autoscaling:groupName,Values=cloudops-dev-asg-workload" "Name=instance-state-name,Values=running" \
     --query 'Reservations[].Instances[].[InstanceId,ImageId]' --output table
   ```
   The `ImageId` should match `$NEW_AMI`.

2. **SSM Agent is Online** — Systems Manager → Fleet Manager.

3. **fraud-worker is healthy** — run `scripts/validation/post-deploy-checks.sh <new-instance-id> us-east-1`. All checks must pass.

4. **No `cloudops-dev-alarm-status-check-failed` alarm** firing for the new instance.

## Rollback

If validation fails:

1. **Console:** Launch Template → set previous version as default.
2. **CLI:**
   ```bash
   aws ec2 modify-launch-template \
     --launch-template-name cloudops-dev-lt-workload \
     --default-version <previous-version-number> \
     --region us-east-1
   ```
3. Trigger another instance refresh — same procedure as Step 5.
4. Open an issue tagged `phase:hardening` with the build logs (S3: `image-builder-logs/`).

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| Pipeline `Failed` in `Testing` phase | `IMDSv2 validate` step failed (HTTP != 401) | Check the recipe component output; AL2023 base image change broke metadata defaults |
| Instance refresh stuck `Pending` | Health check grace too short | Increase `health_check_grace_period` to 600s and retry |
| New instance fails post-deploy checks | CloudWatch Agent SSM Parameter path mismatch | Confirm `/cloudops/dev/cloudwatch-agent/config/standard` exists and is readable by workload role |

## Related

- [Runbook 05 — Emergency Patch](05-emergency-patch.md) — for CVE-driven rotations
- [docs/decision-records/0003-al2023-graviton-base.md](../docs/decision-records/0003-al2023-graviton-base.md)
- [docs/architecture.md](../docs/architecture.md) Section 9 — Image Builder pipeline
