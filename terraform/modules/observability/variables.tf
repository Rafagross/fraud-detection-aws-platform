variable "project" { type = string }
variable "environment" { type = string }

variable "workload_name" {
  description = "Workload identifier used in log group names and parameter paths."
  type        = string
  default     = "fraud-worker"
}

variable "kms_key_arn" {
  description = "ARN of the platform CMK for log group and SNS encryption."
  type        = string
}

variable "kms_key_id" {
  description = "KMS key ID (short form) — used for SSM SecureString parameters."
  type        = string
}

variable "asg_name" {
  description = "ASG name used as dimension in CloudWatch alarms."
  type        = string
}

variable "alert_email" {
  description = "Email address for SNS subscriptions and AWS Budgets notifications."
  type        = string
}

variable "app_log_level" {
  description = "Log level for the workload application."
  type        = string
  default     = "info"
}

variable "app_api_token" {
  description = "Initial API token. Managed outside Terraform after initial deploy."
  type        = string
  sensitive   = true
  default     = "REPLACE_ME_AFTER_DEPLOY"
}

variable "break_glass_role_arn" {
  description = "ARN of the break-glass role — used in EventBridge alert rule."
  type        = string
}
