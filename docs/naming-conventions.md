# Naming Conventions

This document defines the naming standard for all resources in the platform. Enforced by Terraform module input validation (Phase 4) and code review.

For tagging (separate from naming), see [`tagging-strategy.md`](tagging-strategy.md).

---

## 1. Pattern

```
<project>-<env>-<resource-type>-<purpose>
```

| Segment | Example | Rules |
|---|---|---|
| `<project>` | `cloudops` | Fixed for this platform |
| `<env>` | `dev`, `staging`, `prod` | Lowercase, no hyphens |
| `<resource-type>` | `vpc`, `sg`, `iprofile` | Lowercase abbreviated (see Section 3) |
| `<purpose>` | `workload`, `vpce`, `golden-al2023` | Lowercase, hyphen-separated |

**Examples:** `cloudops-dev-vpc-main`, `cloudops-dev-sg-workload`, `cloudops-dev-vpce-ssm`, `cloudops-dev-asg-workload`, `cloudops-dev-cmk-platform`

**Length limit:** Under 64 characters (the lowest AWS field cap across IAM roles, security group names, etc.).

---

## 2. Why this pattern

1. **Sortability** — alphabetical grouping: project → env → resource type. In a console with 200 resources, this matters.
2. **Greppability** — `grep cloudops-dev-sg-` narrows to security groups in dev.
3. **Readability** — a reviewer who has never seen the project can guess what `cloudops-dev-vpce-ssm` is.

---

## 3. Resource type abbreviations

| AWS Resource | Abbreviation | Example |
|---|---|---|
| VPC | `vpc` | `cloudops-dev-vpc-main` |
| Subnet | `subnet` | `cloudops-dev-subnet-private-app-a` |
| Internet Gateway | `igw` | (not used in MVP) |
| Route Table | `rt` | `cloudops-dev-rt-private-app` |
| Security Group | `sg` | `cloudops-dev-sg-workload` |
| VPC Endpoint (Interface) | `vpce` | `cloudops-dev-vpce-ssm` |
| VPC Endpoint (Gateway) | `vpce-gw` | `cloudops-dev-vpce-gw-s3` |
| VPC Flow Log | `flowlog` | `cloudops-dev-flowlog-main` |
| Launch Template | `lt` | `cloudops-dev-lt-workload` |
| Auto Scaling Group | `asg` | `cloudops-dev-asg-workload` |
| IAM Role | `role` | `cloudops-dev-role-workload` |
| IAM Instance Profile | `iprofile` | `cloudops-dev-iprofile-workload` |
| IAM Policy | `policy` | `cloudops-dev-policy-workload-inline` |
| KMS Key | `cmk` | `cloudops-dev-cmk-platform` |
| KMS Alias | `alias` | `alias/cloudops-dev-cmk-platform` |
| CloudWatch Alarm | `alarm` | `cloudops-dev-alarm-cpu-high` |
| CloudWatch Dashboard | `dashboard` | `cloudops-dev-dashboard-overview` |
| EventBridge Rule | `evt` | `cloudops-dev-evt-asg-state-change` |
| SNS Topic | `sns` | `cloudops-dev-sns-alerts` |
| SSM Document | `ssmdoc` | `cloudops-dev-ssmdoc-collect-diagnostics` |
| SSM Maintenance Window | `mw` | `cloudops-dev-mw-patch-weekly` |
| SSM Patch Baseline | `pb` | `cloudops-dev-pb-al2023` |
| AWS Backup Vault | `vault` | `cloudops-dev-vault-platform` |
| AWS Backup Plan | `bp` | `cloudops-dev-bp-daily` |
| AWS Backup Selection | `bsel` | `cloudops-dev-bsel-tagged-daily` |
| EC2 Image Builder Pipeline | `ibpipe` | `cloudops-dev-ibpipe-golden-al2023-arm64` |
| EC2 Image Builder Recipe | `ibrecipe` | `cloudops-dev-ibrecipe-golden-al2023-arm64` |
| EC2 Image Builder Component | `ibcomp` | `cloudops-dev-ibcomp-cis-baseline` |
| EC2 Image Builder Distribution | `ibdist` | `cloudops-dev-ibdist-us-east-1` |
| EC2 Image Builder Infrastructure | `ibinfra` | `cloudops-dev-ibinfra-default` |
| S3 Bucket | `s3` | `cloudops-dev-s3-diagnostics-<accountid>` |
| AWS Budgets | `budget` | `cloudops-dev-budget-monthly` |

**Exceptions:**
- **CloudWatch Log Groups** use AWS conventional `/` paths.
- **SSM Parameters** use `/`-path hierarchy (see Section 4.3).
- **S3 buckets** append account ID for global uniqueness.
- **KMS aliases** require the `alias/` prefix per AWS API.

---

## 4. Special cases

### 4.1 Subnets (carry AZ)

```
cloudops-<env>-subnet-<tier>-<az-suffix>
```

Examples: `cloudops-dev-subnet-private-app-a`, `cloudops-dev-subnet-private-vpce-b`, `cloudops-dev-subnet-public-a`

### 4.2 IAM Roles vs. Instance Profiles

- Role: `cloudops-dev-role-workload`
- Instance Profile: `cloudops-dev-iprofile-workload`

### 4.3 SSM Parameters (hierarchical)

```
/cloudops/<env>/<category>/<component>/<key>
```

Examples:
- `/cloudops/dev/golden-ami/al2023-arm64/latest`
- `/cloudops/dev/cloudwatch-agent/config/standard`
- `/cloudops/dev/worker/sqs-queue-url`
- `/cloudops/dev/worker/dynamodb-table-name`
- `/cloudops/dev/app/fraud-worker/log-level`
- `/cloudops/dev/app/fraud-worker/api-token` (SecureString)

Enables IAM resource scoping by path prefix:
```
Resource: arn:aws:ssm:us-east-1:<acct>:parameter/cloudops/dev/app/fraud-worker/*
Resource: arn:aws:ssm:us-east-1:<acct>:parameter/cloudops/dev/worker/*
```

### 4.4 CloudWatch Log Groups

Conventional `/aws/<service>/...` prefix:
- `/aws/ec2/fraud-worker/system`
- `/aws/ec2/fraud-worker/app`
- `/aws/ec2/fraud-worker/audit`
- `/aws/ssm/sessions`
- `/aws/vpc/flowlogs`

---

## 5. Anti-patterns to avoid

| Anti-pattern | Why bad |
|---|---|
| `WorkloadSecurityGroup` (PascalCase) | Inconsistent with AWS lowercase + hyphens |
| `cloudops_dev_sg_workload` (underscores) | Inconsistent; standardize on hyphens |
| `cloudops-dev-sg` (no purpose) | Multiple SGs will collide |
| `cloudops-dev-app01-sg` (purpose before type) | Breaks sort grouping by resource type |
| Including AWS region in name | Implied by context; doubles length |
| Timestamps or version numbers in resource names | Use tags (`CreatedAt`, `Version`) instead |
| Mixed separators | Pick one |

---

## 6. Validation

Terraform modules (Phase 4) include input validation blocks enforcing:
- Project segment is `cloudops`.
- Environment is one of `dev`, `staging`, `prod`.
- Generated names match `^cloudops-(dev|staging|prod)-[a-z]+-[a-z0-9-]+$`.
- Total length under 64 characters.
