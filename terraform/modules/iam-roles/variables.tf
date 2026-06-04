variable "project" {
  description = "Project identifier prefix."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "workload_name" {
  description = "Workload identifier used for IAM resource scoping."
  type        = string
  default     = "heartbeat-api"
}

variable "kms_key_arn" {
  description = "ARN of the platform CMK."
  type        = string
}

variable "diagnostics_bucket_name" {
  description = "Name of the S3 diagnostics bucket."
  type        = string
}

variable "worker_queue_arn" {
  description = "ARN of the SQS fraud transactions queue. Empty string disables SQS permissions."
  type        = string
  default     = ""
}

variable "worker_dynamodb_table_arn" {
  description = "ARN of the DynamoDB fraud decisions table. Empty string disables DynamoDB permissions."
  type        = string
  default     = ""
}
