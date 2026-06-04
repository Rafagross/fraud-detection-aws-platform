# ADR 0008 — SQS + DynamoDB for Fraud-Worker Infrastructure

**Status:** Accepted  
**Date:** 2026-06-04

## Context

The platform needed a realistic async workload to demonstrate event-driven EC2 patterns and justify the SQS/DynamoDB VPC endpoints. The workload had to be fully private (no internet egress) and produce observable, auditable results.

## Decision

Use Amazon SQS (with a Dead Letter Queue) as the message bus and Amazon DynamoDB as the decision store for a fraud-screening simulation worker.

| Concern | Choice | Rationale |
|---|---|---|
| Message bus | SQS Standard | Decouples producers from consumers; built-in retry via visibility timeout |
| Failed message handling | DLQ (maxReceiveCount=3) | Keeps bad messages out of the main queue without data loss |
| Decision store | DynamoDB on-demand | Schemaless, millisecond writes, no capacity planning for a demo workload |
| Runtime config delivery | SSM Parameter Store | Queue URL and table name fetched at startup — AMI never needs a rebake when infra names change |
| Encryption | Platform CMK (kms:ViaService) | Single CMK enforced on both SQS and DynamoDB; consistent with ADR 0004 |

## Consequences

- Adds two VPC endpoints: SQS interface (~$7.30/month) and DynamoDB gateway (free).
- IAM workload role gains three tightly scoped permissions: `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `dynamodb:PutItem/GetItem/Query`.
- DLQ depth alarm is wired in `envs/dev/main.tf` (not inside a module) to avoid a circular dependency between `worker-infra` and `observability`.
- The `card-velocity-index` GSI on DynamoDB enables velocity queries (all decisions for a given card in a time window) without a full table scan.
