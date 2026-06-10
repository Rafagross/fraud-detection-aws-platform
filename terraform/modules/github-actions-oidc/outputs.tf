output "plan_role_arn" {
  description = "ARN of the read-only IAM role assumed by GitHub Actions on PRs."
  value       = aws_iam_role.github_actions_plan.arn
}

output "apply_role_arn" {
  description = "ARN of the admin IAM role assumed by GitHub Actions on push to main."
  value       = aws_iam_role.github_actions_apply.arn
}
