# Backup Strategy

Authoritative source for backup architecture, lifecycle, immutability evaluation, and recovery analysis. [`architecture.md`](architecture.md) Section 8 links here.

---

## 1. Goals

- Recover from accidental data loss within a 24-hour RPO.
- Recover from instance or volume failure within a 1-hour RTO.
- Encrypt all recovery points with the customer-managed platform CMK.
- Stay within the platform's monthly cost budget.

**Non-goals:** Multi-region DR, Vault Lock, long-term archival (>97 days).

---

## 2. Architecture

### 2.1 Single operational vault

`cloudops-dev-vault-platform`

| Property | Value |
|---|---|
| Encryption | Platform CMK |
| Vault access policy | Denies `backup:DeleteRecoveryPoint` to all principals except `cloudops-dev-role-break-glass` |
| Vault Lock | Not enabled — see Section 5 |
| Cross-region copy | None (Phase 2) |

Single-vault rationale: a second compliance vault was evaluated and rejected. Without Vault Lock, a second vault is functionally redundant — same protection level, doubled storage cost, no new defensive property.

### 2.2 Backup plan

`cloudops-dev-bp-daily`

| Property | Value |
|---|---|
| Frequency | Daily, 05:00 UTC |
| Selection | Tag-based: `Backup=daily` |
| Lifecycle | Warm 7 days → cold day 8 → delete day 98 |
| Vault | `cloudops-dev-vault-platform` |
| Failure notification | EventBridge → SNS on job `FAILED`, `EXPIRED`, `ABORTED` |

### 2.3 Lifecycle rationale

| Tier | Duration | Cost (per GB-month) | Why |
|---|---|---|---|
| Warm | Days 1–7 | $0.05 | Covers most "I need yesterday's data" cases |
| Cold | Days 8–97 | $0.0125 | Long-tail recoveries; ~4× cheaper than warm |
| Delete | Day 98+ | $0 | No regulatory retention requirement beyond this |

**Note:** AWS Backup requires a minimum of 90 days in cold storage when cold tier is used. Effective lifecycle: warm 7d + cold minimum 90d = 97 days total retention.

Estimated steady-state storage with daily snapshots, 30 GB volume, ~5% daily change rate: **~$3–4/month**.

---

## 3. What gets backed up

| Resource | Backed up? | Mechanism |
|---|---|---|
| EBS volumes on workload instances | Yes (daily) | AWS Backup, tag selection |
| Golden AMI | No | Image Builder versioned outputs |
| SSM Parameter Store values | No | Terraform state |
| CloudWatch log content | No | Log group retention handles lifecycle |
| Terraform state | Yes | Remote state with versioning (S3 + DynamoDB lock) |

---

## 4. Vault access protection

### 4.1 Vault access policy

Denies destructive operations to all principals except break-glass role: `backup:DeleteBackupVault`, `backup:DeleteRecoveryPoint`, `backup:UpdateRecoveryPointLifecycle`, `backup:PutBackupVaultAccessPolicy`, `backup:DeleteBackupVaultAccessPolicy`.

### 4.2 KMS key deletion risk

If the platform CMK is deleted, every recovery point in the vault becomes permanently unrecoverable. Mitigations:

- Deploy role IAM policy does **not** grant `kms:ScheduleKeyDeletion` on the platform CMK.
- EventBridge rule fires on any `kms:ScheduleKeyDeletion` event for the platform CMK → SNS alert. Provides the 7-day waiting window to cancel.
- Break-glass role has the action, but usage is logged and triggers separate alerts.

---

## 5. Vault Lock evaluation (excluded from MVP)

### 5.1 The two modes

**Governance mode:** Lock can be removed by principals with `backup:DeleteBackupVaultLockConfiguration`. Protects against accidental deletion, not malicious deletion by a privileged principal.

**Compliance mode:** Lock cannot be removed once the cooling-off period expires. Even the AWS account root cannot delete recovery points before their retention expires.

### 5.2 Why neither was chosen for MVP

**Governance mode:** The threat it defends against (privileged principal deleting backups) is already addressed by the vault access policy. Adding a lock adds operational surface without doubling protection.

**Compliance mode:** Creates a teardown problem for a lab environment. With this MVP's lifecycle (warm 7d + cold 90d), the vault cannot be destroyed until the longest retention expires — a 97-day commitment with associated storage costs. Unacceptable for a portfolio project that may be rebuilt.

### 5.3 When Vault Lock should be added

- Workload handles regulated data (PCI, PHI, financial records under SEC/FINRA).
- Audit requirement specifies cryptographic immutability.
- Environment is permanent (not a lab).
- Two-person operational controls exist for vault management.

**Implementation:** Small. `aws_backup_vault_lock_configuration` in Terraform. Complexity is operational, not technical.

### 5.4 Residual risk of no Vault Lock

- A compromised principal with vault + IAM permissions can modify the vault access policy, then delete recovery points. EventBridge alerts on policy change give detection but not prevention.
- A malicious break-glass principal can delete recovery points. This is the residual risk of any system with a break-glass mechanism.

---

## 6. Restore drill (quarterly)

Runbook: `runbooks/03-restore-from-backup.md`

1. Identify latest recovery point in the vault.
2. Restore to new EBS volume in dev VPC, encrypted with platform CMK.
3. Launch temporary `t4g.micro` from current Golden AMI in dev subnet.
4. Stop instance, detach root volume, attach restored volume as `/dev/sdf`.
5. Start instance, mount restored volume, validate file presence and integrity (sha256 sums).
6. Capture observed RTO from "restore initiated" to "data verified."
7. Terminate temporary instance, delete restored volume.
8. Record in quarterly log: date, recovery point ID, observed RTO, issues encountered.

---

## 7. RPO and RTO

**RPO target:** 24 hours. Appropriate for a stateless workload with no business data to lose between snapshots.

**RTO target:** 1 hour. Realistic for single-volume restore from cold: ~10 min to provision volume, ~10 min for instance launch, ~30 min buffer.

### Tighter targets would require

| Target | Mechanism | Cost impact |
|---|---|---|
| RPO 1 hour | Hourly snapshots via DLM or AWS Backup | ~$5–10/month additional |
| RTO < 30 min | Pre-provisioned standby in second AZ | ~2× compute cost |
| RTO < 5 min | Active-active across AZs | ~2–3× compute + load balancer |

---

## 8. Recovery Analysis

### 8.1 Failure scenarios

| Scenario | Recovery mechanism | Observed RTO | RPO impact |
|---|---|---|---|
| EC2 instance status check failure | ASG replaces from Golden AMI | ~3–5 min | None |
| AZ failure | ASG launches in second AZ | ~5–10 min | None |
| Application crash/hang | systemd restart, then Run Command | <2–10 min | None |
| EBS volume corruption / accidental detach | AWS Backup restore | ~1 hour | Up to 24 hours |
| Accidental Terraform destroy | `terraform apply` rebuilds; backups retained | ~30 min | None |
| Malicious backup deletion | Vault access policy denies; break-glass required | N/A | If break-glass abused: total loss |
| Region-wide AWS outage | **No automated mitigation in MVP** | Hours to days | Depends on outage duration |
| KMS CMK deleted | EventBridge alert allows 7-day cancellation | If completed: catastrophic | All backups unrecoverable |

### 8.2 Production deployment recommendations (priority order)

1. **Cross-region backup copy (highest priority)** — Copy recovery points to `us-west-2`. Cost: ~2× backup storage + copy charges (~$0.02/GB). Effort: one Terraform resource. This is the single highest-value addition.

2. **Region failover runbook** — Document procedure to rebuild from Terraform + restored backups in secondary region. Cost: $0.

3. **Multi-AZ workload (`min=2`)** — Eliminates brief downtime during replacement. Cost: ~2× compute (~$6/month). Only justified if workload becomes customer-facing.

4. **Tighter RPO via hourly snapshots** — Only worth it if workload develops persistent state.

5. **Vault Lock (compliance mode)** — When workload becomes subject to regulatory immutability requirements.

### 8.3 What this analysis is not

Not a Business Impact Analysis (BIA), not a comprehensive DR plan, not a substitute for a DR drill. Level of analysis is calibrated to "production-pattern reference for a portfolio" — demonstrates the patterns and trade-offs without inflating into a separate project.

---

## 9. Summary

- Single operational vault, CMK-encrypted, vault access policy protection.
- Daily backups, 7-day warm + 90-day cold minimum, delete at day 98.
- Vault Lock evaluated and excluded with documented rationale and production-deployment trigger.
- 24-hour RPO, 1-hour RTO targets with justified cost trade-offs.
- Quarterly manual restore drill, runbook-driven.
- Recovery analysis covers in-region failures; multi-region DR is a documented gap with clear production recommendations.
