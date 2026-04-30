# ADR 0007: VPC Flow Logs to CloudWatch Logs

**Status:** Accepted  
**Date:** 2026-04-30  
**Decision makers:** Platform owner (Rafael Gross)

## Context

The platform VPC carries traffic between SSM endpoints, workload instances, and AWS service endpoints. Without network-level telemetry, troubleshooting connectivity and investigating security incidents requires guesswork.

VPC Flow Logs capture metadata for every IP flow: source/destination IP, ports, protocol, packets, bytes, action, timestamp. Three destination options: CloudWatch Logs, S3, or Amazon Data Firehose.

## Decision

Enable VPC Flow Logs at the **VPC level** (captures all subnets), destination **CloudWatch Logs**, log group `/aws/vpc/flowlogs`, retention **14 days**, encrypted with the platform CMK, filter `ALL`.

## Alternatives considered

### No Flow Logs
- Rejected: no network-layer audit trail. Troubleshooting SSM endpoint connectivity becomes guesswork. Senior reviewer red flag.

### Flow Logs to S3 with Athena queries
- Pros: cheaper at high volume (~$0.30/month vs ~$0.75/month).
- Cons: Athena queries require schema setup, partition management, cost-per-query. For ad-hoc troubleshooting at MVP scale, CloudWatch Logs Insights is faster and lower friction.
- Rejected for MVP. Revisit if monthly volume exceeds 50 GB.

### Subnet-level logs only
- Rejected: misses traffic in excluded subnets. VPC-level is the correct default.

### REJECT-only filter
- Pros: ~10x cheaper at this volume.
- Cons: loses visibility into accept events needed for troubleshooting. Cost difference is ~$0.50/month — not worth the loss.
- Rejected for MVP.

## Trade-offs

| Dimension | Impact |
|---|---|
| Cost | ~$0.75/month at MVP volume — trivial |
| Security | Improves: full network-layer audit trail |
| Operability | Improves: troubleshooting is a Logs Insights query |
| Performance | None — Flow Logs are out-of-band |

## Consequences

- New log group `/aws/vpc/flowlogs`, 14-day retention, KMS-encrypted.
- IAM role `cloudops-dev-role-flowlogs` for Flow Logs service to write to the log group.
- CloudWatch alarm on `IncomingBytes` at 5 GB/24h fires on traffic anomalies.
- Flow Logs capture metadata only, not payload content.

## Revisit when

- Monthly volume exceeds 50 GB → re-evaluate S3 destination.
- Regulatory retention requirement → S3 with Glacier lifecycle.
- SIEM adoption → Firehose destination.
