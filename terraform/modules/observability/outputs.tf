output "sns_topic_arn" {
  description = "ARN of the platform alerts SNS topic."
  value       = aws_sns_topic.alerts.arn
}

output "log_group_arns" {
  description = "Map of CloudWatch Log Group ARNs keyed by logical name."
  value       = { for k, v in aws_cloudwatch_log_group.platform : k => v.arn }
}

output "dashboard_name" {
  description = "Name of the CloudWatch overview dashboard."
  value       = aws_cloudwatch_dashboard.overview.dashboard_name
}

output "cwagent_config_parameter_name" {
  description = "SSM Parameter name for CloudWatch Agent config."
  value       = aws_ssm_parameter.cloudwatch_agent_config.name
}
