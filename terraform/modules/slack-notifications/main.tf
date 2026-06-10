##############################################################################
# Module: slack-notifications
# Purpose: Lambda function subscribed to the platform SNS topic; formats
#          CloudWatch alarms and GuardDuty findings and posts to Slack.
#
# Flow: SNS → Lambda → Slack Incoming Webhook
# The webhook URL is stored encrypted as a Lambda environment variable (CMK).
##############################################################################

locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ---------------------------------------------------------------------------
# Lambda package — zip the handler at plan time
# ---------------------------------------------------------------------------

data "archive_file" "handler" {
  type        = "zip"
  source_file = "${path.module}/templates/handler.py"
  output_path = "${path.module}/templates/handler.zip"
}

# ---------------------------------------------------------------------------
# IAM role for Lambda execution
# ---------------------------------------------------------------------------

resource "aws_iam_role" "slack_lambda" {
  name = "${local.name_prefix}-role-lambda-slack-notify"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Name = "${local.name_prefix}-role-lambda-slack-notify" }
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.slack_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_kms" {
  name = "${local.name_prefix}-policy-lambda-slack-kms"
  role = aws_iam_role.slack_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AllowKMSDecryptEnvVars"
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource = var.kms_key_arn
    }]
  })
}

# ---------------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------------

resource "aws_lambda_function" "slack_notify" {
  function_name = "${local.name_prefix}-fn-slack-notify"
  description   = "Forwards platform SNS alerts to Slack via Incoming Webhook"
  role          = aws_iam_role.slack_lambda.arn
  runtime       = "python3.12"
  handler       = "handler.handler"

  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256

  timeout     = 10
  memory_size = 128

  kms_key_arn = var.kms_key_arn

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }

  tags = { Name = "${local.name_prefix}-fn-slack-notify" }
}

resource "aws_cloudwatch_log_group" "slack_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.slack_notify.function_name}"
  retention_in_days = 14
  kms_key_id        = var.kms_key_arn

  tags = { Name = "${local.name_prefix}-lg-lambda-slack-notify" }
}

# ---------------------------------------------------------------------------
# SNS → Lambda subscription
# ---------------------------------------------------------------------------

resource "aws_lambda_permission" "sns_invoke" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notify.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.sns_topic_arn
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = var.sns_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notify.arn
}
