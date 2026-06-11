# ADR 0004: Single customer-managed KMS key for MVP

**Status:** Accepted  
**Date:** 2026-04-29  
**Decision makers:** Platform owner (Rafael Gross)

## Context

The platform encrypts data at rest in multiple places: EBS volumes, CloudWatch Log Groups, AWS Backup vault, SSM Parameter Store SecureString parameters.

Options: AWS-managed keys (free, no policy control), one CMK per data class (~$4/month), or a single CMK (~$1/month).

## Decision

Use a **single customer-managed CMK**, `cloudops-dev-cmk-platform`, for all platform encryption in MVP.

## Alternatives considered

### AWS-managed keys everywhere

- Rejected: no key policy control, cannot enforce `kms:ViaService` conditions, weaker portfolio narrative.

### Per-data-class CMKs

- Pros: tighter blast radius, more granular auditing.
- Cons: four key policies to maintain, more IAM complexity for service roles, disproportionate overhead for a single-workload MVP.
- Deferred to Phase 2.

### One CMK for everything (chosen)

- Cost: $1/month.
- One key policy to review. Clear audit trail.
- Compatible with Phase 2 split (splitting keys later is easier than merging).

## Trade-offs

| Dimension | Impact |
|---|---|
| Cost | Saves ~$3/month vs. four CMKs |
| Security | Better than AWS-managed; looser than per-class CMKs |
| Operability | Simpler key policy review |

## Consequences

- Key policy grants `kms:ViaService`-conditioned access to workload role, Backup service role, and CloudWatch Logs service principal.
- Key rotation enabled (annual automatic rotation).
- Key deletion has 7–30 day waiting period; pipeline does not destroy keys, only marks for deletion.

## Revisit when

- Platform expands to multiple workloads with different sensitivity levels.
- Compliance requirement mandates per-data-class key separation.
- Multi-account deployment introduces cross-account key sharing.
