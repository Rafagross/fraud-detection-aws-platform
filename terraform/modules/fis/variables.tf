variable "project" {
  description = "Project identifier prefix."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the platform CMK used to encrypt the FIS experiment log group."
  type        = string
}
