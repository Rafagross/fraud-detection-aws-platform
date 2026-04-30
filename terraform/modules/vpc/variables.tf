variable "project" {
  description = "Project identifier prefix."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnets" {
  description = "Map of public subnet definitions."
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    a = { cidr = "10.20.0.0/24", az = "us-east-1a" }
    b = { cidr = "10.20.1.0/24", az = "us-east-1b" }
  }
}

variable "private_app_subnets" {
  description = "Map of private workload subnet definitions."
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    a = { cidr = "10.20.10.0/24", az = "us-east-1a" }
    b = { cidr = "10.20.11.0/24", az = "us-east-1b" }
  }
}

variable "private_vpce_subnets" {
  description = "Map of private VPC endpoint subnet definitions."
  type = map(object({
    cidr = string
    az   = string
  }))
  default = {
    a = { cidr = "10.20.20.0/24", az = "us-east-1a" }
    b = { cidr = "10.20.21.0/24", az = "us-east-1b" }
  }
}

variable "kms_key_arn" {
  description = "ARN of the platform CMK used to encrypt VPC Flow Logs."
  type        = string
}
