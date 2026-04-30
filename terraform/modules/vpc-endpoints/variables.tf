variable "project" {
  description = "Project identifier prefix."
  type        = string
}

variable "environment" {
  description = "Deployment environment."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to attach endpoints to."
  type        = string
}

variable "private_vpce_subnet_ids" {
  description = "Map of private endpoint subnet IDs."
  type        = map(string)
}

variable "private_app_route_table_id" {
  description = "Route table ID for private workload subnets — S3 gateway route added here."
  type        = string
}

variable "workload_sg_id" {
  description = "Security group ID of the workload instances."
  type        = string
}
