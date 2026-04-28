# ============================================================================
# OptiCloud - Plataforma de Gestión y Optimización de Costos Cloud
# Arquitectura desplegada en AWS - Fiel al diagrama de despliegue
# ============================================================================
# ASRs validados por esta arquitectura:
#   - Disponibilidad (Detección):  Health Monitor detecta fallas en <= 200ms
#   - Disponibilidad (Reparación): ALB + Exception Handler en <= 2s
#   - Seguridad (Detección):       IDS Middleware detecta spoofing en <= 200ms
#   - Seguridad (Reparación):      Anomaly Detector bloquea anomalías al instante
# ============================================================================

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ----------------------------------------------------------------------------
# Variables - fácil de modificar
# ----------------------------------------------------------------------------
variable "project_name" {
  description = "Prefijo de los recursos"
  type        = string
  default     = "opticloud"
}

variable "db_username" {
  description = "Usuario maestro de RDS"
  type        = string
  default     = "opticloud_admin"
}

variable "db_password" {
  description = "Password maestro de RDS - cambiar antes de producción"
  type        = string
  default     = "OptiCloud2025Secure"
  sensitive   = true
}

# AMI Ubuntu 24.04 LTS oficial de Canonical
data "aws_ami" "ubuntu_2404" {
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

# ----------------------------------------------------------------------------
# RED - VPC default según el diagrama (AWS-Default VPC)
# ----------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

# Subnets de las dos zonas que aparecen en el diagrama: us-east-1a y us-east-1b
data "aws_subnet" "default_a" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "us-east-1a"
  default_for_az    = true
}

data "aws_subnet" "default_b" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = "us-east-1b"
  default_for_az    = true
}

# ----------------------------------------------------------------------------
# SECURITY GROUPS - mínimos según el diagrama
# ----------------------------------------------------------------------------

# SG del ALB: HTTP:80 desde Internet (puerto del diagrama)
resource "aws_security_group" "alb_sg" {
  name        = "${var.project_name}-alb-sg"
  description = "ALB - HTTP 80 desde Internet"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP desde Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-alb-sg" }
}

# SG de Web Servers: solo desde ALB + SSH para administración
resource "aws_security_group" "web_sg" {
  name        = "${var.project_name}-web-sg"
  description = "Web Servers Django - puerto 8000 desde ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Django desde ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "SSH (ajustar CIDR en producción)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-web-sg" }
}

# SG del BD Server EC2 (cache Redis para reportes pre-procesados)
resource "aws_security_group" "bd_sg" {
  name        = "${var.project_name}-bd-sg"
  description = "BD Server - cache Redis desde Web Servers"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Redis desde Web Servers"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  ingress {
    description = "SSH (ajustar CIDR en producción)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-bd-sg" }
}

# SG de RDS: solo Web Servers
resource "aws_security_group" "rds_sg" {
  name        = "${var.project_name}-rds-sg"
  description = "RDS Persistencia - PostgreSQL desde Web Servers"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "PostgreSQL desde Web Servers"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-rds-sg" }
}

# ----------------------------------------------------------------------------
# RDS - Persistencia (Type: Dev/Test, Storage: 1TB - según el diagrama)
# ----------------------------------------------------------------------------
resource "aws_db_subnet_group" "rds_subnets" {
  name       = "${var.project_name}-rds-subnets"
  subnet_ids = [data.aws_subnet.default_a.id, data.aws_subnet.default_b.id]
  tags       = { Name = "${var.project_name}-rds-subnets" }
}

resource "aws_db_instance" "persistencia" {
  identifier     = "${var.project_name}-persistencia"
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = "db.t3.micro" # default Dev/Test económico

  # Storage 1TB según el diagrama
  allocated_storage     = 1000
  max_allocated_storage = 1000
  storage_type          = "gp3"

  db_name  = "opticloud"
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.rds_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  skip_final_snapshot = true
  publicly_accessible = false
  multi_az            = false # Dev/Test - una sola AZ

  tags = { Name = "${var.project_name}-rds-persistencia" }
}

# ----------------------------------------------------------------------------
# WEB SERVERS - 3 instancias t3.micro Ubuntu 24.04 (fiel al diagrama)
# Cada una corre Django con middlewares que materializan los componentes
# del diagrama: Autenticador, IDS, Anomaly Detector, Response Manager,
# Audit Logger, Health Monitor, Exception Handler, Cola de trabajos,
# Procesador de análisis, Report Cache, Elastic Orchestrator.
# Web Server A además tiene: Validador de resultados + Pre-Generator
# (controlado vía la variable IS_PRIMARY=true).
# ----------------------------------------------------------------------------

# El user_data se construye con templatefile() leyendo userdata.sh.tftpl.
# Esto evita conflictos entre la sintaxis ${} de Terraform y los f-strings
# de Python dentro del script.
locals {
  user_data_a = templatefile("${path.module}/userdata.sh.tftpl", {
    db_user     = var.db_username
    db_password = var.db_password
    db_host     = aws_db_instance.persistencia.address
    server_name = "web-server-a"
    is_primary  = "true"
  })

  user_data_b = templatefile("${path.module}/userdata.sh.tftpl", {
    db_user     = var.db_username
    db_password = var.db_password
    db_host     = aws_db_instance.persistencia.address
    server_name = "web-server-b"
    is_primary  = "false"
  })

  user_data_c = templatefile("${path.module}/userdata.sh.tftpl", {
    db_user     = var.db_username
    db_password = var.db_password
    db_host     = aws_db_instance.persistencia.address
    server_name = "web-server-c"
    is_primary  = "false"
  })
}

# Web Server A - PRIMARY (con Validador, Exception Handler y Pre-Generator)
resource "aws_instance" "web_server_a" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnet.default_a.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  user_data = local.user_data_a

  tags = {
    Name = "${var.project_name}-web-server-a"
    Role = "primary"
  }

  depends_on = [aws_db_instance.persistencia]
}

# Web Server B
resource "aws_instance" "web_server_b" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnet.default_b.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  user_data = local.user_data_b

  tags = {
    Name = "${var.project_name}-web-server-b"
    Role = "secondary"
  }

  depends_on = [aws_db_instance.persistencia]
}

# Web Server C
resource "aws_instance" "web_server_c" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnet.default_a.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  user_data = local.user_data_c

  tags = {
    Name = "${var.project_name}-web-server-c"
    Role = "secondary"
  }

  depends_on = [aws_db_instance.persistencia]
}

# ----------------------------------------------------------------------------
# BD SERVER EC2 (t3.nano) - cache de reportes pre-procesados
# Según el diagrama: "Información preprocesada de reportes recientes y
# cálculos realizados". Implementado con Redis.
# ----------------------------------------------------------------------------
resource "aws_instance" "bd_server" {
  ami                    = data.aws_ami.ubuntu_2404.id
  instance_type          = "t3.nano"
  subnet_id              = data.aws_subnet.default_a.id
  vpc_security_group_ids = [aws_security_group.bd_sg.id]

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y redis-server
    sed -i 's/^bind 127.0.0.1.*/bind 0.0.0.0/' /etc/redis/redis.conf
    sed -i 's/^protected-mode yes/protected-mode no/' /etc/redis/redis.conf
    systemctl enable redis-server
    systemctl restart redis-server
  EOF

  tags = { Name = "${var.project_name}-bd-server" }
}

# ----------------------------------------------------------------------------
# APPLICATION LOAD BALANCER - HTTP:80 según el diagrama
# Distribuye carga entre los 3 Web Servers en us-east-1a y us-east-1b.
# Health checks rápidos para que ASR de reparación funcione.
# ----------------------------------------------------------------------------
resource "aws_lb" "alb" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [data.aws_subnet.default_a.id, data.aws_subnet.default_b.id]

  tags = { Name = "${var.project_name}-alb" }
}

resource "aws_lb_target_group" "web_tg" {
  name     = "${var.project_name}-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  # Health check: parte del ASR de Disponibilidad Reparación.
  # Cuando una instancia falla, el ALB enruta a otros targets sanos
  # de inmediato (ms) por el lado del listener; el target tarda ~20s
  # en quedar marcado como unhealthy formalmente.
  health_check {
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  # Stickiness off: que el ALB pueda re-rutear de inmediato a otro target
  stickiness {
    type    = "lb_cookie"
    enabled = false
  }

  tags = { Name = "${var.project_name}-tg" }
}

resource "aws_lb_target_group_attachment" "web_a" {
  target_group_arn = aws_lb_target_group.web_tg.arn
  target_id        = aws_instance.web_server_a.id
  port             = 8000
}

resource "aws_lb_target_group_attachment" "web_b" {
  target_group_arn = aws_lb_target_group.web_tg.arn
  target_id        = aws_instance.web_server_b.id
  port             = 8000
}

resource "aws_lb_target_group_attachment" "web_c" {
  target_group_arn = aws_lb_target_group.web_tg.arn
  target_id        = aws_instance.web_server_c.id
  port             = 8000
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

# ----------------------------------------------------------------------------
# OUTPUTS - URLs y comandos para validar los ASRs
# ----------------------------------------------------------------------------
output "alb_dns" {
  description = "DNS público del ALB - punto de entrada de la plataforma"
  value       = aws_lb.alb.dns_name
}

output "endpoints" {
  description = "Endpoints disponibles en la plataforma"
  value = {
    home          = "http://${aws_lb.alb.dns_name}/"
    health        = "http://${aws_lb.alb.dns_name}/health"
    report        = "http://${aws_lb.alb.dns_name}/report"
    report_heavy  = "http://${aws_lb.alb.dns_name}/report/heavy"
    simulate_fail = "http://${aws_lb.alb.dns_name}/simulate-failure"
  }
}

output "como_probar_los_asrs" {
  description = "Comandos curl para validar cada ASR"
  value = {
    "1_disponibilidad_deteccion_200ms" = "curl -i -H 'X-Auth-Token: valid-demo' http://${aws_lb.alb.dns_name}/simulate-failure  # ver header X-Health-Detection-Ms"
    "2_disponibilidad_reparacion_2s"   = "curl -s -H 'X-Auth-Token: valid-demo' http://${aws_lb.alb.dns_name}/simulate-failure  # ver campo recovery_ms"
    "3_seguridad_deteccion_spoofing"   = "curl -i http://${aws_lb.alb.dns_name}/report  # sin token, ver ids_detection_ms (debe ser <200ms)"
    "4_seguridad_reparacion_bloqueo"   = "for i in $(seq 1 60); do curl -s -H 'X-Auth-Token: valid-demo' http://${aws_lb.alb.dns_name}/report; done  # tras 50 reqs/10s queda bloqueado"
    "5_request_normal_autenticada"     = "curl -H 'X-Auth-Token: valid-demo' http://${aws_lb.alb.dns_name}/report"
  }
}

output "rds_endpoint" {
  description = "Endpoint privado de RDS"
  value       = aws_db_instance.persistencia.address
}

output "bd_server_private_ip" {
  description = "IP privada del BD Server (cache Redis)"
  value       = aws_instance.bd_server.private_ip
}
