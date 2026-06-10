##############################################################################
# Module: backup
# Purpose: AWS Backup vault, plan, and selection.
#          Single operational vault — see docs/backup-strategy.md
##############################################################################

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
}

resource "aws_backup_vault" "platform" {
  name        = "${local.name_prefix}-vault-platform"
  kms_key_arn = var.kms_key_arn

  tags = { Name = "${local.name_prefix}-vault-platform" }
}

resource "aws_backup_plan" "daily" {
  name = "${local.name_prefix}-bp-daily"

  rule {
    rule_name         = "daily-0500-utc"
    target_vault_name = aws_backup_vault.platform.name
    schedule          = "cron(0 5 * * ? *)"

    lifecycle {
      cold_storage_after = 7
      delete_after       = 97
    }

    recovery_point_tags = {
      BackupPlan  = "daily"
      Project     = "${var.project}-platform"
      Environment = var.environment
    }
  }

  tags = { Name = "${local.name_prefix}-bp-daily" }
}

resource "aws_backup_selection" "tagged_daily" {
  name         = "${local.name_prefix}-bsel-tagged-daily"
  plan_id      = aws_backup_plan.daily.id
  iam_role_arn = var.backup_role_arn

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Backup"
    value = "daily"
  }
}
