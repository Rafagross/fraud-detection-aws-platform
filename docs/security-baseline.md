# Security Baseline

This document consolidates the security controls implemented across the platform and maps them to the AWS Well-Architected Security Pillar and CIS AWS Foundations Benchmark.

For threat-specific reasoning, see [`threat-model.md`](threat-model.md). For individual decisions, see [`decision-records/`](decision-records/).

---

## 1. Security model summary

The platform follows a **defense-in-depth** model with five layers:

1. **Network isolation** — no inbound public exposure, no outbound internet at runtime.
2. **Identity-based access** — IAM-gated, MFA-required, audit-logged.
3. **Encryption everywhere** — at rest and in transit, with a customer-managed key.
4. **Immutable infrastructure** — Golden AMIs, no in-place mutation.
5. **Continuous observability** — CloudWatch, EventBridge, SNS, CloudTrail (assumed upstream).

---

## 2. Network controls

| Control | Implementation |
|---|---|
| No public IPs on workload | Launch Template: `associate_public_ip_address = false` |
| No inbound rules on workload SG | `cloudops-dev-sg-workload` has zero ingress rules |
| Private subnets only | No IGW route in any private route table |
| No NAT Gateway | No `0.0.0.0/0` route ([ADR 0001](decision-records/0001-no-nat-gateway.md)) |
| AWS-private path to control plane | Five VPC Interface Endpoints, private DNS enabled |
| AWS-private path to S3 | S3 Gateway Endpoint |
| Endpoint SG isolation | `cloudops-dev-sg-vpce` accepts 443 from `cloudops-dev-sg-workload` only |
| Network audit trail | VPC Flow Logs to `/aws/vpc/flowlogs`, 14-day retention, KMS-encrypted |
| Default-deny posture | Workload egress: 443 to endpoint SG + S3 prefix list only |

---

## 3. Identity and access controls

### 3.1 Workload IAM role

`cloudops-dev-role-workload`. Trust: `ec2.amazonaws.com`. Attached managed: `AmazonSSMManagedInstanceCore`.

Inline policy (all resources scoped to specific ARNs):

| Action | Resource | Conditions |
|---|---|---|
| `cloudwatch:PutMetricData` | `*` | `cloudwatch:namespace = CloudOpsPlatform/EC2` |
| `logs:CreateLogStream`, `logs:PutLogEvents` | Specific log group ARNs | None |
| `ssm:GetParameter`, `ssm:GetParameters` | Platform parameter path prefixes | None |
| `kms:Decrypt`, `kms:GenerateDataKey` | Platform CMK ARN | `kms:ViaService` conditioned |
| `s3:PutObject` | Diagnostics bucket ARN | None |

### 3.2 Service roles

| Role | Trust | Scope |
|---|---|---|
| `cloudops-dev-role-image-builder` | `ec2.amazonaws.com` | Image Builder build instance |
| `cloudops-dev-role-image-builder-distribution` | `imagebuilder.amazonaws.com` | Distribution config |
| `cloudops-dev-role-aws-backup` | `backup.amazonaws.com` | Snapshot / restore |
| `cloudops-dev-role-flowlogs` | `vpc-flow-logs.amazonaws.com` | Write to `/aws/vpc/flowlogs` |
| `cloudops-dev-role-deploy` | Operator/CI principal | Terraform apply, least-privilege |
| `cloudops-dev-role-break-glass` | Operator (manual assume only) | Emergency operations, triggers alert |

---

## 4. Data protection

### 4.1 Encryption at rest

| Data class | Encryption | Key |
|---|---|---|
| EBS volumes | Yes | Platform CMK |
| CloudWatch Log Groups (all) | Yes | Platform CMK |
| AWS Backup vault | Yes | Platform CMK |
| SSM Parameter SecureString | Yes | Platform CMK |
| S3 diagnostics bucket | Yes (SSE-KMS) | Platform CMK |
| Image Builder output AMI | Yes (encrypted snapshot) | Platform CMK |
| SSM Session logs | Yes (CloudWatch Log Group) | Platform CMK |

### 4.2 Encryption in transit

All paths use HTTPS/mTLS. Instance-to-AWS-service traffic travels over VPC Interface Endpoints (PrivateLink) and never leaves the AWS network.

### 4.3 KMS key management

Single CMK, symmetric, `SYMMETRIC_DEFAULT`. Annual automatic rotation enabled. Key policy grants `kms:ViaService`-conditioned access. Key deletion requires 7–30 day waiting period. EventBridge alert fires on any `kms:ScheduleKeyDeletion` event for the platform CMK.

---

## 5. Compute hardening

| Control | Mechanism |
|---|---|
| OS patches up-to-date at bake time | `update-linux` component runs first |
| Unused services disabled | `cloudops-cis-baseline` component |
| `sshd` configured, not used | `PermitRootLogin no`, `PasswordAuthentication no` |
| `auditd` enabled | Ships to `/aws/ec2/fraud-worker/audit` |
| Sysctl hardening | rp_filter, ASLR, IPv6 redirects disabled |
| IMDSv2 enforced | Launch Template `http_tokens = required`, hop limit 1 |
| No SSH key pair | Launch Template has no `key_name` |

Image Builder validation tests run before AMI publish: SSM Agent, CloudWatch Agent, and fraud-worker script present and service enabled; IMDSv2 enforcement verified; no listening ports on `0.0.0.0`.

---

## 6. Audit and monitoring

| Source | Destination | Retention |
|---|---|---|
| AWS API calls | CloudTrail (assumed) | Per account trail config |
| SSM Session Manager | `/aws/ssm/sessions` | 30 days |
| auditd (instance-level) | `/aws/ec2/fraud-worker/audit` | 30 days |
| VPC traffic | `/aws/vpc/flowlogs` | 14 days |
| Application logs | `/aws/ec2/fraud-worker/app` | 30 days |
| System logs | `/aws/ec2/fraud-worker/system` | 30 days |

EventBridge rules: break-glass role assumption, `kms:ScheduleKeyDeletion` on platform CMK, AWS Backup job failures → all route to SNS.

---

## 7. AWS Well-Architected Security Pillar mapping (selected)

| WA Best Practice | This platform |
|---|---|
| SEC02-BP02 Use temporary credentials | All access via IAM roles; no long-lived keys |
| SEC03-BP01 Define access requirements | IAM least-privilege per role |
| SEC04-BP01 Configure service and application logging | CloudWatch Logs, audit logs, session logs, VPC Flow Logs |
| SEC05-BP01 Create network layers | Public/private subnet split, endpoint subnet isolation |
| SEC05-BP02 Control traffic at all layers | SGs (default-deny), VPC endpoints, Flow Logs |
| SEC06-BP01 Perform vulnerability management | Patch Manager (runtime), Phase 2 Inspector (AMI build) |
| SEC06-BP02 Provision compute from hardened images | EC2 Image Builder Golden AMI |
| SEC08-BP01 Implement secure key management | CMK, rotation enabled |
| SEC08-BP02 Enforce encryption at rest | All data classes encrypted |
| SEC09-BP02 Enforce encryption in transit | All paths HTTPS/mTLS |

---

## 8. CIS AWS Foundations Benchmark (selected)

| CIS control | Status |
|---|---|
| 2.8 KMS key rotation | ✅ Enabled |
| 2.9 VPC Flow Logs in all VPCs | ✅ Enabled |
| 4.1 No SG inbound 0.0.0.0/0 port 22 | ✅ No SG has any ingress rule |
| 4.2 No SG inbound 0.0.0.0/0 port 3389 | ✅ Same |
| 4.3 Default SG restricts all traffic | ✅ Default SG has no rules attached |
| 5.1 EBS volumes encrypted | ✅ Mandatory at volume creation |

---

## 9. Known gaps

- No continuous compliance monitoring (GuardDuty/Config/Security Hub) — Phase 2
- CloudTrail assumed, not provisioned — prerequisite
- No Vault Lock on AWS Backup vault — see `backup-strategy.md` Section 5
- No Inspector in AMI pipeline — Phase 2
- No CIS metric filters + alarms (CIS 3.x controls) — Phase 2
- Account-level controls (root MFA, password policy) assumed upstream
