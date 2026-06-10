output "lambda_function_arn" {
  description = "ARN of the Slack notification Lambda function."
  value       = aws_lambda_function.slack_notify.arn
}

output "lambda_function_name" {
  description = "Name of the Slack notification Lambda function."
  value       = aws_lambda_function.slack_notify.function_name
}
