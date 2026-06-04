variable "project" { type = string }
variable "environment" { type = string }

variable "kms_key_arn" {
  description = "ARN of the platform CMK — used for SQS and DynamoDB encryption."
  type        = string
}
