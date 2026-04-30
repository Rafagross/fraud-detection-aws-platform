output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Map of public subnet IDs keyed by AZ suffix."
  value       = { for k, v in aws_subnet.public : k => v.id }
}

output "private_app_subnet_ids" {
  description = "Map of private workload subnet IDs keyed by AZ suffix."
  value       = { for k, v in aws_subnet.private_app : k => v.id }
}

output "private_vpce_subnet_ids" {
  description = "Map of private endpoint subnet IDs keyed by AZ suffix."
  value       = { for k, v in aws_subnet.private_vpce : k => v.id }
}

output "private_app_route_table_id" {
  description = "Route table ID for private workload subnets."
  value       = aws_route_table.private_app.id
}

output "private_vpce_route_table_id" {
  description = "Route table ID for private endpoint subnets."
  value       = aws_route_table.private_vpce.id
}

output "flow_log_group_arn" {
  description = "CloudWatch Log Group ARN for VPC Flow Logs."
  value       = aws_cloudwatch_log_group.flow_logs.arn
}
