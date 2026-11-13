output "instance_id" {
  description = "ID de la instancia EC2"
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "IP pública de la EC2"
  value       = aws_instance.app.public_ip
}

output "app_url" {
  description = "URL base de la API"
  value       = "http://${aws_instance.app.public_ip}:${var.app_port}"
}

output "rds_endpoint" {
  description = "Endpoint de RDS (solo accesible desde la EC2)"
  value       = aws_db_instance.db.address
}

output "rds_identifier" {
  description = "Identificador de RDS (para detenerla y probar la alarma)"
  value       = aws_db_instance.db.identifier
}

output "secret_name" {
  description = "Secret con las credenciales de RDS"
  value       = aws_secretsmanager_secret.db.name
}

output "sns_topic_arn" {
  description = "Tópico SNS de las alarmas"
  value       = aws_sns_topic.alerts.arn
}

output "dashboard_url" {
  description = "Dashboard de CloudWatch"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.app.dashboard_name}"
}
