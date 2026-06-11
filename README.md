# fraud-detection-aws-platform

A production-grade fraud detection platform built on AWS, running a real-time fraud transaction scoring worker in private EC2 subnets with no public SSH, no bastion hosts, and no key pairs. Operator access is exclusively through SSM Session Manager over VPC Interface Endpoints. The fraud worker reads transactions from SQS, applies scoring rules, and persists decisions to DynamoDB — running on hardened Golden AMIs produced by EC2 Image Builder, encrypted with a customer-managed KMS key, monitored with the CloudWatch Agent, and protected by AWS Backup.

Designed as a production-pattern reference for financial workloads requiring strict isolation and auditability. Targets under $100/month in `us-east-1`.

---

## Why this exists

Most public examples for "EC2 on AWS" still teach SSH key pairs, public bastions, and `0.0.0.0/0` security group rules. That pattern carries operational debt — key rotation, audit gaps, brute-force exposure, bastion sprawl — that doesn't belong in a 2026 environment. This project demonstrates the alternative as it is actually built in well-run AWS shops:

- No inbound network access to workload instances.
- Identity-based access through IAM and SSM, fully audited, encrypted, MFA-gated.
- Immutable infrastructure via Golden AMIs and Launch Templates.
- Self-healing through an Auto Scaling Group sized at `min=max=2`.
- Encryption everywhere with a customer-managed KMS key.
- Backups with cold-storage lifecycle and a documented restore drill.
- Cost held under $100/month through deliberate trade-offs (no NAT Gateway, single CMK, Graviton compute).

The platform runs a fraud transaction scoring worker — a Python service that polls an SQS queue, evaluates transaction risk, and writes fraud decisions to DynamoDB — giving the runbooks, alarms, and automation something real to operate on.

---

## Architecture

```mermaid
flowchart LR
    OPS["👤 Operator"]
    GHA["🛠️ GitHub Actions"]

    subgraph AWS ["☁️ AWS Cloud · us-east-1"]
        direction LR

        subgraph ACCESS ["🔐 Access & CI/CD"]
            direction TB
            SSM["Systems Manager\nSession Manager"]
            IMG["📦 Image Builder\nGolden AMI · AL2023 arm64"]
        end

        subgraph VPCNET ["🌐 VPC 10.20.0.0/16 · Private App Subnet"]
            direction TB
            EP["🔗 VPC Endpoints\nSSM·SQS·CloudWatch·DynamoDB"]
            SQS["📨 SQS\nfraud-transactions"]
            EC2["⚙️ EC2 / ASG\nfraud-worker arm64 · desired=2"]
            FIS["💥 FIS\nterminate-one-instance"]
        end

        subgraph DATA ["🗄️ Data"]
            direction TB
            DDB["📊 DynamoDB\nfraud-decisions"]
            BCK["🗃️ AWS Backup\nvault + daily plan"]
        end

        subgraph SECOBS ["🛡️ Security & Observability"]
            direction TB
            KMS["🔑 KMS · CMK"]
            INS["🔍 Inspector v2"]
            GRD["🚨 GuardDuty"]
            CW["📉 CloudWatch\nAlarms & Dashboards"]
        end

        subgraph ALERT ["🔔 Alerting"]
            direction TB
            EVB["⚡ EventBridge\nAlert Rules"]
            SNS["📣 SNS\ncloudops-alerts"]
            LAM["λ Lambda\nslack-notify · Py 3.12"]
        end
    end

    SLACK["💬 Slack"]

    %% ---- Numbered flows ----
    GHA  -->|"7 · OIDC + Terraform apply"| SSM
    OPS  -->|"1 · SSM Session (no SSH/bastion)"| SSM
    SSM  --> EP
    SQS  -->|"2 · poll transactions"| EC2
    EC2  -->|"3 · write decision via gateway EP"| DDB
    GRD  -->|"4 · HIGH/CRITICAL findings"| EVB
    SNS  -->|"5a · publish to subscriber"| LAM
    LAM  -->|"5b · webhook POST"| SLACK
    FIS  -->|"6 · chaos terminate"| EC2
    IMG  -->|"8 · publish Golden AMI"| EC2
    INS  -->|"continuous CVE scan"| EC2
    BCK  -->|"daily backup"| DDB
    EC2  -->|"CPU/mem/health metrics"| CW
    CW   -->|"alarm breach → alert"| SNS
    EVB  -->|"alert rule → routes to SNS"| SNS
    KMS  -.->|encrypts| SQS
    KMS  -.->|encrypts| DDB

    classDef compute fill:#ED7100,stroke:#232F3E,color:#fff
    classDef queue fill:#FF4F8B,stroke:#232F3E,color:#fff
    classDef db fill:#7B16FF,stroke:#232F3E,color:#fff
    classDef sec fill:#DD344C,stroke:#232F3E,color:#fff
    classDef obs fill:#1A9C3E,stroke:#232F3E,color:#fff
    classDef notify fill:#E7157B,stroke:#232F3E,color:#fff
    classDef ext fill:#232F3E,stroke:#FF9900,color:#fff
    class EC2,FIS compute
    class SQS queue
    class DDB,BCK db
    class KMS,GRD,INS,IMG sec
    class CW obs
    class EVB,SNS,LAM notify
    class OPS,GHA,SLACK ext
```

A higher-fidelity network and IAM diagram lives in [`docs/diagrams/`](docs/diagrams/). Full architecture detail is in [`docs/architecture.md`](docs/architecture.md).

---

## What this platform does

| Capability | How |
|---|---|
| Operator shell access | SSM Session Manager over VPC Interface Endpoints, MFA-required, fully logged to CloudWatch |
| Ad-hoc and scheduled operations | SSM Run Command with versioned documents |
| Configuration management | SSM Parameter Store (Standard tier, SecureString where needed) |
| Patching | Immutable — OS patches baked into Golden AMIs via EC2 Image Builder; running instances replaced via ASG refresh, never patched in place |
| Observability | CloudWatch Agent (system + custom metrics), CloudWatch Logs, alarms on CPU/memory/disk/status, dashboard |
| Alerting | CloudWatch Alarms + EventBridge → SNS → email + Slack; events: EC2 state change, SSM Run Command failure, Backup job failure, KMS key deletion, break-glass role assumption |
| Threat detection | GuardDuty with S3 log analysis and EC2 malware scanning; HIGH/CRITICAL findings (severity ≥ 7) routed via EventBridge → SNS → Slack + email |
| Vulnerability scanning | Amazon Inspector v2 continuously scans running EC2 instances for OS-level CVEs; findings visible in Inspector console and Security Hub |
| CI/CD | GitHub Actions with OIDC federation — no static credentials; `terraform plan` posted as PR comment, `terraform apply` on merge to main |
| AMI quality gate | ARM64 Python validation in Image Builder — verifies aarch64 runtime and all fraud-worker stdlib patterns before AMI is published; broken AMIs never reach the fleet |
| Chaos engineering | AWS Fault Injection Service experiment terminates one ASG instance to validate self-healing — ASG replaces the instance in under 2 minutes; experiment logs to KMS-encrypted CloudWatch Log Group |
| Backup and recovery | AWS Backup, daily snapshots, 7d warm + 30d cold, KMS-encrypted vault |
| Fraud transaction processing | SQS queue → EC2 fraud-worker (Python) → DynamoDB; zero-downtime ASG rolling updates |
| Poison-message handling | SQS Dead Letter Queue — messages failing 3× (DynamoDB write errors) are moved to DLQ automatically; CloudWatch alarm fires when DLQ depth > 0 |
| Immutable infrastructure | EC2 Image Builder produces Golden AL2023 arm64 AMIs; Launch Template references the AMI ID via SSM Parameter |
| Self-healing | Auto Scaling Group `min=max=2` across two AZs replaces failed instances automatically |
| Encryption | Customer-managed KMS key for EBS, CloudWatch Logs, AWS Backup vault, SSM session logs |

---

## How to navigate this repo

If you are reviewing this as a hiring signal or technical reference, start here:

| Step | What to read | Time |
|---|---|---|
| 1 | This README — problem statement, capabilities, cost | 5 min |
| 2 | [`docs/architecture.md`](docs/architecture.md) — full system design, network, IAM, observability | 15 min |
| 3 | [`docs/decision-records/`](docs/decision-records/) — ADRs 0001–0010, the non-obvious choices | 10 min |
| 4 | [`terraform/modules/`](terraform/modules/) — 13 modules, each with a single responsibility | 10 min |
| 5 | [`runbooks/`](runbooks/) — 5 operational procedures written for on-call use | 10 min |

The ADRs are the highest-density read for architecture signal. The runbooks show operational maturity. The modules show IaC discipline.

---

## Cost summary

| Item | Estimate (monthly, us-east-1) |
|---|---|
| 2 × `t4g.micro` EC2 (730h, on-demand) | ~$12.00 |
| 2 × EBS gp3 30 GB encrypted | ~$4.80 |
| 5 × VPC Interface Endpoints | ~$36.50 |
| CloudWatch Logs (1 GB ingest, 7-day retention) | ~$0.55 |
| CloudWatch metrics + alarms | ~$1–2 |
| CloudWatch Dashboard (×1) | ~$3.00 |
| AWS Backup (~60 GB warm + cold) | ~$4–6 |
| KMS CMK | ~$1.00 |
| EC2 Image Builder (~1 build/month, t3.medium minutes) | <$1.00 |
| SQS (low volume) | ~$0 |
| DynamoDB (on-demand, low volume) | ~$0 |
| SNS (email, low volume) | ~$0 |
| **Total** | **~$65–72/month** |

Detailed cost model and the avoided-cost decisions are in [`docs/cost-model.md`](docs/cost-model.md).

The single largest line item is VPC Interface Endpoints. Forgetting to destroy the environment is the failure mode; an AWS Budgets alert at 50% / 80% / 100% of the $100 ceiling is part of the deploy.

---

## Repository layout

```text
.
├── README.md                       # This file
├── LICENSE
├── Makefile                        # make validate / plan / apply / destroy
├── .github/workflows/              # CI: terraform fmt, validate, tflint, checkov
├── terraform/
│   ├── envs/dev/                   # Environment composition root
│   └── modules/                    # vpc, vpc-endpoints, kms, iam-roles,
│                                   # ec2-workload, worker-infra,
│                                   # image-builder, observability, backup
├── docs/
│   ├── architecture.md             # Full design document
│   ├── cost-model.md
│   ├── security-baseline.md
│   ├── threat-model.md
│   ├── decision-records/           # ADRs
│   └── diagrams/                   # Mermaid + PlantUML sources
├── runbooks/                       # Operational procedures
├── scripts/                        # Bootstrap configs, validation
└── assets/screenshots/             # Console screenshots for docs
```

Naming convention: `<project>-<env>-<resource>-<purpose>` (e.g., `cloudops-dev-sg-workload`, `cloudops-dev-vpce-ssm`). Required tags on every taggable resource: `Project`, `Environment`, `Owner`, `CostCenter`, `ManagedBy`, plus `Backup` and `Patch` where applicable.

---

## Documentation

The repository's documentation is structured for two audiences: a quick recruiter pass (this README + the architecture overview), and a deep technical review (the rest).

| Document | Purpose |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Full design — networking, compute, IAM, observability, backup, AMI strategy, known gaps |
| [`docs/cost-model.md`](docs/cost-model.md) | Detailed cost breakdown, drivers, services intentionally avoided, budget guardrails |
| [`docs/security-baseline.md`](docs/security-baseline.md) | Consolidated security controls mapped to AWS Well-Architected and CIS Foundations |
| [`docs/threat-model.md`](docs/threat-model.md) | STRIDE-aligned threat enumeration, residual risks, scope gaps |
| [`docs/backup-strategy.md`](docs/backup-strategy.md) | Backup plan, vault protection, Vault Lock evaluation, recovery analysis |
| [`docs/naming-conventions.md`](docs/naming-conventions.md) | Resource naming standard with type abbreviations and special cases |
| [`docs/tagging-strategy.md`](docs/tagging-strategy.md) | Required + functional tags, IAM tag conditions, Terraform `default_tags` |
| [`docs/decision-records/`](docs/decision-records/) | ADRs — the non-obvious choices and why |
| [`docs/diagrams/`](docs/diagrams/) | Mermaid + PlantUML source for architecture, network, data-flow, IAM-trust diagrams |

---

## Architecture decisions

The non-obvious choices are documented as ADRs in [`docs/decision-records/`](docs/decision-records/):

1. [No NAT Gateway in MVP](docs/decision-records/0001-no-nat-gateway.md)
2. [SSM-only access — no SSH, no bastion](docs/decision-records/0002-ssm-only-access.md)
3. [Amazon Linux 2023 on Graviton (`arm64`)](docs/decision-records/0003-amazon-linux-2023-on-graviton.md)
4. [Single customer-managed KMS key for MVP](docs/decision-records/0004-single-cmk-for-mvp.md)
5. [Auto Scaling Group `min=max=2` for self-healing and zero-downtime updates](docs/decision-records/0005-asg-min-max-1-for-self-healing.md)
6. [Parameter Store over Secrets Manager](docs/decision-records/0006-parameter-store-over-secrets-manager.md)
7. [VPC Flow Logs to CloudWatch Logs](docs/decision-records/0007-vpc-flow-logs.md)
8. [SQS + DynamoDB for fraud worker persistence](docs/decision-records/0008-sqs-dynamodb-for-fraud-worker.md)
9. [ASG min=2 for zero-downtime rolling updates](docs/decision-records/0009-asg-min2-zero-downtime.md)
10. [Static ASG capacity vs target-tracking auto-scaling](docs/decision-records/0010-static-asg-vs-target-tracking.md)

---

## Status and roadmap

**MVP + Phase 6 (this repo, current scope):**
VPC + endpoints, KMS, IAM, ASG-managed EC2 (min=max=2) with Golden AMI, fraud transaction worker (SQS → EC2 → DynamoDB), CloudWatch Agent + alarms, AWS Backup, EventBridge → SNS → email + Slack, SSM session logging, immutable patching via Image Builder (ARM64 Python validation gate), AWS Budgets, OIDC-based GitHub Actions CI/CD, GuardDuty threat detection, Inspector v2 vulnerability scanning, FIS chaos engineering, runbooks, ADRs.

**Phase 6 — fully complete:**

- ✅ OIDC-based GitHub Actions pipeline — `terraform plan` on PR, `terraform apply` on merge to main; two IAM roles (read-only plan, admin apply) scoped to exact OIDC sub claims; no static credentials.
- ✅ GuardDuty module — detector enabled with S3 + malware protection; EventBridge routes HIGH/CRITICAL findings (severity ≥ 7) to platform SNS topic.
- ✅ AWS Budgets — monthly $100 ceiling with alerts at 50%, 80%, 100%; managed as Terraform resource.
- ✅ SNS → Slack — Lambda function subscribed to platform SNS topic; formats CloudWatch alarms and GuardDuty findings; webhook URL stored encrypted via CMK.
- ✅ ARM64 Python validation gate — Image Builder component verifies python3 runs on aarch64 and all fraud-worker stdlib patterns execute correctly before AMI is published.
- ✅ Inspector v2 — continuous EC2 vulnerability scanning for OS-level CVEs; enabled at account level via Terraform.
- ✅ FIS chaos engineering — experiment template terminates one ASG instance; validates self-healing under `min=max=2`; experiment logs to KMS-encrypted CloudWatch Log Group.

**Phase 2+ (enterprise scale, out of scope for this repo):**

- Transit Gateway + Shared Services VPC to consolidate Interface Endpoints across multiple workload VPCs.
- AWS Config conformance pack.
- Cross-account / cross-region Backup Vault Lock.
- Inspector vulnerability scanning in Image Builder.
- Chaos Engineering via AWS Fault Injection Service to validate ASG recovery under load.
- OpenSearch / SIEM integration for CloudWatch Logs at enterprise scale.

**Explicit non-goals:**
A managed database (no application use case), Kubernetes (out of scope for an EC2-pattern reference), dynamic target-tracking ASG scaling (documented in [ADR 0010](docs/decision-records/0010-static-asg-vs-target-tracking.md)).

---

## Account setup

This repo deploys into a **workload account** (`Portfolio`) inside an AWS Organizations structure. The organization layout assumed:

```text
Management account (460997080963)
└── Workloads OU
    └── Portfolio account (776648109094)  ← deploy target
```

Account-level controls configured outside Terraform (one-time setup):

- IAM Identity Center with `AdminFullAccess` and `ReadOnlyAccess` permission sets
- Organization CloudTrail (multi-region, centralized in Management account S3 bucket)
- SCP `deny-non-us-regions` on Workloads OU — permits `us-east-1`, `us-east-2`, `us-west-1`, `us-west-2` only
- AWS Budgets alert at 80% of $100/month ceiling

## Prerequisites assumed

- AWS Organizations structure as above, with IAM Identity Center configured.
- Active SSO session for the Portfolio account (`aws sso login --profile <profile>`).
- Terraform `>= 1.6`, AWS provider `>= 5.x`.
- AWS CLI v2 with the Session Manager plugin installed locally.

## Deploy flow

```bash
# 0. Authenticate — SSO session must be active
aws sso login --profile cloudops-portfolio

# 1. Bootstrap — one-time: creates S3 backend + DynamoDB lock table
cd terraform/bootstrap && terraform init && terraform apply
cd -

# 2. Configure
cp terraform/envs/dev/terraform.tfvars.example terraform/envs/dev/terraform.tfvars
# Edit terraform.tfvars:
#   alert_email  = "your@email.com"
#   ami_id       = "ami-..."   # current AL2023 arm64 AMI (see tfvars.example for lookup command)

# 3. Static validation — no AWS credentials required
make validate

# 4. Plan and apply
make plan
make apply

# 5. Verify the platform is healthy
./scripts/validation/post-deploy-checks.sh <instance-id> us-east-1

# Teardown — full clean destroy
# IMPORTANT: delete the Backup vault access policy BEFORE running destroy.
# The vault policy restricts DeleteRecoveryPoint to the break-glass role only.
# If the role is destroyed before the vault is empty, manual recovery via AWS Support is required.
# See docs/decision-records/0010 and the Phase 6 fix for this pattern.
make destroy
cd terraform/bootstrap && terraform destroy
```

---

## Contact

- **GitHub:** [@Rafagross](https://github.com/Rafagross)
- **LinkedIn:** [erafael-gross](https://www.linkedin.com/in/erafael-gross)
- **Email:** *(available on LinkedIn)*

Open to feedback. If you're reviewing this as a hiring signal, the architecture document and ADRs are the highest-density read.

---

## License

[MIT](LICENSE)
