output "workload_sg_id" {
  description = "Security group ID of the workload instances."
  value       = aws_security_group.workload.id
}

output "launch_template_id" {
  description = "ID of the workload Launch Template."
  value       = aws_launch_template.workload.id
}

output "launch_template_latest_version" {
  description = "Latest version of the workload Launch Template."
  value       = aws_launch_template.workload.latest_version
}

output "asg_name" {
  description = "Name of the Auto Scaling Group."
  value       = aws_autoscaling_group.workload.name
}

output "diagnostics_bucket_name" {
  description = "Name of the S3 diagnostics bucket."
  value       = aws_s3_bucket.diagnostics.id
}

output "diagnostics_bucket_arn" {
  description = "ARN of the S3 diagnostics bucket."
  value       = aws_s3_bucket.diagnostics.arn
}
