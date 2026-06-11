# ADR 0009 — ASG min=2 for Zero-Downtime Rolling Updates

**Status:** Accepted — supersedes ADR 0005 (ASG min/max=1 for self-healing)  
**Date:** 2026-06-04

## Context

ADR 0005 set ASG min/max=1 to minimize cost for the initial demo. Adding the fraud-worker SQS consumer introduced a new constraint: if the single instance is replaced during a rolling AMI refresh, message processing pauses until the new instance is healthy (up to 5 minutes given the 300s warmup). For a consumer workload this creates a gap window where SQS messages accumulate unprocessed.

## Decision

Change `asg_instance_count` default to **2** and set `min_healthy_percentage = 50` in the instance refresh policy.

With two instances and 50% min-healthy:

- One instance is replaced at a time.
- The remaining instance continues polling SQS throughout the refresh.
- Processing throughput drops to 50% during the rollout window (~5–10 min), but never stops.

The variable remains configurable: set `asg_instance_count = 1` in `terraform.tfvars` to revert to cost-saving single-instance mode for teardowns.

## Consequences

- Monthly EC2 cost roughly doubles for `t4g.micro` (~$6/month → ~$12/month dev estimate).
- Rolling refreshes no longer require a maintenance window.
- `min_healthy_percentage` guard clause: when `asg_instance_count == 1`, the value is forced to `0` to prevent Terraform from blocking a refresh on a single-instance ASG.
