output "experiment_template_id" {
  description = "ID of the FIS experiment template for the terminate-one-instance chaos experiment."
  value       = aws_fis_experiment_template.terminate_one_instance.id
}
