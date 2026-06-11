output "enabled_resource_types" {
  description = "Resource types enabled for Inspector v2 scanning."
  value       = aws_inspector2_enabler.platform.resource_types
}
