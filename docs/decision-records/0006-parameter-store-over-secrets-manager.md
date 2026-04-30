# ADR 0006: Parameter Store (Standard tier) over Secrets Manager

**Status:** Accepted  
**Date:** 2026-04-29  
**Decision makers:** Platform owner (Rafael Gross)

## Context

The platform stores configuration and a small number of sensitive values. Two options:
1. **SSM Parameter Store** Standard tier — free; `SecureString` for sensitive values (KMS-encrypted).
2. **AWS Secrets Manager** — $0.40/secret/month + $0.05/10K API calls; native rotation, cross-region replication.

## Decision

Use **SSM Parameter Store, Standard tier** for all configuration and secret storage in MVP.

## Alternatives considered

### Secrets Manager for sensitive values, Parameter Store for everything else
- Pros: native rotation, resource policies, cross-region replication.
- Cons: two systems to manage; rotation automation requires a custom rotator for a static token, which is more code than the secret warrants.
- Rejected for MVP.

### HashiCorp Vault
- Rejected: out of scope for a single-account AWS pattern.

### Plain environment variables baked into the AMI
- Rejected: secrets in AMI are visible to anyone with `ec2:DescribeImages` or `ec2:CopyImage`.

### Parameter Store (chosen)
- Cost: $0 at MVP volume.
- `SecureString` provides KMS encryption with the platform CMK.
- IAM resource-level scoping by path prefix.
- Same service surface as AMI ID pointers and CloudWatch Agent config.

## Trade-offs

| Dimension | Impact |
|---|---|
| Cost | Saves $0.40/secret/month |
| Security | Equivalent storage and access control; weaker on rotation automation |
| Operability | Improves: one config service, not two |

## Consequences

- `kms:Decrypt` conditioned on `kms:ViaService = ssm.us-east-1.amazonaws.com`.
- Rotation for the `heartbeat-api` API token is manual, documented as a runbook.

## Revisit when

- A managed database is introduced (RDS/Aurora) with native rotation needs.
- Secret needs cross-region replication.
- Number of secrets passes ~25 where consolidated rotation tooling becomes worth the per-secret cost.
