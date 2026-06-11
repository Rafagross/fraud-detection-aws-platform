# ADR 0002: SSM-only access — no SSH, no bastion

**Status:** Accepted  
**Date:** 2026-04-29  
**Decision makers:** Platform owner (Rafael Gross)

## Context

Operators need shell and command access to private EC2 instances.

Two common patterns:

1. **SSH-based access** — public-facing bastion or jump host, SSH key pairs, port 22 open.
2. **AWS Systems Manager Session Manager** — IAM-gated shell through the SSM control plane, no inbound network rules, no key material on instances.

## Decision

Use **SSM Session Manager exclusively.** No SSH service enabled on workload instances. No EC2 key pair associated with the Launch Template. Inbound SSH denied by default-deny SG posture.

## Alternatives considered

### Alternative A: Bastion host with SSH

- Rejected: one more instance to patch, key distribution/rotation overhead, public IP exposure, weaker session auditing.

### Alternative B: EC2 Instance Connect (EIC) Endpoint

- Rejected: still uses SSH under the hood, requires SSH service running on the instance. SSM removes SSH entirely.

### Alternative C: Hybrid (SSM primary, SSH break-glass)

- Rejected: re-introduces the surface SSM removes. Instance failure is handled by ASG replacement and EC2 Serial Console.

## Trade-offs

| Dimension | Impact |
|---|---|
| Security | Significant improvement: no inbound rules, no key material, MFA-gateable, fully logged |
| Cost | Lower: no bastion EC2, no Elastic IP |
| Operability | Improves: `aws ssm start-session` from anywhere with credentials |
| Reliability | One additional dependency (SSM control plane). Mitigated by Serial Console for boot-time recovery |
| Sustainability | Slight improvement: one less always-on EC2 |

## Consequences

- Operators must have IAM permissions for `ssm:StartSession` + `ssmmessages:*` + `ec2messages:*`, MFA-enforced.
- Session logs to CloudWatch Logs `/aws/ssm/sessions`, KMS-encrypted, 30-day retention.
- Port forwarding for local-only services uses `AWS-StartPortForwardingSession`.
- File transfer uses SSM Run Command + S3 patterns. `scp` unavailable.
- VPC Interface Endpoints for `ssm`, `ssmmessages`, `ec2messages` are mandatory.

## Revisit when

- A regulatory or contractual requirement specifically mandates SSH-protocol access.
- A toolchain dependency cannot be worked around without SSH.
