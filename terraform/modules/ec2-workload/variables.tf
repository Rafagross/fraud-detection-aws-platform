variable "project" { type = string }
variable "environment" { type = string }

variable "workload_name" {
  description = "Workload identifier."
  type        = string
  default     = "fraud-worker"
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "private_app_subnet_ids" {
  description = "Map of private workload subnet IDs."
  type        = map(string)
}

variable "s3_prefix_list_id" {
  description = "Managed prefix list ID for S3 — used in egress rule."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the platform CMK for EBS and S3 encryption."
  type        = string
}

variable "instance_profile_name" {
  description = "IAM instance profile name to attach to the Launch Template."
  type        = string
}

variable "ami_id" {
  description = "Golden AMI ID."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t4g.micro"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB."
  type        = number
  default     = 30
}

variable "asg_instance_count" {
  description = "Desired/min/max instance count for the ASG. Use 1 for cost-saving demo teardowns, 2 for production HA."
  type        = number
  default     = 2
}
