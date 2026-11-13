terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Backend remoto en S3. El bucket se pasa en `terraform init -backend-config="bucket=..."`
  # (el workflow provision.yml lo crea si no existe). use_lockfile = locking nativo de S3.
  backend "s3" {
    key          = "practica04/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = var.project_name
    }
  }
}

# --------------------------------------------------------------------------- Red
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Ubuntu 24.04 se busca dinámicamente: los AMI IDs fijos no sirven en Learner Lab.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "app" {
  name        = "${var.project_name}-ec2-sg"
  description = "Acceso a la API y SSH para el deploy"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH (deploy desde GitHub Actions)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
  }

  ingress {
    description = "API to-do-list"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = var.app_allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS solo acepta conexiones desde el Security Group de la EC2; nunca desde internet.
resource "aws_security_group" "db" {
  name        = "${var.project_name}-rds-sg"
  description = "PostgreSQL solo desde la EC2 de la app"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "PostgreSQL desde la EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --------------------------------------------------------------------------- Key Pair
resource "aws_key_pair" "deployer" {
  key_name   = "${var.project_name}-key"
  public_key = var.ssh_public_key
}

# --------------------------------------------------------------------------- RDS + Secrets Manager
resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_db_subnet_group" "db" {
  name       = "${var.project_name}-db-subnets"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "db" {
  identifier              = "${var.project_name}-db"
  engine                  = "postgres"
  engine_version          = var.db_engine_version
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  storage_type            = "gp2"
  db_name                 = var.db_name
  username                = var.db_username
  password                = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.db.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  publicly_accessible     = false
  multi_az                = false
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}

resource "aws_secretsmanager_secret" "db" {
  name                    = var.secret_name
  description             = "Credenciales de RDS para ${var.project_name}"
  recovery_window_in_days = 0 # borrado inmediato: permite recrear el mismo nombre en cada sesión del lab
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.db.address
    port     = aws_db_instance.db.port
    dbname   = var.db_name
    username = var.db_username
    password = random_password.db.result
  })
}

# --------------------------------------------------------------------------- EC2
resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.deployer.key_name
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = var.instance_profile_name # LabInstanceProfile: permisos para Secrets Manager y CloudWatch
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    repo_url          = var.repo_url
    repo_branch       = var.repo_branch
    app_version       = var.app_version
    app_port          = var.app_port
    secret_id         = aws_secretsmanager_secret.db.name
    aws_region        = var.aws_region
    metrics_namespace = var.metrics_namespace
  })

  metadata_options {
    http_tokens = "required" # IMDSv2
  }

  tags = {
    Name = "${var.project_name}-ec2"
  }
}

# --------------------------------------------------------------------------- Observabilidad
locals {
  # Las alarmas viven en alerting/alarms.json; aquí solo se sustituyen los tokens.
  alarm_config = jsondecode(replace(replace(
    file("${path.module}/../alerting/alarms.json"),
    "__NAMESPACE__", var.metrics_namespace),
  "__PROJECT__", var.project_name))

  alarms = { for a in local.alarm_config.alarms : a.name => a }
}

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "app" {
  for_each = local.alarms

  alarm_name          = each.value.name
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric_name
  statistic           = each.value.statistic
  period              = each.value.period
  evaluation_periods  = each.value.evaluation_periods
  datapoints_to_alarm = each.value.datapoints_to_alarm
  threshold           = each.value.threshold
  comparison_operator = each.value.comparison_operator
  treat_missing_data  = each.value.treat_missing_data
  dimensions          = { for k, v in each.value.dimensions : k => replace(v, "__INSTANCE_ID__", aws_instance.app.id) }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "app" {
  dashboard_name = "${var.project_name}-dashboard"
  dashboard_body = replace(replace(replace(
    file("${path.module}/../alerting/cloudwatch-dashboard.json"),
    "__INSTANCE_ID__", aws_instance.app.id),
    "__NAMESPACE__", var.metrics_namespace),
  "__REGION__", var.aws_region)
}
