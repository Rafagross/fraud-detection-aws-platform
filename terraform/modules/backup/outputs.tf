output "vault_name" {
  description = "Name of the AWS Backup vault."
  value       = aws_backup_vault.platform.name
}

output "vault_arn" {
  description = "ARN of the AWS Backup vault."
  value       = aws_backup_vault.platform.arn
}

output "backup_plan_id" {
  description = "ID of the daily backup plan."
  value       = aws_backup_plan.daily.id
}
