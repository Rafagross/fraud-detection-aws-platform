##############################################################################
# Module: observability
# Purpose: CloudWatch Log Groups, Alarms, Dashboard, SNS, EventBridge,
#          SSM Parameters, AWS Budgets.
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "${var.project}-${var.environment}"
}

# SNS
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-sns-alerts"
  tags = { Name = "${local.name_prefix}-sns-alerts" }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn                       = aws_sns_topic.alerts.arn
  protocol                        = "email"
  endpoint                        = var.alert_email
  confirmation_timeout_in_minutes = 10
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.sns_alerts_policy.json
}

data "aws_iam_policy_document" "sns_alerts_policy" {
  statement {
    sid    = "AllowCloudWatchAlarms"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid    = "AllowEventBridge"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# CloudWatch Log Groups
locals {
  log_groups = {
    system   = { name = "/aws/ec2/${var.workload_name}/system", retention = 30 }
    app      = { name = "/aws/ec2/${var.workload_name}/app", retention = 30 }
    audit    = { name = "/aws/ec2/${var.workload_name}/audit", retention = 30 }
    sessions = { name = "/aws/ssm/sessions", retention = 30 }
  }
}

resource "aws_cloudwatch_log_group" "platform" {
  for_each          = local.log_groups
  name              = each.value.name
  retention_in_days = each.value.retention
  kms_key_id        = var.kms_key_arn
  tags              = { Name = "${local.name_prefix}-lg-${each.key}" }
}

# Alarms
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${local.name_prefix}-alarm-cpu-high"
  alarm_description   = "CPU > 85% for 10 min"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  dimensions          = { AutoScalingGroupName = var.asg_name }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = { Name = "${local.name_prefix}-alarm-cpu-high" }
}

resource "aws_cloudwatch_metric_alarm" "status_check_failed" {
  alarm_name          = "${local.name_prefix}-alarm-status-check-failed"
  alarm_description   = "EC2 status check failure"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  treat_missing_data  = "breaching"
  dimensions          = { AutoScalingGroupName = var.asg_name }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = { Name = "${local.name_prefix}-alarm-status-check-failed" }
}

resource "aws_cloudwatch_metric_alarm" "mem_high" {
  alarm_name          = "${local.name_prefix}-alarm-mem-high"
  alarm_description   = "Memory > 90% for 10 min"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "mem_used_percent"
  namespace           = "CloudOpsPlatform/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 90
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = { Name = "${local.name_prefix}-alarm-mem-high" }
}

resource "aws_cloudwatch_metric_alarm" "disk_root_high" {
  alarm_name          = "${local.name_prefix}-alarm-disk-root-high"
  alarm_description   = "Root disk > 85%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "disk_used_percent"
  namespace           = "CloudOpsPlatform/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  dimensions          = { path = "/", fstype = "xfs" }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = { Name = "${local.name_prefix}-alarm-disk-root-high" }
}

resource "aws_cloudwatch_metric_alarm" "cwagent_missing" {
  alarm_name          = "${local.name_prefix}-alarm-cwagent-missing"
  alarm_description   = "No mem_used_percent for 15 min — CloudWatch Agent may be down or instance unresponsive"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  metric_name         = "mem_used_percent"
  namespace           = "CloudOpsPlatform/EC2"
  period              = 300
  statistic           = "SampleCount"
  threshold           = 0
  treat_missing_data  = "ignore"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = { Name = "${local.name_prefix}-alarm-cwagent-missing" }
}

resource "aws_cloudwatch_metric_alarm" "log_ingestion_app_high" {
  alarm_name          = "${local.name_prefix}-alarm-log-ingestion-app-high"
  alarm_description   = "App log ingestion > 500MB/24h"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "IncomingBytes"
  namespace           = "AWS/Logs"
  period              = 86400
  statistic           = "Sum"
  threshold           = 524288000
  treat_missing_data  = "notBreaching"
  dimensions          = { LogGroupName = "/aws/ec2/${var.workload_name}/app" }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  tags                = { Name = "${local.name_prefix}-alarm-log-ingestion-app-high" }
}

# EventBridge rules
resource "aws_cloudwatch_event_rule" "ec2_state_change" {
  name        = "${local.name_prefix}-evt-ec2-state-change"
  description = "Alert when a workload instance is stopped or terminated"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail      = { state = ["stopped", "terminated"] }
  })
  tags = { Name = "${local.name_prefix}-evt-ec2-state-change" }
}

resource "aws_cloudwatch_event_target" "ec2_state_change_sns" {
  rule      = aws_cloudwatch_event_rule.ec2_state_change.name
  target_id = "SNSAlerts"
  arn       = aws_sns_topic.alerts.arn
}

resource "aws_cloudwatch_event_rule" "ssm_run_command_failed" {
  name        = "${local.name_prefix}-evt-ssm-run-command-failed"
  description = "Alert when an SSM Run Command invocation fails"
  event_pattern = jsonencode({
    source      = ["aws.ssm"]
    detail-type = ["EC2 Command Invocation Status-change Notification"]
    detail      = { status = ["Failed", "TimedOut", "Cancelled"] }
  })
  tags = { Name = "${local.name_prefix}-evt-ssm-run-command-failed" }
}

resource "aws_cloudwatch_event_target" "ssm_failed_sns" {
  rule      = aws_cloudwatch_event_rule.ssm_run_command_failed.name
  target_id = "SNSAlerts"
  arn       = aws_sns_topic.alerts.arn
}

resource "aws_cloudwatch_event_rule" "backup_job_failed" {
  name        = "${local.name_prefix}-evt-backup-job-failed"
  description = "Alert when an AWS Backup job fails"
  event_pattern = jsonencode({
    source      = ["aws.backup"]
    detail-type = ["Backup Job State Change"]
    detail      = { state = ["FAILED", "EXPIRED", "ABORTED"] }
  })
  tags = { Name = "${local.name_prefix}-evt-backup-job-failed" }
}

resource "aws_cloudwatch_event_target" "backup_failed_sns" {
  rule      = aws_cloudwatch_event_rule.backup_job_failed.name
  target_id = "SNSAlerts"
  arn       = aws_sns_topic.alerts.arn
}

resource "aws_cloudwatch_event_rule" "kms_key_deletion" {
  name        = "${local.name_prefix}-evt-kms-key-deletion"
  description = "Alert when platform CMK is scheduled for deletion"
  event_pattern = jsonencode({
    source      = ["aws.kms"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["kms.amazonaws.com"]
      eventName   = ["ScheduleKeyDeletion"]
    }
  })
  tags = { Name = "${local.name_prefix}-evt-kms-key-deletion" }
}

resource "aws_cloudwatch_event_target" "kms_deletion_sns" {
  rule      = aws_cloudwatch_event_rule.kms_key_deletion.name
  target_id = "SNSAlerts"
  arn       = aws_sns_topic.alerts.arn
}

resource "aws_cloudwatch_event_rule" "break_glass_assumed" {
  name        = "${local.name_prefix}-evt-break-glass-assumed"
  description = "Alert when the break-glass emergency role is assumed"
  event_pattern = jsonencode({
    source      = ["aws.sts"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["sts.amazonaws.com"]
      eventName   = ["AssumeRole"]
      requestParameters = {
        roleArn = [var.break_glass_role_arn]
      }
    }
  })
  tags = { Name = "${local.name_prefix}-evt-break-glass-assumed" }
}

resource "aws_cloudwatch_event_target" "break_glass_sns" {
  rule      = aws_cloudwatch_event_rule.break_glass_assumed.name
  target_id = "SNSAlerts"
  arn       = aws_sns_topic.alerts.arn
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "overview" {
  dashboard_name = "${local.name_prefix}-dashboard-overview"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "CPU Utilization"
          region  = local.region
          metrics = [["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.asg_name]]
          period  = 300
          stat    = "Average"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Memory Used %"
          region  = local.region
          metrics = [["CloudOpsPlatform/EC2", "mem_used_percent"]]
          period  = 300
          stat    = "Average"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Disk Used % (root)"
          region  = local.region
          metrics = [["CloudOpsPlatform/EC2", "disk_used_percent", "path", "/", "fstype", "xfs"]]
          period  = 300
          stat    = "Average"
          view    = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Status Check Failed"
          region  = local.region
          metrics = [["AWS/EC2", "StatusCheckFailed", "AutoScalingGroupName", var.asg_name]]
          period  = 60
          stat    = "Maximum"
          view    = "timeSeries"
        }
      },
      {
        type   = "alarm"
        x      = 0
        y      = 12
        width  = 24
        height = 3
        properties = {
          title = "Platform Alarms"
          alarms = [
            "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:${local.name_prefix}-alarm-cpu-high",
            "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:${local.name_prefix}-alarm-mem-high",
            "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:${local.name_prefix}-alarm-disk-root-high",
            "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:${local.name_prefix}-alarm-status-check-failed",
            "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:${local.name_prefix}-alarm-cwagent-missing",
          ]
        }
      },
    ]
  })
}

# SSM Parameter Store
resource "aws_ssm_parameter" "cloudwatch_agent_config" {
  name        = "/${var.project}/${var.environment}/cloudwatch-agent/config/standard"
  description = "CloudWatch Agent configuration JSON for ${var.workload_name}"
  type        = "String"
  value       = file("${path.module}/templates/cloudwatch-agent-config.json")
  tags        = { Name = "${local.name_prefix}-param-cwagent-config" }
  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "app_log_level" {
  name        = "/${var.project}/${var.environment}/app/${var.workload_name}/log-level"
  description = "Log verbosity for ${var.workload_name}"
  type        = "String"
  value       = var.app_log_level
  tags        = { Name = "${local.name_prefix}-param-app-log-level" }
}

resource "aws_ssm_parameter" "app_api_token" {
  name        = "/${var.project}/${var.environment}/app/${var.workload_name}/api-token"
  description = "API token for ${var.workload_name} — SecureString encrypted with platform CMK"
  type        = "SecureString"
  key_id      = var.kms_key_arn
  value       = var.app_api_token
  tags        = { Name = "${local.name_prefix}-param-app-api-token" }
  lifecycle {
    ignore_changes = [value]
  }
}

# AWS Budgets
resource "aws_budgets_budget" "monthly" {
  name         = "${local.name_prefix}-budget-monthly"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [
      { threshold = 50, type = "ACTUAL" },
      { threshold = 80, type = "ACTUAL" },
      { threshold = 100, type = "ACTUAL" },
    ]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = [var.alert_email]
    }
  }
}
