# Tagging Strategy

This document defines required and optional tags, the values each accepts, and how tags drive functional behavior (backups, patching, IAM scoping).

For resource naming, see [`naming-conventions.md`](naming-conventions.md).

---

## 1. Required tags

Every taggable resource receives these tags via the AWS provider's `default_tags` block in Terraform (Phase 4).

| Tag | Purpose | Example |
|---|---|---|
| `Project` | Identifies the platform | `cloudops-platform` |
| `Environment` | Lifecycle environment | `dev`, `staging`, `prod` |
| `Owner` | Responsible engineer / team | `Rafagross` |
| `CostCenter` | Cost allocation | `portfolio` (MVP) |
| `ManagedBy` | How the resource is managed | `terraform`, `aws-backup`, `image-builder` |

---

## 2. Functional tags

Used by AWS services or platform automation to make decisions. Adding or removing changes runtime behavior.

| Tag | Values | Effect |
|---|---|---|
| `Backup` | `daily`, `none` | AWS Backup plan selects `Backup=daily`; untagged resources not backed up |
| `Patch` | `auto`, `manual`, `none` | SSM Patch Manager Maintenance Window targets `Patch=auto` |
| `Workload` | Workload ID (e.g., `fraud-worker`) | CloudWatch metric filters, log routing, alarm scoping |
| `BackupPlan` | Plan name (e.g., `daily`) | Auto-applied by AWS Backup to recovery points |

---

## 3. Operational tags (optional)

| Tag | Purpose | Example |
|---|---|---|
| `Description` | Free-text purpose | `Workload host for fraud-worker` |
| `Documentation` | Link to runbook or doc | GitHub URL |
| `Contact` | Who to call | `owner@example.com` |
| `LastReviewedAt` | Date of last security/architecture review | `2026-04-29` |

---

## 4. Tags used for IAM conditions

### 4.1 Operator SSM session access

```yaml
Condition:
  StringEquals:
    ssm:resourceTag/Project: "cloudops-platform"
    ssm:resourceTag/Environment: "${operator_permitted_env}"
  Bool:
    aws:MultiFactorAuthPresent: "true"
```

A developer with `dev` access cannot session into a `prod`-tagged instance.

### 4.2 AWS Backup selection

`Backup=daily` is the trigger for the daily backup plan.

### 4.3 SSM Patch Manager target

`Patch=auto` is the Maintenance Window target.

### 4.4 EventBridge rule filtering

Instance state change rule filters on `detail.tags.Project: ["cloudops-platform"]`. Only platform-tagged instances trigger alerts.

---

## 5. Tag value validation

| Tag | Validation |
|---|---|
| `Project` | Exactly `cloudops-platform` (case-sensitive) |
| `Environment` | One of `dev`, `staging`, `prod` (lowercase) |
| `Owner` | Non-empty |
| `CostCenter` | Non-empty, lowercase, hyphen-separated |
| `ManagedBy` | One of `terraform`, `cloudformation`, `manual`, `aws-backup`, `image-builder` |
| `Backup` | One of `daily`, `weekly`, `none` |
| `Patch` | One of `auto`, `manual`, `none` |
| `Workload` | Lowercase, hyphen-separated |

Enforced in Terraform module input validation (Phase 4). Example:

```hcl
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod"
  }
}
```

---

## 6. Implementation in Terraform

```hcl
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "cloudops-platform"
      Environment = var.environment
      Owner       = var.owner
      CostCenter  = var.cost_center
      ManagedBy   = "terraform"
    }
  }
}
```

Resource-specific functional tags added at the resource level:

```hcl
resource "aws_autoscaling_group" "workload" {
  # ...
  tag {
    key                 = "Backup"
    value               = "daily"
    propagate_at_launch = true
  }
  tag {
    key                 = "Patch"
    value               = "auto"
    propagate_at_launch = true
  }
  tag {
    key                 = "Workload"
    value               = "fraud-worker"
    propagate_at_launch = true
  }
}
```

**Caveat:** Some EBS volumes attached at instance launch do not propagate `default_tags`. Explicitly tag these via `tag_specifications` in the Launch Template.

---

## 7. What this strategy is not

- **Not AWS Tag Policies.** Requires AWS Organizations. Out of scope for single-account MVP. Phase 2.
- **Not SCPs.** Same Organizations dependency. Phase 2.
- **Not AWS Config required-tags rule.** ~$2/resource/month; largely redundant when Terraform `default_tags` guarantees tag presence for IaC-managed resources.

The MVP relies on Terraform IaC enforcement + code review + pre-commit hook. Appropriate for single-account, single-team scope.

---

## 8. Cost allocation reporting

With required tags in place, AWS Cost Explorer can break down spend by `Project`, `Environment`, `Workload`, `CostCenter`.

Cost allocation tags must be **activated** in the AWS Billing Console before appearing in Cost Explorer. One-time manual step per tag per account.

---

## 9. Tag immutability and drift

Tags applied via `default_tags` are reconciled on every `terraform apply`. Manual Console modifications are reverted on the next apply.

AWS services auto-add internal tags (`aws:autoscaling:groupName`, `aws-backup:*`). Ignore these via `lifecycle.ignore_changes` where necessary.
