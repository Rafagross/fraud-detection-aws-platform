##############################################################################
# Module: vpc-endpoints
# Purpose: VPC Interface Endpoints for SSM/CloudWatch/EC2 Messages
#          + S3 Gateway Endpoint (free). No KMS endpoint.
#          See docs/architecture.md Section 3.4
##############################################################################

data "aws_region" "current" {}

locals {
  region      = data.aws_region.current.name
  name_prefix = "${var.project}-${var.environment}"
}

resource "aws_security_group" "vpce" {
  name        = "${local.name_prefix}-sg-vpce"
  description = "Allow HTTPS from workload instances to VPC endpoints. No egress rules."
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTPS from workload SG"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [var.workload_sg_id]
  }

  tags = { Name = "${local.name_prefix}-sg-vpce" }
}

locals {
  interface_endpoints = toset([
    "ssm",
    "ssmmessages",
    "ec2messages",
    "logs",
    "monitoring",
    "sqs",        # fraud worker queue consumer (~$7.30/month)
  ])
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${local.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = values(var.private_vpce_subnet_ids)
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = { Name = "${local.name_prefix}-vpce-${each.key}" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [var.private_app_route_table_id]

  tags = { Name = "${local.name_prefix}-vpce-gw-s3" }
}

# DynamoDB Gateway Endpoint — free, same pattern as S3.
# Required for the fraud worker to write decisions without internet egress.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${local.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [var.private_app_route_table_id]

  tags = { Name = "${local.name_prefix}-vpce-gw-dynamodb" }
}
