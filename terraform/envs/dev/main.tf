##############################################################################
# main.tf — Dev environment module composition
# Module dependency order:
#   kms > worker-infra
#   kms > vpc
#   kms, worker-infra > iam-roles > ec2-workload > vpc-endpoints
#   vpc-endpoints > sg-rule-wiring > backup > observability > image-builder
#   observability + worker-infra > dlq-alarm (standalone resource at bottom)
#   inspector + fis are independent (no cross-module deps)
##############################################################################

data "aws_caller_identity" "current" {}

data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${var.region}.s3"
}

data "aws_ec2_managed_prefix_list" "dynamodb" {
  name = "com.amazonaws.${var.region}.dynamodb"
}

locals {
  diagnostics_bucket_name = "${var.project}-${var.environment}-s3-diagnostics-${data.aws_caller_identity.current.account_id}"
}

# 1. KMS
module "kms" {
  source      = "../../modules/kms"
  project     = var.project
  environment = var.environment
}

# 2. VPC
module "vpc" {
  source      = "../../modules/vpc"
  project     = var.project
  environment = var.environment
  kms_key_arn = module.kms.key_arn
}

# 3. Worker infrastructure — SQS + DynamoDB (depends only on kms)
module "worker_infra" {
  source      = "../../modules/worker-infra"
  project     = var.project
  environment = var.environment
  kms_key_arn = module.kms.key_arn
}

# 4. IAM roles (depends on worker-infra for least-privilege ARN scoping)
module "iam_roles" {
  source                    = "../../modules/iam-roles"
  project                   = var.project
  environment               = var.environment
  workload_name             = var.workload_name
  kms_key_arn               = module.kms.key_arn
  diagnostics_bucket_name   = local.diagnostics_bucket_name
  worker_queue_arn          = module.worker_infra.queue_arn
  worker_dynamodb_table_arn = module.worker_infra.dynamodb_table_arn
  enable_worker_policy      = true
}

# 5. EC2 workload — creates workload SG (S3 egress only; vpce egress added below)
module "ec2_workload" {
  source        = "../../modules/ec2-workload"
  project       = var.project
  environment   = var.environment
  workload_name = var.workload_name

  vpc_id                 = module.vpc.vpc_id
  private_app_subnet_ids = module.vpc.private_app_subnet_ids
  s3_prefix_list_id      = data.aws_ec2_managed_prefix_list.s3.id
  kms_key_arn            = module.kms.key_arn
  instance_profile_name  = module.iam_roles.workload_instance_profile_name
  ami_id                 = var.ami_id
}

# 6. VPC endpoints — needs workload SG
module "vpc_endpoints" {
  source      = "../../modules/vpc-endpoints"
  project     = var.project
  environment = var.environment

  vpc_id                     = module.vpc.vpc_id
  private_vpce_subnet_ids    = module.vpc.private_vpce_subnet_ids
  private_app_route_table_id = module.vpc.private_app_route_table_id
  workload_sg_id             = module.ec2_workload.workload_sg_id
}

# 6b. Wire vpce egress rule onto the workload SG — breaks circular dependency
# ec2-workload creates its SG without this rule; we add it here once both SGs exist.
resource "aws_security_group_rule" "workload_to_dynamodb" {
  type              = "egress"
  description       = "HTTPS to DynamoDB via gateway endpoint"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = module.ec2_workload.workload_sg_id
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.dynamodb.id]
}

resource "aws_security_group_rule" "workload_to_vpce" {
  type                     = "egress"
  description              = "HTTPS to VPC interface endpoints"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.ec2_workload.workload_sg_id
  source_security_group_id = module.vpc_endpoints.vpce_sg_id
}

# 7. Backup
module "backup" {
  source          = "../../modules/backup"
  project         = var.project
  environment     = var.environment
  kms_key_arn     = module.kms.key_arn
  backup_role_arn = module.iam_roles.aws_backup_role_arn
}

# 8. Observability
module "observability" {
  source        = "../../modules/observability"
  project       = var.project
  environment   = var.environment
  workload_name = var.workload_name

  kms_key_arn          = module.kms.key_arn
  asg_name             = module.ec2_workload.asg_name
  alert_email          = var.alert_email
  break_glass_role_arn = module.iam_roles.break_glass_role_arn
}

# 9. Image Builder
module "image_builder" {
  source      = "../../modules/image-builder"
  project     = var.project
  environment = var.environment

  kms_key_arn               = module.kms.key_arn
  launch_template_id        = module.ec2_workload.launch_template_id
  image_builder_logs_bucket = var.image_builder_logs_bucket != "" ? var.image_builder_logs_bucket : module.ec2_workload.diagnostics_bucket_name
}

# 10. GuardDuty
module "guardduty" {
  source        = "../../modules/guardduty"
  project       = var.project
  environment   = var.environment
  sns_topic_arn = module.observability.sns_topic_arn
}

# 11. Slack notifications
module "slack_notifications" {
  source            = "../../modules/slack-notifications"
  project           = var.project
  environment       = var.environment
  sns_topic_arn     = module.observability.sns_topic_arn
  kms_key_arn       = module.kms.key_arn
  slack_webhook_url = var.slack_webhook_url
}

# 12. Inspector v2 — continuous EC2 vulnerability scanning
module "inspector" {
  source = "../../modules/inspector"
}

# 13. FIS — chaos experiment: terminate one instance, validate ASG self-healing
module "fis" {
  source      = "../../modules/fis"
  project     = var.project
  environment = var.environment
  kms_key_arn = module.kms.key_arn
}

# 14. DLQ depth alarm — standalone resource that needs both observability (SNS ARN)
# and worker_infra (DLQ name). Lives here to avoid circular module dependencies.
resource "aws_cloudwatch_metric_alarm" "worker_dlq_depth" {
  alarm_name          = "${var.project}-${var.environment}-alarm-worker-dlq-depth"
  alarm_description   = "Messages visible in fraud worker DLQ — 3 consecutive processing failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  dimensions          = { QueueName = split(":", module.worker_infra.dlq_arn)[5] }
  alarm_actions       = [module.observability.sns_topic_arn]
  tags                = { Name = "${var.project}-${var.environment}-alarm-worker-dlq-depth" }
}
