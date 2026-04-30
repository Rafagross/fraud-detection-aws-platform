output "vpce_sg_id" {
  description = "Security group ID attached to all VPC Interface Endpoints."
  value       = aws_security_group.vpce.id
}

output "interface_endpoint_ids" {
  description = "Map of interface endpoint IDs keyed by service name."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "s3_endpoint_id" {
  description = "S3 Gateway Endpoint ID."
  value       = aws_vpc_endpoint.s3.id
}
