output "key_id" {
  description = "KMS key ID."
  value       = aws_kms_key.platform.key_id
}

output "key_arn" {
  description = "KMS key ARN — used by other modules for encryption configuration."
  value       = aws_kms_key.platform.arn
}

output "alias_arn" {
  description = "KMS alias ARN."
  value       = aws_kms_alias.platform.arn
}

output "alias_name" {
  description = "KMS alias name (e.g. alias/cloudops-dev-cmk-platform)."
  value       = aws_kms_alias.platform.name
}
