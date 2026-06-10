variable "project" {
  description = "Project identifier prefix."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "sns_topic_arn" {
  description = "ARN of the platform SNS topic to subscribe this Lambda to."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the platform CMK for Lambda environment variable encryption."
  type        = string
}

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL. Stored encrypted as Lambda environment variable."
  type        = string
  sensitive   = true
}
