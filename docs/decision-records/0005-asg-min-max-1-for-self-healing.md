# ADR 0005: Auto Scaling Group `min=max=1` for self-healing

**Status:** Accepted  
**Date:** 2026-04-29  
**Decision makers:** Platform owner (Rafael Gross)

## Context

The workload is single-instance by design. The question is how to make instance failure handling automatic rather than manual.

Three patterns: standalone EC2 instance, EC2 Auto Recovery (CloudWatch alarm action), or ASG sized at `min=desired=max=1`.

## Decision

Use an **Auto Scaling Group with `min=desired=max=1`**, spanning both private workload subnets across two AZs, for self-healing and controlled rollout — not for capacity scaling.

## Alternatives considered

### Standalone EC2 instance
- Rejected: manual recovery on failure. Reads as naive in a production-pattern reference.

### EC2 Auto Recovery via CloudWatch alarm
- Rejected as primary: handles only system status check failures, not instance-level failures. Cannot drive Launch-Template-based AMI roll-forward.

### ASG `min=max=1` (chosen)
- Free (no per-hour ASG cost).
- Handles both system and instance status check failures.
- Replacement instance launches from current Launch Template version (picks up latest Golden AMI).
- Instance Refresh provides atomic AMI roll-forward mechanism.
- Cross-AZ subnet eligibility: if one AZ fails, replacement can launch in the other.

## Trade-offs

| Dimension | Impact |
|---|---|
| Cost | Zero — ASG has no per-hour fee |
| Operability | Significantly improved: failure handling and AMI roll-forward are automatic |
| Reliability | Improved: cross-AZ eligibility |

## Consequences

- Terraform provisions a Launch Template and ASG instead of `aws_instance`.
- CloudWatch Agent first-boot config fetch is in user data (auto-configures on replacement).
- Instance Refresh is the supported AMI roll-forward mechanism.
- Brief downtime during replacement is acceptable for this stateless internal-only service.

## Revisit when

- A future workload requires zero-downtime updates → `min=2, max=4`.
- A stateful workload is added → ASG-of-one is insufficient.
- Capacity scaling becomes a real requirement.
