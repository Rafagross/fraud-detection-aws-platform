# Architecture

This document describes the full design of the `aws-cloudops-private-ec2-operations-platform`. It assumes the reader is comfortable with AWS networking, IAM, and EC2.

For shorter "why" answers on individual decisions, see the ADRs under [`decision-records/`](decision-records/).

---

## 1. Goals and non-goals

### Goals
- Operate Linux EC2 workloads in private subnets with zero inbound network exposure.
- Provide auditable, identity-based shell and command access without SSH, key pairs, or bastions.
- Make instance replacement automatic, not manual.
- Encrypt all platform data at rest and in transit with a customer-managed key.
- Stay under $100/month while remaining defensible as a real production pattern.
- Be defensible in a senior-level technical interview — every choice has a documented reason.

### Non-goals
- Running a relational managed database (RDS). The fraud-worker uses DynamoDB for decision persistence — serverless, near-zero cost at PoC volume, routed free via Gateway Endpoint, and directly relevant to the fraud detection narrative. RDS would add ~$20/month minimum without adding to the platform story.
- Multi-account or organization-level controls. This repo provisions a single workload pattern in a single account. The org structure is assumed to exist.
- Human identity (SSO, permission sets, MFA enforcement at the IAM Identity Center level). The platform builds *workload* IAM roles; operator IAM is upstream.
- Multi-region disaster recovery. In-region durability via AWS Backup is the MVP; multi-region copy is a Phase 2 enhancement.
- Kubernetes. EKS belongs in a different reference project.

---

## 2. The fraud-worker service

A Python poll-loop worker gives the platform something real to operate, observe, back up, and patch. It is not the point of the project — the platform is — but it provides genuine signal to the runbooks, alarms, and automation.

| Property | Value |
|---|---|
| Language | Python 3 |
| Runtime model | Long-running poll loop — not an HTTP server |
| Function | Polls `fraud-transactions` SQS queue, scores each transaction, writes `APPROVED` / `DECLINED` / `REVIEW` decision to DynamoDB `fraud-decisions` table |
| Idempotency | DynamoDB `txn_id` (hash key) — a duplicate `PutItem` on the same transaction ID is a no-op |
| Config | Reads SQS URL and DynamoDB table name from SSM Parameter Store at startup (`/cloudops/dev/worker/sqs-queue-url`, `/cloudops/dev/worker/dynamodb-table-name`) |
| Process model | systemd unit `fraud-worker.service`, `User=nobody`, `NoNewPrivileges=yes`, `PrivateTmp=yes` |
| Log destination | journald → CloudWatch Agent → `/aws/ec2/fraud-worker/app` |
| External dependencies | SQS (via Interface Endpoint), DynamoDB (via Gateway Endpoint), SSM Parameter Store (via Interface Endpoint) |

The script is baked into the Golden AMI by the Image Builder pipeline. There is no runtime code deploy in MVP — a new worker version means a new AMI, a new Launch Template version, and an ASG instance refresh. This demonstrates immutable infrastructure and removes the "how do I deploy code to a private instance" question from MVP scope.

Operators verify and test the worker via SSM session:

```bash
# Connect to any instance in the ASG
aws ssm start-session --target i-xxxxxxxxxxxxxxxxx

# Stream live worker output
sudo journalctl -u fraud-worker.service -f

# Send a test transaction into the queue (from operator's terminal, not the instance)
aws sqs send-message \
  --queue-url $(aws ssm get-parameter \
    --name /cloudops/dev/worker/sqs-queue-url --query Parameter.Value --output text) \
  --message-body '{"txn_id":"test-001","card_id":"card-test","amount":99.00,"merchant":"test-store"}'

# Verify the decision was persisted
aws dynamodb get-item \
  --table-name cloudops-dev-ddb-fraud-decisions \
  --key '{"txn_id":{"S":"test-001"}}'
```

No public endpoint, no Application Load Balancer, no inbound rules.

### 2.1 SQS processing model — retry, visibility, and poison messages

| Property | Value | Rationale |
|---|---|---|
| Visibility timeout | 60 s | Worker has 60 s to write DynamoDB + delete the message before it re-enqueues |
| Max receive count | 3 | A message that fails 3 times is moved to the DLQ instead of looping indefinitely |
| DLQ retention | 14 days | Enough time to investigate root cause and replay valid messages |
| Main queue retention | 4 days | Covers a weekend outage without message loss |

**Happy path:** `ReceiveMessage` → score → `PutItem` (DynamoDB) → `DeleteMessage`. Total under 5 s per transaction.

**DynamoDB failure:** `DeleteMessage` is skipped. The message becomes visible again after 60 s. If it fails 3 times total, SQS moves it to the DLQ automatically — this is the poison-message control. A CloudWatch alarm fires when the DLQ depth exceeds 0.

**Idempotency:** `txn_id` is the DynamoDB hash key. If a message is processed twice (e.g., `DeleteMessage` timed out but `PutItem` succeeded), the second `PutItem` is a no-op — the original decision is preserved.

**Business metrics:** After each successful decision the worker emits to CloudWatch namespace `FraudPlatform/Worker`: `Decisions` (count by `APPROVE` / `REVIEW` / `DENY`) and `FraudScore` (raw score, 0–99). Infrastructure metrics use the separate `CloudOpsPlatform/EC2` namespace so platform and application observability can be dashboarded and permissioned independently.

---

## 3. Network design

### 3.1 VPC and CIDR

Single VPC: `10.20.0.0/16`. Chosen to avoid the most common on-premises and home-network ranges (`10.0.0.0/16`, `192.168.x.x`, `172.16.x.x`).

### 3.2 Subnets

| Subnet | CIDR | AZ | Purpose | MVP usage |
|---|---|---|---|---|
| `cloudops-dev-public-a` | `10.20.0.0/24` | us-east-1a | Public (reserved) | Empty — no IGW attachment in MVP |
| `cloudops-dev-public-b` | `10.20.1.0/24` | us-east-1b | Public (reserved) | Empty |
| `cloudops-dev-private-app-a` | `10.20.10.0/24` | us-east-1a | Workload | ASG eligible |
| `cloudops-dev-private-app-b` | `10.20.11.0/24` | us-east-1b | Workload | ASG eligible |
| `cloudops-dev-private-vpce-a` | `10.20.20.0/24` | us-east-1a | Interface endpoints | One ENI per endpoint |
| `cloudops-dev-private-vpce-b` | `10.20.21.0/24` | us-east-1b | Interface endpoints | One ENI per endpoint |

Endpoint ENIs live in dedicated subnets so the security group surface is explicit and so workload-subnet route tables and ACLs aren't entangled with endpoint behavior.

### 3.3 Routing

- Workload private route tables: only the local VPC route. No `0.0.0.0/0`. Reachability to AWS services is via interface endpoints (private DNS enabled) and the S3 gateway endpoint route.
- Endpoint subnet route tables: same — local VPC route only.
- Public subnets have a route table prepared for an IGW but no IGW is attached in MVP.

### 3.4 VPC endpoints

Interface endpoints (PrivateLink, ~$7.30/endpoint/month + data):

| Service | Why required |
|---|---|
| `com.amazonaws.us-east-1.ssm` | SSM Agent control plane |
| `com.amazonaws.us-east-1.ssmmessages` | Session Manager data channel |
| `com.amazonaws.us-east-1.ec2messages` | Run Command / agent messaging |
| `com.amazonaws.us-east-1.logs` | CloudWatch Logs ingestion |
| `com.amazonaws.us-east-1.monitoring` | CloudWatch Metrics |

Gateway endpoint (free):

| Service | Why required |
|---|---|
| `com.amazonaws.us-east-1.s3` | Image Builder artifacts, AWS Backup metadata, vended logs |

KMS interface endpoint is **not** in MVP. KMS calls from the workload happen in the context of EBS, CloudWatch Logs, and AWS Backup — those services call KMS server-side, not the instance. The instance's direct KMS API call volume is negligible. Adding the endpoint costs another ~$87/year for no measurable security or performance gain.

### 3.5 Why no NAT Gateway

NAT Gateway base cost is ~$33/month per AZ before data charges. Workload instances do not need internet egress: SSM, CloudWatch, and S3 traffic uses endpoints; OS package updates happen inside the EC2 Image Builder pipeline (which manages its own egress in its own infrastructure configuration), not at runtime. Adding NAT to the runtime VPC would more than double the platform's monthly cost for no functional gain.

If a future requirement demands runtime internet egress (an outbound API call, a webhook), the addition is one route table change. Justifying that cost should require a real reason — see [ADR 0001](decision-records/0001-no-nat-gateway.md).

### 3.6 Why no public SSH

Public SSH would require an internet-routable IP (or a bastion that does), an open port, key distribution, key rotation, and parallel audit logging. SSM Session Manager replaces all of it: IAM-controlled, MFA-required, encrypted in transit, fully logged to CloudWatch Logs, no inbound network rules. See [ADR 0002](decision-records/0002-ssm-only-access.md).

### 3.7 VPC Flow Logs

Flow Logs are enabled at the **VPC level** (captures all subnets) with destination CloudWatch Logs:

| Property | Value |
|---|---|
| Log group | `/aws/vpc/flowlogs` |
| Filter | `ALL` (accept + reject) |
| Retention | 14 days |
| Encryption | Platform CMK |
| Format | Default (AWS standard fields) |

This provides a complete network-layer audit trail for troubleshooting connectivity issues and investigating security incidents. A CloudWatch alarm on `IncomingBytes` at 5 GB/24h detects traffic anomalies.

Cost is ~$0.75/month at MVP volume. Rationale and the alternatives considered (S3 destination, REJECT-only filter) are in [ADR 0007](decision-records/0007-vpc-flow-logs.md).

---

## 4. Compute design

### 4.1 Instance type

`t4g.micro` (Graviton, `arm64`). 2 vCPU, 1 GiB RAM, ~$6/month on-demand in `us-east-1`.

Graviton is the AWS-recommended default for new Linux workloads. AL2023 has full `arm64` parity, both SSM Agent and CloudWatch Agent ship native `arm64` builds, and the fraud-worker Python runtime and its dependencies compile cleanly for `arm64`. See [ADR 0003](decision-records/0003-amazon-linux-2023-on-graviton.md).

### 4.2 Launch Template

A single Launch Template, `cloudops-dev-lt-workload`, defines:

| Field | Value |
|---|---|
| AMI ID | Resolved from SSM Parameter `/golden-ami/al2023-arm64/latest` |
| Instance type | `t4g.micro` |
| IAM instance profile | `cloudops-dev-iprofile-workload` |
| Key pair | None |
| Security groups | `cloudops-dev-sg-workload` |
| Metadata options | IMDSv2 required, hop limit 1 |
| EBS | 30 GB gp3, encrypted with platform CMK, deleted on termination |
| User data | Minimal: register CloudWatch Agent config, start `fraud-worker.service` |
| Tags | `Project`, `Environment`, `Owner`, `CostCenter`, `ManagedBy`, `Backup=daily`, `Patch=auto`, `Workload=fraud-worker` |

New AMI versions land in the SSM Parameter; deploying them means creating a new Launch Template version and triggering an ASG instance refresh. There is no in-place update path in MVP. This is the immutable-infrastructure pattern, and it's the right answer for a portfolio.

### 4.3 Auto Scaling Group

`cloudops-dev-asg-workload` with `min=desired=max=1`, spanning both private workload subnets.

The ASG is **not** for scaling — the workload doesn't need it. The ASG exists for two reasons:

1. **Self-healing.** When the underlying instance fails an EC2 status check or is terminated, the ASG launches a replacement automatically. The replacement comes up clean from the Golden AMI, registers with SSM, and begins reporting metrics within ~3 minutes. No human in the loop.
2. **Controlled rollout.** Instance refresh with a `MinHealthyPercentage=0` (acceptable because the workload is single-instance) replaces the instance on a new AMI without manual termination.

Health check type is `EC2` in MVP (the workload has no public load balancer to provide ELB health checks). See [ADR 0005](decision-records/0005-asg-min-max-1-for-self-healing.md).

### 4.4 Storage

Single 30 GB gp3 EBS volume per instance, encrypted with the platform CMK. gp3 over gp2: cheaper baseline, higher floor IOPS, and IOPS/throughput are independently configurable. 30 GB is sized for OS + agents + the fraud-worker script and its Python dependencies + 30 days of local logs before CloudWatch Logs rotation handles them.

---

## 5. IAM and security design

### 5.1 Roles

| Role | Trust | Purpose |
|---|---|---|
| `cloudops-dev-role-workload` | `ec2.amazonaws.com` | Instance profile for workload EC2 |
| `cloudops-dev-role-image-builder` | `ec2.amazonaws.com` | Instance profile for Image Builder build instances |
| `cloudops-dev-role-image-builder-distribution` | `imagebuilder.amazonaws.com` | Image Builder distribution |
| `cloudops-dev-role-aws-backup` | `backup.amazonaws.com` | AWS Backup service role |
| `cloudops-dev-role-deploy` (assumed by CI / operator) | Operator account principal | Terraform apply |

### 5.2 Workload role permissions

Attached managed policy: `AmazonSSMManagedInstanceCore`.

Inline policy (least privilege):

- `cloudwatch:PutMetricData` on `*`, conditioned on `cloudwatch:namespace` equals `CloudOpsPlatform/EC2`.
- `logs:CreateLogStream`, `logs:PutLogEvents` on the specific platform log group ARNs only.
- `ssm:GetParameter`, `ssm:GetParameters`, `ssm:GetParametersByPath` on `/cloudops/dev/worker/*`, `/cloudops/dev/app/fraud-worker/*`, and `/cloudops/dev/cloudwatch-agent/*`.
- `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` on the `fraud-transactions` queue ARN only.
- `dynamodb:PutItem`, `dynamodb:GetItem`, `dynamodb:Query` on the `fraud-decisions` table ARN and its `card-velocity-index` GSI only.
- `kms:Decrypt`, `kms:GenerateDataKey` on the platform CMK ARN, conditioned on `kms:ViaService` matching `ec2`, `logs`, `ssm`, `sqs`, or `dynamodb` in `us-east-1`.

No `s3:*`. No `ec2:*`. No `iam:*`. No wildcard resources except where the action requires it (`PutMetricData`).

### 5.3 KMS

One customer-managed symmetric key, `cloudops-dev-cmk-platform`, used for EBS volume encryption, CloudWatch Logs encryption, SSM session log encryption, and AWS Backup vault encryption. Key rotation enabled. See [ADR 0004](decision-records/0004-single-cmk-for-mvp.md).

### 5.4 Security groups

| SG | Inbound | Outbound |
|---|---|---|
| `cloudops-dev-sg-workload` | None | TCP 443 to `cloudops-dev-sg-vpce`; TCP 443 to S3 prefix list |
| `cloudops-dev-sg-vpce` | TCP 443 from `cloudops-dev-sg-workload` | None |

### 5.5 Secrets and configuration

SSM Parameter Store, Standard tier. See [ADR 0006](decision-records/0006-parameter-store-over-secrets-manager.md).

---

## 6. Operations design

### 6.1 Operator access

All access via SSM Session Manager. MFA required. Sessions logged to `/aws/ssm/sessions` with KMS encryption, 30-day retention. See [ADR 0002](decision-records/0002-ssm-only-access.md).

### 6.2 CloudWatch Agent

Config pulled from SSM Parameter `/cloudwatch-agent/config/standard` at boot. Collects `mem_used_percent`, `swap_used_percent`, `disk_used_percent`, `disk_inodes_free` plus application and system logs.

### 6.3 Run Command

| Document | Purpose |
|---|---|
| `cloudops-collect-diagnostics` | Tar `/var/log/`, push to the diagnostics S3 bucket |
| `cloudops-restart-fraud-worker` | `systemctl restart fraud-worker` |
| `cloudops-refresh-cwagent` | Re-fetch CloudWatch Agent config from Parameter Store |
| `cloudops-emergency-patch` | Apply a single named CVE patch outside the Maintenance Window |

#### S3 diagnostics bucket

| Property | Value |
|---|---|
| Name | `cloudops-dev-s3-diagnostics-<accountid>` |
| Encryption | SSE-KMS with platform CMK |
| Public access block | All four settings: `true` |
| Versioning | Enabled |
| Lifecycle | Auto-delete objects after 30 days |
| Bucket policy | Denies `s3:*` for non-TLS requests; restricts `PutObject` to workload role |

### 6.4 Patch Manager

Baseline: `Security` + `Critical` severity for AL2023. Maintenance Window: Sunday 06:00 UTC. Tag target: `Patch=auto`.

---

## 7. Observability design

### 7.1 Metrics

Native EC2 + CloudWatch Agent custom namespace `CloudOpsPlatform/EC2`: `mem_used_percent`, `swap_used_percent`, `disk_used_percent`, `disk_inodes_free`.

### 7.2 Logs

| Log Group | Retention | Encryption |
|---|---|---|
| `/aws/ec2/fraud-worker/system` | 30 days | Platform CMK |
| `/aws/ec2/fraud-worker/app` | 30 days | Platform CMK |
| `/aws/ec2/fraud-worker/audit` | 30 days | Platform CMK |
| `/aws/ssm/sessions` | 30 days | Platform CMK |
| `/aws/vpc/flowlogs` | 14 days | Platform CMK |

### 7.3 Alarms

| Alarm | Threshold | Action |
|---|---|---|
| `cpu-high` | > 85% for 10 min | SNS |
| `status-check-failed` | >= 1 for 2 datapoints | SNS |
| `disk-root-high` | > 85% | SNS |
| `mem-high` | > 90% for 10 min | SNS |
| `cwagent-missing` | no metrics for 15 min | SNS |
| `backup-job-failed` | any failure | SNS |

### 7.4 Alerting

EventBridge → SNS: ASG workload instance termination (scoped to `cloudops-dev-asg-workload` — EC2 state-change events don't carry tags so the filter uses the ASG event source instead), SSM Run Command failure, AWS Backup job failure, KMS key deletion, break-glass role assumption. CloudWatch alarms → SNS. Email subscription in MVP.

---

## 8. Backup and recovery

Full strategy in [`backup-strategy.md`](backup-strategy.md).

| Property | Value |
|---|---|
| Vault | `cloudops-dev-vault-platform` (KMS-encrypted, single operational vault) |
| Frequency | Daily, 05:00 UTC, tag `Backup=daily` |
| Lifecycle | Warm 7 days → cold (90-day minimum) → delete day 98 |
| RPO target | 24 hours |
| RTO target | 1 hour (in-region single-volume restore) |
| Vault Lock | Evaluated and excluded — see `backup-strategy.md` Section 5 |

---

## 9. Golden AMI strategy

EC2 Image Builder pipeline `cloudops-dev-ibpipe-golden-al2023-arm64`. Monthly schedule + on-demand. Base: AL2023 arm64. Components: `update-linux`, CIS baseline, CloudWatch Agent install, fraud-worker install (script + systemd unit), cleanup. Validation tests confirm the service unit is enabled and the script is executable before publish. AMI ID written to SSM Parameter `/cloudops/dev/golden-ami/al2023-arm64/latest`.

---

## 10. Cost control

See [`cost-model.md`](cost-model.md). Total ~$54.80/month. Largest driver: VPC Interface Endpoints (~$36.50/month). AWS Budgets alerts at 50/80/100% of $100 ceiling.

---

## 11. Known design gaps

- No Config / GuardDuty / Security Hub (Phase 2)
- CloudTrail assumed, not built (prerequisite)
- No Vault Lock (evaluated, excluded, documented)
- Single-region only
- Operator IAM upstream
- Single CMK (ADR 0004)
- No Inspector in AMI pipeline (Phase 2)
- No Slack/PagerDuty (Phase 2)

---

## 12. Where to look next

- **Runbooks:** [`../runbooks/`](../runbooks/)
- **ADRs:** [`decision-records/`](decision-records/)
- **Cost details:** [`cost-model.md`](cost-model.md)
- **Security baseline:** [`security-baseline.md`](security-baseline.md)
- **Threat model:** [`threat-model.md`](threat-model.md)
- **Backup strategy:** [`backup-strategy.md`](backup-strategy.md)
- **Naming conventions:** [`naming-conventions.md`](naming-conventions.md)
- **Tagging strategy:** [`tagging-strategy.md`](tagging-strategy.md)
- **Diagrams:** [`diagrams/`](diagrams/)
- **Terraform:** [`../terraform/`](../terraform/)
