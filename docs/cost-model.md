# Cost Model

This document explains the cost structure of the platform, the deliberate trade-offs that keep it under $100/month, and the operational guardrails that prevent cost surprises.

---

## 1. Summary

| Item | Estimate (monthly, us-east-1) | Notes |
|---|---|---|
| `t4g.micro` EC2 (730h, on-demand) | ~$6.00 | Single instance, ASG-managed |
| EBS gp3 30 GB encrypted | ~$2.40 | $0.08/GB/month base |
| 5 × VPC Interface Endpoints | ~$36.50 | $7.30/endpoint base + data |
| S3 Gateway Endpoint | $0.00 | Free |
| CloudWatch Logs ingestion | ~$0.50 | ~1 GB/month at $0.50/GB |
| CloudWatch Logs storage | ~$0.05 | ~1 GB at $0.03/GB/month, 7-day retention |
| CloudWatch metrics + alarms | ~$1.50 | Custom metrics + 6 alarms |
| CloudWatch Dashboard (×1) | ~$3.00 | Flat fee |
| AWS Backup (snapshot storage) | ~$3.00 | ~30 GB warm/cold mix |
| KMS CMK | ~$1.00 | $1/key + minor request cost |
| EC2 Image Builder | ~$0.50 | One build/month, ~10 min t3.medium |
| SNS (email) | ~$0.00 | Below free tier |
| VPC Flow Logs to CloudWatch | ~$0.75 | ~1.5 GB/month |
| S3 (diagnostics bucket) | ~$0.10 | <1 GB, lifecycle to delete in 30 days |
| **Total** | **~$54.80/month** | |

---

## 2. Cost drivers, ranked

### 2.1 VPC Interface Endpoints (~67% of monthly cost)

The single largest line item. Each interface endpoint costs **$0.01/hour ≈ $7.30/month** in `us-east-1`. Five endpoints = **$36.50/month base** before any traffic.

This is non-negotiable: without these endpoints, private instances cannot reach the SSM control plane or ship telemetry, and the alternative (NAT Gateway) is more expensive and weakens security posture (see [ADR 0001](decision-records/0001-no-nat-gateway.md)).

**Failure mode to avoid:** Forgetting to destroy the dev environment is the #1 cost risk. Endpoints accrue 24/7 whether or not anything is running. Mitigation: AWS Budgets alerts (Section 4) and a `make destroy` shortcut in the Terraform layer.

KMS interface endpoint is **deliberately excluded**. KMS calls from the workload are server-side (via EBS, CloudWatch Logs, AWS Backup), not direct from the instance. Adding it would cost ~$7.30/month for no measurable benefit.

### 2.2 EC2 + EBS (~15%)

`t4g.micro` on-demand: ~$6/month. Graviton chosen for ~20% savings over `t3.micro` (see [ADR 0003](decision-records/0003-amazon-linux-2023-on-graviton.md)). gp3 over gp2: cheaper baseline ($0.08 vs $0.10/GB/month), decoupled IOPS/throughput.

Reserved Instances not used: the project may be torn down; on-demand is correct for a portfolio lab.

### 2.3 CloudWatch (~10%)

**Logs ingestion ($0.50/GB):** Variable. The failure mode is a runaway application logging in a tight loop — a misconfigured app can ingest 100 GB/day at $50/day. Mitigation: alarm on `IncomingBytes` per log group (Section 5).

**Logs storage ($0.03/GB/month):** Controlled by retention settings. Audit and session logs get longer retention (30 days) because their forensic value outlasts ordinary application logs (7 days).

**Metrics + Alarms:** ~$1.50/month for 6 alarms and ~5 custom metrics.

### 2.4 AWS Backup (~5%)

Snapshots are incremental. Steady-state cost for a 30 GB volume with ~5% daily change rate, warm 7d + cold 90d lifecycle: **~$3/month**.

Restore cost from cold: $0.03/GB. For a 30 GB volume, ~$0.90 per restore. Negligible for quarterly drills.

### 2.5 Everything else (~3%)

KMS ($1/key), Image Builder (~$0.50/month for one monthly build), SNS (free at this volume), VPC Flow Logs (~$0.75/month), S3 diagnostics bucket (<$0.10).

---

## 3. Services explicitly avoided and why

| Service | Cost if added | Why excluded |
|---|---|---|
| NAT Gateway | ~$33/month + data | No internet egress needed at runtime ([ADR 0001](decision-records/0001-no-nat-gateway.md)) |
| KMS Interface Endpoint | ~$7.30/month | Workload's direct KMS API call volume is negligible |
| AWS Secrets Manager | ~$0.40/secret/month | Parameter Store SecureString covers MVP needs ([ADR 0006](decision-records/0006-parameter-store-over-secrets-manager.md)) |
| GuardDuty | ~$5–10/month | Phase 2 |
| AWS Config | ~$2/resource/month | Phase 2; Terraform `default_tags` covers required-tags use case for free |
| Security Hub | ~$5–10/month | Phase 2 |
| Inspector | ~$1–2/month | Phase 2; slots into Image Builder pipeline |
| RDS / DynamoDB | $13+/month minimum | No application use case; `heartbeat-api` is stateless |
| Application Load Balancer | ~$16/month | No public-facing component |

**Total cost avoided: ~$80–120/month.** That margin is what makes this design defensible at the $100 ceiling.

---

## 4. Budget guardrails

Three AWS Budgets alarms:

| Threshold | Action |
|---|---|
| 50% ($50) | SNS notification — informational |
| 80% ($80) | SNS notification — investigate now |
| 100% ($100) | SNS notification — destroy non-essential resources |

Budgets are informational only. They do not stop spend. Hard caps require Lambda automation or AWS Service Quotas — Phase 2.

---

## 5. CloudWatch Logs runaway protection

Log ingestion is the highest-volatility cost. A misbehaving application can flip the monthly cost from $1 to $50 in a day.

Alarms per log group on `IncomingBytes`:

| Log Group | Threshold | Normal baseline |
|---|---|---|
| `/aws/ec2/heartbeat-api/app` | > 500 MB / 24h | ~30 MB/day |
| `/aws/ec2/heartbeat-api/system` | > 200 MB / 24h | ~10 MB/day |
| `/aws/vpc/flowlogs` | > 5 GB / 24h | ~50 MB/day |

First response: SSM Session Manager connect, log file inspection, service restart via Run Command, or temporary log-level change via Parameter Store.

---

## 6. Sizing assumptions

- One workload instance, ASG `min=max=1`.
- Application generates ~30 MB/day of logs.
- Daily backup of ~30 GB EBS with ~5% daily change rate.
- SSM session usage: <2 hours/month total.
- Image Builder: one build/month.

---

## 7. Cost vs. compliance trade-offs

| Capability | Cost | Appropriate when |
|---|---|---|
| Cross-region backup copy | ~2× backup storage | Regulatory geographic separation requirement |
| Vault Lock (compliance mode) | $0 incremental + lifecycle commitment | SEC 17a-4, FINRA, similar immutability requirements |
| AWS Config + conformance pack | ~$2/resource/month | Multi-account governance, audit trail requirement |
| GuardDuty + Security Hub | ~$10–20/month | Continuous threat detection requirement |
| Multi-AZ workload (min=2) | ~2× compute cost | RTO < 5 minutes, customer-facing availability |

The MVP excludes all of the above on the grounds that the project's stated purpose is a production-pattern reference under $100/month, not a regulated production workload.
