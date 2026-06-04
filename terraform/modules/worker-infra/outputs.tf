output "queue_url" {
  description = "URL of the main SQS fraud transactions queue."
  value       = aws_sqs_queue.fraud_transactions.id
}

output "queue_arn" {
  description = "ARN of the main SQS fraud transactions queue."
  value       = aws_sqs_queue.fraud_transactions.arn
}

output "dlq_url" {
  description = "URL of the SQS Dead Letter Queue."
  value       = aws_sqs_queue.dlq.id
}

output "dlq_arn" {
  description = "ARN of the SQS Dead Letter Queue."
  value       = aws_sqs_queue.dlq.arn
}

output "dynamodb_table_name" {
  description = "DynamoDB fraud decisions table name."
  value       = aws_dynamodb_table.fraud_decisions.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB fraud decisions table ARN."
  value       = aws_dynamodb_table.fraud_decisions.arn
}

output "sqs_queue_url_parameter_name" {
  description = "SSM Parameter name holding the queue URL — used by IAM policy scoping."
  value       = aws_ssm_parameter.sqs_queue_url.name
}
