variable "region" {
  description = "AWS region where state backend resources are created."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project prefix used in resource names."
  type        = string
  default     = "cloudops"
}
