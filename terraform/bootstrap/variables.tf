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

variable "environment" {
  description = "Deployment environment for OIDC role naming."
  type        = string
  default     = "dev"
}

variable "github_repo" {
  description = "GitHub repository in owner/name format for OIDC trust policy."
  type        = string
  default     = "Rafagross/fraud-detection-aws-platform"
}
