##############################################################################
# backend.tf — Remote state configuration
# Prerequisites:
#   1. Create an S3 bucket for state storage (versioning + encryption enabled)
#   2. Create a DynamoDB table for state locking (partition key: LockID, type: S)
#   3. Fill in the bucket/table names below before running terraform init
##############################################################################

terraform {
  backend "s3" {
    bucket         = "cloudops-tfstate-776648109094"
    key            = "cloudops/dev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    use_lockfile   = true
  }
}
