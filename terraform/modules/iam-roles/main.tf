##############################################################################
# Module: iam-roles
# Purpose: All platform IAM roles with least-privilege inline policies.
#          See docs/security-baseline.md Section 3
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
  name_prefix = "${var.project}-${var.environment}"
}

resource "aws_iam_role" "workload" {
  name = "${local.name_prefix}-role-workload"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${local.name_prefix}-role-workload" }
}

resource "aws_iam_role_policy_attachment" "workload_ssm_core" {
  role       = aws_iam_role.workload.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "workload_inline" {
  name = "${local.name_prefix}-policy-workload-inline"
  role = aws_iam_role.workload.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowPutMetricData"
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "CloudOpsPlatform/EC2" }
        }
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = [
          "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/ec2/${var.workload_name}/*:*",
          "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/ssm/sessions:*",
        ]
      },
      {
        Sid    = "AllowSSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = [
          "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${var.project}/${var.environment}/app/${var.workload_name}/*",
          "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${var.project}/${var.environment}/cloudwatch-agent/*",
          "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${var.project}/${var.environment}/golden-ami/*",
        ]
      },
      {
        Sid    = "AllowKMSViaService"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = var.kms_key_arn
        Condition = {
          StringLike = {
            "kms:ViaService" = [
              "ec2.${local.region}.amazonaws.com",
              "ssm.${local.region}.amazonaws.com",
              "logs.${local.region}.amazonaws.com",
              "s3.${local.region}.amazonaws.com",
            ]
          }
        }
      },
      {
        Sid      = "AllowS3DiagnosticsPut"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${var.diagnostics_bucket_name}/*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "workload" {
  name = "${local.name_prefix}-iprofile-workload"
  role = aws_iam_role.workload.name
  tags = { Name = "${local.name_prefix}-iprofile-workload" }
}

resource "aws_iam_role" "aws_backup" {
  name = "${local.name_prefix}-role-aws-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${local.name_prefix}-role-aws-backup" }
}

resource "aws_iam_role_policy_attachment" "backup_policy" {
  role       = aws_iam_role.aws_backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore_policy" {
  role       = aws_iam_role.aws_backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_iam_role" "break_glass" {
  name                 = "${local.name_prefix}-role-break-glass"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {
        Bool = { "aws:MultiFactorAuthPresent" = "true" }
      }
    }]
  })

  tags = {
    Name        = "${local.name_prefix}-role-break-glass"
    Description = "EMERGENCY USE ONLY. Assumption triggers SNS alert via EventBridge."
  }
}

resource "aws_iam_role_policy" "break_glass_inline" {
  name = "${local.name_prefix}-policy-break-glass"
  role = aws_iam_role.break_glass.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowBackupVaultDestructive"
        Effect   = "Allow"
        Action   = ["backup:DeleteRecoveryPoint", "backup:DeleteBackupVault"]
        Resource = "*"
      },
      {
        Sid      = "AllowKMSKeyDeletion"
        Effect   = "Allow"
        Action   = ["kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion"]
        Resource = var.kms_key_arn
      },
      {
        Sid      = "AllowReadEverything"
        Effect   = "Allow"
        Action   = ["ec2:Describe*", "ssm:Describe*", "ssm:Get*", "logs:*", "backup:Describe*", "backup:List*"]
        Resource = "*"
      },
    ]
  })
}
