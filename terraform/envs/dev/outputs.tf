output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "kms_key_arn" {
  description = "Platform CMK ARN."
  value       = module.kms.key_arn
}

output "kms_alias" {
  description = "Platform CMK alias name."
  value       = module.kms.alias_name
}

output "workload_sg_id" {
  description = "Workload security group ID."
  value       = module.ec2_workload.workload_sg_id
}

output "asg_name" {
  description = "Auto Scaling Group name."
  value       = module.ec2_workload.asg_name
}

output "launch_template_id" {
  description = "Launch Template ID."
  value       = module.ec2_workload.launch_template_id
}

output "backup_vault_name" {
  description = "AWS Backup vault name."
  value       = module.backup.vault_name
}

output "sns_topic_arn" {
  description = "Alerts SNS topic ARN."
  value       = module.observability.sns_topic_arn
}

output "diagnostics_bucket_name" {
  description = "S3 diagnostics bucket name."
  value       = module.ec2_workload.diagnostics_bucket_name
}

output "image_builder_pipeline_arn" {
  description = "Image Builder pipeline ARN."
  value       = module.image_builder.pipeline_arn
}

output "cwagent_config_parameter" {
  description = "SSM Parameter path for CloudWatch Agent config."
  value       = module.observability.cwagent_config_parameter_name
}

output "post_deploy_command" {
  description = "Command to run post-deploy validation."
  value       = "# Wait ~3 minutes, then:\n# INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${module.ec2_workload.asg_name} --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)\n# ./scripts/validation/post-deploy-checks.sh $INSTANCE_ID us-east-1"
}
