variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "github_repo" {
  description = "GitHub repository in owner/name format (e.g. Rafagross/fraud-detection-aws-platform)."
  type        = string
}
