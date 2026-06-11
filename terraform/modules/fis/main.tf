##############################################################################
# Module: fis
# Purpose: AWS Fault Injection Service — chaos experiment that terminates one
#          workload instance to validate ASG self-healing (min=max=2).
#          Experiment logs go to a CloudWatch Log Group.
##############################################################################

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
}

resource "aws_cloudwatch_log_group" "fis_experiments" {
  name              = "/aws/fis/${local.name_prefix}-experiments"
  retention_in_days = 30
  tags              = { Name = "${local.name_prefix}-lg-fis-experiments" }
}

# FIS uses delivery.logs.amazonaws.com to write experiment logs.
# That service principal requires an explicit CloudWatch Logs resource policy on the log group.
resource "aws_cloudwatch_log_resource_policy" "fis_delivery" {
  policy_name = "${local.name_prefix}-fis-log-delivery"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.fis_experiments.arn}:*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role" "fis" {
  name = "${local.name_prefix}-role-fis"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Name = "${local.name_prefix}-role-fis" }
}

resource "aws_iam_role_policy" "fis_ec2_terminate" {
  name = "${local.name_prefix}-policy-fis-ec2-terminate"
  role = aws_iam_role.fis.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerminateTaggedInstances"
        Effect = "Allow"
        Action = ["ec2:TerminateInstances"]
        Resource = ["arn:aws:ec2:*:*:instance/*"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Project"     = "${var.project}-platform"
            "aws:ResourceTag/Environment" = var.environment
          }
        }
      },
      {
        Sid    = "DescribeInstances"
        Effect = "Allow"
        Action = ["ec2:DescribeInstances"]
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_role_policy" "fis_logs" {
  name = "${local.name_prefix}-policy-fis-logs"
  role = aws_iam_role.fis.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteFISExperimentLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        Resource = [
          aws_cloudwatch_log_group.fis_experiments.arn,
          "${aws_cloudwatch_log_group.fis_experiments.arn}:*",
        ]
      },
      {
        Sid    = "FISLogDelivery"
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
        ]
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_fis_experiment_template" "terminate_one_instance" {
  description = "Terminate one workload instance — validates ASG self-healing (min=max=2 recovers in <2 min)"
  role_arn    = aws_iam_role.fis.arn

  # No automated stop condition — experiment scope is COUNT(1), blast radius is bounded.
  stop_condition {
    source = "none"
  }

  action {
    name      = "terminate-one-ec2-instance"
    action_id = "aws:ec2:terminate-instances"
    target {
      key   = "Instances"
      value = "workload-instances"
    }
  }

  target {
    name           = "workload-instances"
    resource_type  = "aws:ec2:instance"
    selection_mode = "COUNT(1)"
    resource_tag {
      key   = "Project"
      value = "${var.project}-platform"
    }
    resource_tag {
      key   = "Environment"
      value = var.environment
    }
  }

  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis_experiments.arn}:*"
    }
  }

  tags = { Name = "${local.name_prefix}-fis-terminate-one-instance" }
}
