variable "project" {
  description = "Project identifier prefix."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "sns_topic_arn" {
  description = "ARN of the platform SNS topic for HIGH/CRITICAL finding alerts."
  type        = string
}

variable "finding_publishing_frequency" {
  description = "How often GuardDuty exports active findings to EventBridge (SIX_HOURS | ONE_HOUR | FIFTEEN_MINUTES)."
  type        = string
  default     = "SIX_HOURS"
}
