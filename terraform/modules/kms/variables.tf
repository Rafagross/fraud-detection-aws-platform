variable "project" {
  description = "Project identifier prefix used in all resource names."
  type        = string
  validation {
    condition     = var.project == "cloudops"
    error_message = "project must be 'cloudops'."
  }
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}
