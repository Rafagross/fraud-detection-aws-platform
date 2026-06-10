output "tfstate_bucket_name" {
  description = "S3 bucket name for Terraform remote state."
  value       = aws_s3_bucket.tfstate.id
}

output "tfstate_lock_table_name" {
  description = "DynamoDB table name for state locking."
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "github_actions_plan_role_arn" {
  description = "ARN of the read-only IAM role for GitHub Actions plan jobs."
  value       = aws_iam_role.github_actions_plan.arn
}

output "github_actions_apply_role_arn" {
  description = "ARN of the admin IAM role for GitHub Actions apply jobs."
  value       = aws_iam_role.github_actions_apply.arn
}

output "backend_config" {
  description = "Ready-to-paste snippet for terraform/envs/dev/backend.tf"
  value = <<-EOT

    # Paste this into terraform/envs/dev/backend.tf (replace the placeholder block):
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.tfstate.id}"
        key            = "cloudops/dev/terraform.tfstate"
        region         = "${var.region}"
        encrypt        = true
        dynamodb_table = "${aws_dynamodb_table.tfstate_lock.name}"
      }
    }
  EOT
}
