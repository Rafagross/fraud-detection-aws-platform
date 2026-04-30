variable "project" { type = string }
variable "environment" { type = string }

variable "kms_key_arn" {
  description = "ARN of platform CMK to encrypt AMI snapshots."
  type        = string
}

variable "launch_template_id" {
  description = "Launch Template ID to associate with the distribution config."
  type        = string
}

variable "image_builder_logs_bucket" {
  description = "S3 bucket name for Image Builder build logs."
  type        = string
}
