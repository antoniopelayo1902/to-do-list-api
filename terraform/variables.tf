variable "aws_region" {
  description = "Región de AWS (Learner Lab usa us-east-1)"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo para nombrar los recursos"
  type        = string
  default     = "todo-list-api"
}

variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
  default     = "t3.micro"
}

variable "instance_profile_name" {
  description = "Instance profile de la EC2. En Learner Lab no se pueden crear roles, se usa el que ya existe."
  type        = string
  default     = "LabInstanceProfile"
}

variable "repo_url" {
  description = "URL HTTPS del repositorio público que clona user_data"
  type        = string
}

variable "repo_branch" {
  description = "Rama que clona user_data al arrancar"
  type        = string
  default     = "main"
}

variable "app_version" {
  description = "Versión inicial que reporta GET /version antes del primer deploy"
  type        = string
  default     = "v0.0.0"
}

variable "app_port" {
  description = "Puerto de la API"
  type        = number
  default     = 8000
}

variable "ssh_public_key" {
  description = "Llave pública para el Key Pair (la privada vive en el secret EC2_SSH_PRIVATE_KEY de GitHub)"
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs que pueden entrar por SSH (puerto 22)"
  type        = list(string)

  validation {
    condition     = length(var.ssh_allowed_cidrs) > 0 && alltrue([for c in var.ssh_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "ssh_allowed_cidrs debe ser una lista de CIDRs válidos, p. ej. [\"203.0.113.10/32\"]."
  }
}

variable "app_allowed_cidrs" {
  description = "CIDRs que pueden llamar a la API (puerto app_port)"
  type        = list(string)

  validation {
    condition     = length(var.app_allowed_cidrs) > 0 && alltrue([for c in var.app_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "app_allowed_cidrs debe ser una lista de CIDRs válidos."
  }
}

variable "alert_email" {
  description = "Correo que recibe las alarmas vía SNS"
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email debe ser un correo válido."
  }
}

variable "db_engine_version" {
  description = "Versión de PostgreSQL. Revisa las disponibles con: aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[].EngineVersion'"
  type        = string
  default     = "16.9"
}

variable "db_instance_class" {
  description = "Clase de la instancia RDS"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Nombre de la base de datos"
  type        = string
  default     = "todo"
}

variable "db_username" {
  description = "Usuario administrador de RDS"
  type        = string
  default     = "todoadmin"
}

variable "secret_name" {
  description = "Nombre del secret en Secrets Manager con las credenciales de RDS"
  type        = string
  default     = "todo-list-api/db-credentials"
}

variable "metrics_namespace" {
  description = "Namespace de CloudWatch para las métricas propias"
  type        = string
  default     = "TodoApp"
}
