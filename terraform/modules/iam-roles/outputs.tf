output "workload_role_arn" {
  description = "ARN of the workload IAM role."
  value       = aws_iam_role.workload.arn
}

output "workload_role_name" {
  description = "Name of the workload IAM role."
  value       = aws_iam_role.workload.name
}

output "workload_instance_profile_name" {
  description = "Name of the EC2 instance profile for workload instances."
  value       = aws_iam_instance_profile.workload.name
}

output "workload_instance_profile_arn" {
  description = "ARN of the EC2 instance profile."
  value       = aws_iam_instance_profile.workload.arn
}

output "aws_backup_role_arn" {
  description = "ARN of the AWS Backup service role."
  value       = aws_iam_role.aws_backup.arn
}

output "break_glass_role_arn" {
  description = "ARN of the break-glass emergency role."
  value       = aws_iam_role.break_glass.arn
}

output "break_glass_role_name" {
  description = "Name of the break-glass role."
  value       = aws_iam_role.break_glass.name
}
