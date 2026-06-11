# Runbook 06 — Terraform Operations & Troubleshooting

**Severity:** N/A (operational procedure)  
**Owner:** Cloud Operations  
**Last reviewed:** 2026-06-06

---

## Trigger

- You need to apply infrastructure changes
- `terraform plan` or `terraform apply` hangs or fails
- SG egress rules go missing and workers lose connectivity
- SNS subscription keeps getting deleted
- ImageBuilder apply fails with `ResourceDependencyException`

## Prerequisites

- AWS SSO active: `aws sso login --profile cloudops-portfolio`
- Working directory: `terraform/envs/dev/`
- `terraform.tfvars` must exist (it is gitignored — never commit it)
- Session Manager plugin installed

## Impact

- Full `terraform apply` restarts no running services
- Targeted applies (`-target`) can cause SG rule removal — **avoid them**

---

## Critical rules before any apply

1. **Never use `-target`** — targeting individual resources causes the `aws_security_group.workload` to reconcile its inline egress rules, removing the externally-managed rules (`workload_to_vpce`, `workload_to_dynamodb`). Always run a full apply.
2. **`terraform.tfvars` must exist** — without it, `terraform plan` waits for interactive `ami_id` input and appears to hang.
3. **One apply at a time** — interrupted applies leave stale `.tflock` files.

---

## Procedure

### Step 1 — Refresh SSO credentials

```bash
aws sso login --profile cloudops-portfolio
aws sts get-caller-identity --profile cloudops-portfolio
```

### Step 2 — Check for stale state lock

If `terraform plan` or `terraform apply` hangs immediately (within seconds, no output):

```bash
aws s3 ls s3://cloudops-tfstate-776648109094/cloudops/dev/ \
  --profile cloudops-portfolio | grep tflock
```

If a `.tflock` file exists, remove it:

```bash
aws s3 rm s3://cloudops-tfstate-776648109094/cloudops/dev/terraform.tfstate.tflock \
  --profile cloudops-portfolio
```

### Step 3 — Verify tfvars exists

```bash
cat terraform/envs/dev/terraform.tfvars
```

Minimum required content:

```hcl
ami_id      = "ami-XXXXXXXXXXXXXXXXX"   # current AL2023 arm64 AMI
alert_email = "YOUR_EMAIL"              # use non-Gmail; iCloud works
```

Get current AMI ID:

```bash
aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --query Parameter.Value --output text \
  --profile cloudops-portfolio
```

### Step 4 — Apply

```bash
cd terraform/envs/dev
AWS_PROFILE=cloudops-portfolio terraform apply
```

Review the plan before typing `yes`. Expected stable state:

- `aws_security_group.workload` → **no changes** (lifecycle ignore_changes on egress)
- `aws_security_group_rule.workload_to_vpce` → no changes
- `aws_security_group_rule.workload_to_dynamodb` → no changes

### Step 5 — Validate SG egress rules after apply

Three rules must be present. Verify:

```bash
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=cloudops-dev-sg-workload" \
  --profile cloudops-portfolio \
  --query 'SecurityGroups[0].IpPermissionsEgress[*].{PrefixLists:PrefixListIds,SGs:UserIdGroupPairs[*].GroupId}'
```

Expected output:

- `pl-63a5400a` — S3 gateway endpoint
- `pl-02cd2c6b` — DynamoDB gateway endpoint
- `sg-04b38b2a73492e4d7` — VPC interface endpoints SG

If any rule is missing, the workers will hang on `sqs receive-message` or `dynamodb put-item`. Restore with:

```bash
AWS_PROFILE=cloudops-portfolio terraform apply -replace=aws_security_group_rule.workload_to_vpce
```

---

## Common errors and fixes

### `terraform plan` hangs

**Cause A:** Stale `.tflock` file from interrupted apply → remove it (Step 2).  
**Cause B:** `ami_id` not in `terraform.tfvars` → Terraform waiting for interactive input. Create the file (Step 3).

### ImageBuilder `ResourceDependencyException`

```text
Error: deleting Image Builder Image Recipe: ResourceDependencyException
```

**Cause:** Recipe is immutable. If any component's `data` field changes, Terraform tries to delete and recreate the recipe, but the pipeline depends on it.  
**Fix:** All components and the recipe have `lifecycle { create_before_destroy = true }`. If the recipe version hasn't been bumped, bump it (e.g., `1.0.0` → `1.1.0`) — ImageBuilder recipes require a unique name+version. Then apply.

### ImageBuilder `ResourceAlreadyExistsException`

```text
Error: creating Image Builder Image Recipe: ResourceAlreadyExistsException
```

**Cause:** `create_before_destroy` tried to create a new recipe with the same version as the existing one.  
**Fix:** Bump the recipe version in `terraform/modules/image-builder/main.tf`.

### Workers not processing SQS messages (hanging)

**Symptom:** SQS shows `ApproximateNumberOfMessagesNotVisible = 0` and messages stay visible indefinitely.  
**Cause:** Missing `workload_to_vpce` or `workload_to_dynamodb` SG egress rule.  
**Diagnosis:**

```bash
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=cloudops-dev-sg-workload" \
  --profile cloudops-portfolio \
  --query 'SecurityGroups[0].IpPermissionsEgress'
```

**Fix:** Full apply to restore the missing rule. Then restart workers:

```bash
aws ssm send-command \
  --instance-ids i-03da4edffb6539a7b i-0a20a9df5fa41c883 \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["sudo systemctl restart fraud-worker"]}' \
  --profile cloudops-portfolio \
  --query 'Command.CommandId' --output text
```

Workers hang indefinitely on failed connections (no timeout in the script). A restart is always required after restoring connectivity.

### SNS subscription auto-deletes after confirmation

**Cause A:** `alert_email` not set in `terraform.tfvars` → Terraform applies empty endpoint → subscription deleted.  
**Fix:** Add `alert_email = "YOUR_EMAIL"` to `terraform.tfvars`. Run apply.

**Cause B:** CloudWatch alarms in ALARM state fire immediately on confirmation → email delivery failures accumulate → SNS auto-unsubscribes.  
**Diagnosis:** Check alarms in ALARM state:

```bash
aws cloudwatch describe-alarms --state-value ALARM \
  --profile cloudops-portfolio \
  --query 'MetricAlarms[*].AlarmName' --output text
```

**Cause C:** Gmail hard-bounces AWS SNS notification emails. Use iCloud or any non-Gmail address.  
**Note:** KMS encryption is intentionally **not** set on the SNS topic — SNS with CMK blocks email delivery silently.

### SNS subscription `confirmation_timeout_in_minutes`

The subscription resource has `confirmation_timeout_in_minutes = 10`. When `terraform apply` creates the subscription, you have 10 minutes to click the confirmation link in the email. If you miss it, Terraform deletes the subscription and apply fails. Run apply again.

---

## Validation

```bash
# SQS processing
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/776648109094/cloudops-dev-sqs-fraud-transactions \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --profile cloudops-portfolio

# Worker status (via SSM)
aws ssm send-command \
  --instance-ids i-03da4edffb6539a7b i-0a20a9df5fa41c883 \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["sudo systemctl is-active fraud-worker"]}' \
  --profile cloudops-portfolio \
  --output text

# SNS subscription active
aws sns list-subscriptions-by-topic \
  --topic-arn arn:aws:sns:us-east-1:776648109094:cloudops-dev-sns-alerts \
  --profile cloudops-portfolio
```
