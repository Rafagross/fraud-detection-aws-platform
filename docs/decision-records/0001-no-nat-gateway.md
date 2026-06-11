# ADR 0001: No NAT Gateway in MVP

**Status:** Accepted  
**Date:** 2026-04-29  
**Decision makers:** Platform owner (Rafael Gross)

## Context

Workload EC2 instances live in private subnets and need to reach AWS service endpoints (SSM, CloudWatch, S3) and, in some designs, the public internet (for OS package updates, third-party API calls, etc.).

Two common options:

1. **NAT Gateway** — managed, highly available, ~$33/month base per AZ plus $0.045/GB processed.
2. **VPC Endpoints (Interface + Gateway)** — direct private connectivity to specific AWS services. Interface endpoints ~$7.30/month each; S3 Gateway Endpoint is free.

## Decision

Use VPC Interface Endpoints for SSM, CloudWatch, and Logs traffic, plus the free S3 Gateway Endpoint. **Do not provision a NAT Gateway.**

OS package updates and CIS hardening occur inside the EC2 Image Builder pipeline. The runtime workload never reaches the public internet directly.

## Alternatives considered

### Alternative A: NAT Gateway in one AZ

- Cost: ~$33/month + data.
- Rejected: more than doubles the platform's monthly cost for no functional gain at MVP scope.

### Alternative B: NAT Instance (self-managed)

- Cost: ~$6/month for a `t4g.nano`.
- Rejected: operator-owned patching, scaling, HA, monitoring — defeats the "operationally clean" narrative.

### Alternative C: Endpoints + NAT (hybrid)

- Rejected: pays NAT cost without solving any concrete MVP requirement.

### Chosen: Endpoints only

- Cost: ~$36.50/month for five interface endpoints, $0 for S3 gateway.
- Saves ~$33/month minimum vs. single-AZ NAT.
- Improves security: no internet egress means no covert exfiltration path.

## Trade-offs

| Dimension | Impact |
|---|---|
| Cost | Saves ~$33/month minimum vs. single-AZ NAT |
| Security | Improves: no internet egress surface |
| Operability | Slightly worse: bootstrap must happen at AMI bake time |
| Reliability | Neutral: endpoints are AZ-redundant by default |
| Performance | Improves: traffic stays inside the AWS network |
| Sustainability | Improves: no always-on NAT compute |

## Consequences

- Any future requirement for arbitrary outbound HTTP calls requires an explicit decision: add NAT, add another PrivateLink endpoint, or restructure.
- The Image Builder pipeline is the single place that handles internet access during build.
- KMS Interface Endpoint deliberately excluded (server-side KMS calls only, no direct instance volume).

## Revisit when

- A genuine runtime dependency on a non-AWS service appears.
- Monthly budget ceiling is raised.
- Multi-account architecture introduces a centralized egress VPC.
