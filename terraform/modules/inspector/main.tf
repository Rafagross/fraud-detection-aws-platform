##############################################################################
# Module: inspector
# Purpose: Enable Amazon Inspector v2 for continuous EC2 vulnerability scanning.
#          Scans all running instances for OS-level CVEs automatically.
##############################################################################

data "aws_caller_identity" "current" {}

resource "aws_inspector2_enabler" "platform" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2"]
}
