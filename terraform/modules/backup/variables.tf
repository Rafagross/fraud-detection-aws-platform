variable "project" { type = string }
variable "environment" { type = string }

variable "kms_key_arn" {
  description = "ARN of the platform CMK used to encrypt the backup vault."
  type        = string
}

variable "backup_role_arn" {
  description = "ARN of the AWS Backup service role."
  type        = string
}
