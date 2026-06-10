variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "project" {
  description = "Project identifier prefix."
  type        = string
  default     = "cloudops"
  validation {
    condition     = var.project == "cloudops"
    error_message = "project must be 'cloudops'."
  }
}

variable "owner" {
  description = "GitHub handle or team name — applied as Owner tag on all resources."
  type        = string
  default     = "Rafagross"
}

variable "cost_center" {
  description = "Cost allocation identifier."
  type        = string
  default     = "portfolio"
}

variable "alert_email" {
  description = "Email address for CloudWatch alarms, EventBridge alerts, and AWS Budgets."
  type        = string
  default     = ""
}

variable "ami_id" {
  description = <<-EOT
    Golden AMI ID for the workload Launch Template.
    For initial deploy, supply the current AL2023 arm64 AMI for us-east-1:
    aws ssm get-parameter \
      --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
      --query Parameter.Value --output text
  EOT
  type        = string
}

variable "image_builder_logs_bucket" {
  description = "S3 bucket for Image Builder logs. Leave empty to reuse diagnostics bucket."
  type        = string
  default     = ""
}

variable "workload_name" {
  description = "Workload identifier used in resource names, tags, and SSM paths."
  type        = string
  default     = "fraud-worker"
}

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL for platform alert notifications."
  type        = string
  sensitive   = true
  default     = ""
}
