# ADR 0010 — Static ASG Capacity vs Target-Tracking Auto-Scaling

**Status:** Accepted  
**Date:** 2026-06-06

## Context

Auto Scaling Groups support two capacity models:

- **Static** (`min = max = desired`): a fixed fleet size; ASG acts as a self-healing mechanism only, replacing failed instances without changing fleet size.
- **Dynamic (target-tracking)**: ASG scales in and out automatically based on a CloudWatch metric (e.g., `CPUUtilization = 60%`, custom SQS queue depth per instance). Fleet size fluctuates between `min` and `max`.

The fraud-worker processes SQS messages in a long-polling loop. SQS `ApproximateNumberOfMessagesVisible` is the natural scaling signal: if the queue depth grows, add instances; if it drains, scale in.

## Decision

Keep `min = max = desired = 2` (static capacity). Do not configure target-tracking or step-scaling policies.

Reasons:

1. **Transaction volume is low and bounded in the MVP.** The simulator sends low-rate synthetic messages. There is no observed queue buildup that would justify adding instances.
2. **Scale-out latency is ~5 minutes.** A new EC2 instance must boot, execute user_data (AMI install already done), start fraud-worker, and resolve SSM parameters before it can poll. Target-tracking cannot react faster than this cold-start floor — for burst protection it is not effective.
3. **Per-instance cost is $6/month.** The operational complexity of a dynamic scaling policy (scale-in cooldowns, flapping guards, target value tuning) is not justified at this cost level.
4. **DLQ handles backpressure.** Messages that cannot be processed within visibility_timeout return to the queue. After 3 attempts they move to the DLQ where an alarm fires. This is the explicit signal to investigate — not a trigger to add capacity automatically.
5. **Static capacity is predictable.** Runbook-driven incident response is simpler when the fleet size is a known constant.

## Rejected Alternative — SQS-based target tracking

Scale on `ApproximateNumberOfMessagesVisible / instance_count` with a target of 100 messages per instance. Rejected because:

- Cold-start latency (~5 min) means scale-out kicks in after the queue has already been backing up for several minutes.
- Scale-in requires a cooldown (≥300 s default) to avoid flapping; this turns a brief spike into a sustained over-provisioned state.
- The DLQ alarm already surfaces persistent backlog to an operator who can make an informed capacity decision.

## Consequences

- Fleet size does not change automatically. A sustained increase in transaction volume requires a manual `asg_instance_count` bump and `terraform apply`.
- Phase 2 can introduce target-tracking on SQS queue depth once transaction volume is measurable from production load data.
- The static model is appropriate for any non-traffic-driven workload (SQS consumers, batch processors) where volume is low and cold-start latency is high relative to the scaling benefit.
