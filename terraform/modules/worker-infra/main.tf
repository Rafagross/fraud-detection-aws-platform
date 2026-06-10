##############################################################################
# Module: worker-infra
# Purpose: SQS queue + Dead Letter Queue for the fraud-worker consumer,
#          DynamoDB table for fraud decisions, SSM parameters for runtime
#          config, and a DLQ depth alarm wired to the platform SNS topic.
#
# Access pattern summary:
#   - Main queue: worker polls ReceiveMessage, calls DeleteMessage on success
#   - DLQ:        messages land here after 3 failed processing attempts
#   - DynamoDB:   PutItem (write decision), GetItem (lookup by txn_id),
#                 Query on GSI card-velocity-index (velocity checks by card_id)
##############################################################################

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ---------------------------------------------------------------------------
# SQS — Dead Letter Queue (created first; referenced by main queue redrive)
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name_prefix}-sqs-fraud-transactions-dlq"
  message_retention_seconds = 1209600 # 14 days — time to investigate failures
  kms_master_key_id         = var.kms_key_arn

  tags = { Name = "${local.name_prefix}-sqs-fraud-transactions-dlq" }
}

# ---------------------------------------------------------------------------
# SQS — Main queue
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "fraud_transactions" {
  name                       = "${local.name_prefix}-sqs-fraud-transactions"
  visibility_timeout_seconds = 60    # worker has 60s to process before re-enqueue
  message_retention_seconds  = 345600 # 4 days
  kms_master_key_id          = var.kms_key_arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })

  tags = { Name = "${local.name_prefix}-sqs-fraud-transactions" }
}

resource "aws_sqs_queue_policy" "fraud_transactions" {
  queue_url = aws_sqs_queue.fraud_transactions.id
  policy    = data.aws_iam_policy_document.sqs_queue_policy.json
}

data "aws_iam_policy_document" "sqs_queue_policy" {
  statement {
    sid    = "DenyNonTLS"
    effect = "Deny"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.fraud_transactions.arn]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# ---------------------------------------------------------------------------
# DynamoDB — fraud decisions table
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "fraud_decisions" {
  name         = "${local.name_prefix}-ddb-fraud-decisions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "txn_id"

  attribute {
    name = "txn_id"
    type = "S"
  }

  # GSI partition key — needed for velocity queries ("all decisions for card X")
  attribute {
    name = "card_id"
    type = "S"
  }

  # GSI sort key — ISO-8601 timestamp enables time-range queries
  attribute {
    name = "ts"
    type = "S"
  }

  global_secondary_index {
    name            = "card-velocity-index"
    hash_key        = "card_id"
    range_key       = "ts"
    projection_type = "ALL"
  }

  # Auto-delete decisions older than 90 days — keeps table lean for the demo
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.kms_key_arn
  }

  tags = { Name = "${local.name_prefix}-ddb-fraud-decisions" }
}

# ---------------------------------------------------------------------------
# SSM Parameters — runtime config for the fraud worker script
# The worker reads these at startup so the AMI never needs a rebake when
# queue or table names change.
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "sqs_queue_url" {
  name        = "/${var.project}/${var.environment}/worker/sqs-queue-url"
  description = "Main SQS queue URL for the fraud worker"
  type        = "String"
  value       = aws_sqs_queue.fraud_transactions.id
  tags        = { Name = "${local.name_prefix}-param-worker-queue-url" }
}

resource "aws_ssm_parameter" "dynamodb_table_name" {
  name        = "/${var.project}/${var.environment}/worker/dynamodb-table-name"
  description = "DynamoDB table name for fraud decisions"
  type        = "String"
  value       = aws_dynamodb_table.fraud_decisions.name
  tags        = { Name = "${local.name_prefix}-param-worker-ddb-table" }
}

# DLQ depth alarm is wired in envs/dev/main.tf after both worker-infra and
# observability modules are available — avoids a circular module dependency.
