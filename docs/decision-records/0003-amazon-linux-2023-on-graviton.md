# ADR 0003: Amazon Linux 2023 on Graviton (`arm64`)

**Status:** Accepted  
**Date:** 2026-04-29  
**Decision makers:** Platform owner (Rafael Gross)

## Context

Two choices made together: OS and CPU architecture.

## Decision

Use **Amazon Linux 2023 on Graviton (`arm64`)**, instance type `t4g.micro`. AMI sourced from the public SSM Parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64`.

## OS alternatives considered

### Amazon Linux 2
- End of standard support: June 30, 2025. Already past. Rejected immediately.

### Amazon Linux 2023
- Current AWS-supported default for new Linux workloads. DNF-based, 5-year support commitment, native `arm64` parity. **Chosen.**

### Ubuntu / RHEL
- Familiar to operators without AWS background. No benefit for this platform narrative. Rejected for MVP.

## Architecture alternatives considered

### x86 (`t3.micro`) — ~$7.50/month
- Rejected: ~20% more expensive, not the AWS-recommended default for new workloads in 2026.

### Graviton `arm64` (`t4g.micro`) — ~$6.00/month
- Cheaper, lower power, AWS-recommended default for new Linux workloads. **Chosen.**
- AL2023 has full parity. SSM Agent and CloudWatch Agent ship native `arm64` builds. Go cross-compiles trivially with `GOOS=linux GOARCH=arm64`.

## Trade-offs

| Dimension | Impact |
|---|---|
| Cost | Saves ~$1.50/instance/month (~20%) vs. x86 equivalent |
| Security | Neutral |
| Operability | Neutral for this workload. Slight risk if a future dep is `x86`-only (rare in 2026) |
| Performance | Equal or better per dollar for general-purpose workloads |
| Sustainability | Improves: lower energy consumption per unit of work |

## Consequences

- Image Builder pipeline produces `arm64` AMIs.
- All AWS agents installed from `arm64` channels.
- `heartbeat-api` binary built with `GOOS=linux GOARCH=arm64 go build`.
- Any future runtime dependency must be checked for `arm64` support before adoption.

## Revisit when

- A required runtime dependency exists only for `x86_64`.
- AWS deprecates AL2023 (not expected in the next 4+ years).
