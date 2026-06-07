# Threat Model

A lightweight STRIDE-aligned threat model. Enumerates plausible threats, likelihood and impact at this scope, and mitigations in place. Gaps outside MVP scope are listed honestly.

For controls catalog, see [`security-baseline.md`](security-baseline.md).

---

## 1. Scope and trust boundaries

**In scope:** Workload EC2 instance, IAM roles/policies, VPC/subnets/SGs/endpoints, KMS CMK, CloudWatch log groups, SSM parameters, AWS Backup vault, Image Builder pipeline, S3 diagnostics bucket.

**Out of scope:** Operator workstation, IAM Identity Center / external IdP, AWS service plane (assumed trusted), physical security.

---

## 2. STRIDE threat analysis

### 2.1 Spoofing

| Threat | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Attacker impersonates operator with stolen credentials | Medium | High | MFA condition on `ssm:StartSession`; upstream IdP enforces MFA |
| Attacker spoofs workload role via stolen instance credentials | Low | High | IMDSv2 required (defeats SSRF-based theft); `kms:ViaService` conditions limit reuse |
| Attacker spoofs AWS service endpoint | Very low | High | Private DNS on VPC endpoints + SDK certificate pinning |

### 2.2 Tampering

| Threat | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Modification of fraud-worker script | Low | High | Script baked into Golden AMI; runtime modification fully logged via SSM session audit |
| Tampering with CloudWatch logs | Low | High | KMS-encrypted; `DeleteLogGroup` not granted to workload role; CloudTrail captures all CW API calls |
| Tampering with backup recovery points | Low | High | Vault access policy denies `DeleteRecoveryPoint` to non-break-glass; KMS encryption |
| Tampering with AMI ID SSM Parameter | Low | High | Writable only by Image Builder distribution role; CloudTrail logs writes |

### 2.3 Repudiation

| Threat | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Operator denies running a command | Medium | Medium | SSM session activity logged to `/aws/ssm/sessions` with operator's IAM principal; 30-day retention |
| Auditor cannot reconstruct a security incident | Medium | High | CloudTrail + VPC Flow Logs (14d) + audit logs (30d) + session logs (30d) |

### 2.4 Information disclosure

| Threat | Likelihood | Impact | Mitigation |
|---|---|---|---|
| EBS snapshot accessed by unauthorized party | Low | High | Encrypted with CMK; vault access policy restricts |
| CloudWatch log content accessed | Low | High | Log groups KMS-encrypted; `GetLogEvents` requires `kms:Decrypt` |
| Parameter Store SecureString via stolen workload role | Low | High | `kms:ViaService` condition; access from outside SSM service path denied |
| SSRF from fraud-worker reaches instance metadata | Low | High | IMDSv2 required, hop limit 1; fraud-worker runs as `nobody` with no network-facing listener |

### 2.5 Denial of service

| Threat | Likelihood | Impact | Mitigation |
|---|---|---|---|
| EC2 instance failure | Low | Medium | ASG `min=max=1` replaces automatically (~3 min RTO) |
| CloudWatch agent crash | Low | Medium | `cwagent-missing` alarm fires when metrics stop arriving |
| Application crash / hang | Medium | Medium | systemd `Restart=on-failure`; cpu-high and mem-high alarms |
| Runaway log ingestion (cost DoS) | Medium | Low (cost) | Per-log-group `IncomingBytes` alarm |
| Region failure | Very low | Critical | **Not mitigated in MVP** — see `backup-strategy.md` Section 8 |

### 2.6 Elevation of privilege

| Threat | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Workload role escalates to admin | Very low | Critical | Trust policy: `ec2.amazonaws.com` only; no `sts:AssumeRole` to other roles |
| Operator with limited SSM access escalates | Low | High | Workload role has no `iam:*`, no `ec2:*`; capability is bounded |
| Deploy role escalates by modifying its own policy | Low | Critical | Deploy role excludes `iam:PutRolePolicy` on its own principal |

---

## 3. Threats outside MVP scope

| Threat | Why not mitigated | Mitigation if needed |
|---|---|---|
| Insider threat with break-glass access | Single-person operator pattern | Two-person break-glass approval |
| Supply chain attack on AL2023 base AMI | Trust in AWS-published images | Inspector vulnerability scanning in pipeline |
| Region-wide AWS outage | Cost and complexity | Multi-region backup copy + failover runbook |
| DNS tunneling from instance | No outbound internet path makes this hard | Route 53 Resolver DNS Query Logging |
| Lateral movement to other accounts | Single-account scope | AWS Organizations + SCPs |

---

## 4. Highest-priority residual risks

1. **Region failure has no automated DR.** RTO is manual rebuild in another region. Acceptable for internal-only stateless service; not for customer-facing.
2. **No continuous compliance monitoring.** Configuration drift after deployment is invisible without GuardDuty/Config/Security Hub.
3. **Break-glass role is a single point of escalation.** Compromise is unrecoverable without external intervention. Two-person approval is the standard production mitigation.

---

## 5. Threat model maintenance

Revisit when: a new component is added, the workload's data sensitivity changes, a relevant AWS service introduces a new control, or after a security incident.
