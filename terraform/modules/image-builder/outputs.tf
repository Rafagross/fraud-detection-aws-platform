output "pipeline_arn" {
  description = "ARN of the Image Builder pipeline."
  value       = aws_imagebuilder_image_pipeline.golden_al2023_arm64.arn
}

output "pipeline_name" {
  description = "Name of the Image Builder pipeline."
  value       = aws_imagebuilder_image_pipeline.golden_al2023_arm64.name
}

output "recipe_arn" {
  description = "ARN of the Image Builder recipe."
  value       = aws_imagebuilder_image_recipe.golden_al2023_arm64.arn
}

output "base_ami_id" {
  description = "Current AL2023 arm64 base AMI ID."
  value       = data.aws_ssm_parameter.al2023_arm64.value
}
