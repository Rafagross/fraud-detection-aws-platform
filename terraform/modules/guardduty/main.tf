##############################################################################
# Module: guardduty
# Purpose: Enable GuardDuty threat detection with EventBridge routing of
#          HIGH/CRITICAL findings (severity >= 7) to the platform SNS topic.
#
# Finding severity scale: LOW 1-3.9 | MEDIUM 4-6.9 | HIGH 7-8.9 | CRITICAL 9-10
# EventBridge is the intermediary — already allowed to publish to platform SNS.
##############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
}

# ---------------------------------------------------------------------------
# GuardDuty detector
# ---------------------------------------------------------------------------

resource "aws_guardduty_detector" "main" {
  enable = true

  finding_publishing_frequency = var.finding_publishing_frequency

  datasources {
    s3_logs {
      enable = true
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = { Name = "${local.name_prefix}-guardduty-detector" }
}

# ---------------------------------------------------------------------------
# EventBridge rule — route HIGH/CRITICAL findings to SNS
# Severity >= 7.0 covers HIGH (7.0-8.9) and CRITICAL (9.0-10.0)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "guardduty_high_critical" {
  name        = "${local.name_prefix}-rule-guardduty-high-critical"
  description = "Route GuardDuty HIGH and CRITICAL findings to the platform SNS topic"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 7] }]
    }
  })

  tags = { Name = "${local.name_prefix}-rule-guardduty-high-critical" }
}

resource "aws_cloudwatch_event_target" "guardduty_to_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_high_critical.name
  target_id = "guardduty-to-sns"
  arn       = var.sns_topic_arn

  input_transformer {
    input_paths = {
      severity   = "$.detail.severity"
      type       = "$.detail.type"
      account    = "$.detail.accountId"
      region     = "$.detail.region"
      finding_id = "$.detail.id"
      updated_at = "$.detail.updatedAt"
    }
    input_template = "\"GuardDuty Finding\\nSeverity: <severity>\\nType: <type>\\nAccount: <account>\\nRegion: <region>\\nFinding ID: <finding_id>\\nUpdated: <updated_at>\\n\\nReview in AWS Console: https://console.aws.amazon.com/guardduty/home?region=<region>#/findings\""
  }
}
