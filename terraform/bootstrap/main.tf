##############################################################################
# Bootstrap — Terraform remote state backend
#
# Creates the S3 bucket and DynamoDB table that terraform/envs/dev uses as
# its remote backend. This module itself uses LOCAL state (no backend block).
#
# Run order:
#   1. terraform init && terraform apply   (this directory)
#   2. Copy the output backend_config into terraform/envs/dev/backend.tf
#   3. cd ../envs/dev && terraform init
#
# Destroy order (AFTER destroying envs/dev):
#   1. Empty the S3 bucket manually or via: aws s3 rm s3://<bucket> --recursive
#   2. terraform destroy  (this directory)
##############################################################################

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
  table_name  = "${var.project}-tfstate-lock"
}

# ---------------------------------------------------------------------------
# S3 — state storage
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name

  tags = { Name = local.bucket_name }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket     = aws_s3_bucket.tfstate.id
  depends_on = [aws_s3_bucket_versioning.tfstate]

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    noncurrent_version_expiration { noncurrent_days = 90 }

    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

# ---------------------------------------------------------------------------
# DynamoDB — state locking
# Prevents concurrent terraform apply runs from corrupting state.
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = { Name = local.table_name }
}
