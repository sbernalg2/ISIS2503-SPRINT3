###############################################################################
# OptiCloud – Infraestructura AWS para validar ASRs (Sprint 3 - v4)
#
# ASR-1 · Escalabilidad  : Pico 12k usuarios / 10 min  -> Auto Scaling Group
# ASR-2 · Latencia       : <= 100 ms con 5k sostenidos -> Report Cache + Pre-Generator
# ASR-DISP-DET · Deteccion falla <= 200 ms             -> Health Monitor (Web Server)
# ASR-DISP-REP · Recuperacion <= 2 s sin perdida       -> Exception Handler + Validador
# ASR-SEG-DET  · Deteccion acceso anomalo <= 200 ms    -> IDS + Anomaly Detector
# ASR-SEG-REP  · Bloqueo inmediato de IP               -> Response Manager
#
# Arquitectura fiel al diagrama de despliegue v3 CONFIRMADO:
#
#   Web Servers A/B/C (ASG, t3.small, IDENTICOS):
#     Django con todos los componentes:
#       Report Cache, Elastic Orchestrator, Report Pre-Generator,
#       Health Monitor, Exception Handler, Validador de resultados,
#       IDS, Autenticador, Anomaly Detector, Audit Logger,
#       Response Manager, Cola de trabajos, Procesador de Analisis
#
#   BD Server (EC2, t3.small): SOLO JMeter
#     NO tiene Django, NO tiene worker, NO accede a RDS
#
#   RDS PostgreSQL: Persistencia (jobs, reportes, audit log)
#   ALB: HTTP:80 zonas us-east-2a / us-east-2b
###############################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
  required_version = ">= 1.3.0"
}

provider "aws" {
  region = "us-east-2"
}

###############################################################################
# VARIABLES
###############################################################################

variable "ami_id" {
  description = "Ubuntu 24.04 LTS en us-east-2"
  default     = "ami-07062e2a343acc423"
}

variable "db_password" {
  description = "Contrasena para la base de datos RDS"
  type        = string
  sensitive   = true
  default     = "OptiCloud2024!"
}

variable "db_username" {
  description = "Usuario administrador de RDS"
  default     = "opticloud_admin"
}

###############################################################################
# KEY PAIR – SSH para acceder a Web Servers y BD Server
###############################################################################

resource "tls_private_key" "opticloud_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "opticloud_key" {
  key_name   = "opticloud-keypair"
  public_key = tls_private_key.opticloud_key.public_key_openssh
}

resource "local_file" "private_key_pem" {
  content         = tls_private_key.opticloud_key.private_key_pem
  filename        = "${path.module}/opticloud_key.pem"
  file_permission = "0400"
}

###############################################################################
# VPC – Default VPC (AWS-Default VPC segun diagrama)
###############################################################################

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "az_a" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availabilityZone"
    values = ["us-east-2a"]
  }
}

data "aws_subnet" "az_b" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availabilityZone"
    values = ["us-east-2b"]
  }
}

###############################################################################
# SECURITY GROUPS
###############################################################################

# ALB: HTTP:80 desde Internet
resource "aws_security_group" "alb_sg" {
  name        = "opticloud-alb-sg"
  description = "HTTP entrante al ALB desde Internet"
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

  tags = { Name = "opticloud-alb-sg" }
}

# Web Servers: puerto 8000 desde ALB + SSH para experimentos ASR
resource "aws_security_group" "web_sg" {
  name        = "opticloud-web-sg"
  description = "ALB Django 8000 SSH experimentos ASR"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Django desde el ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "SSH para experimentos ASR"
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

  tags = { Name = "opticloud-web-sg" }
}

# BD Server: SOLO SSH. Solo corre JMeter, no necesita RDS.
# v4: eliminada la regla de RDS (ya no es un worker Python)
resource "aws_security_group" "bd_server_sg" {
  name        = "opticloud-bd-server-sg"
  description = "BD Server solo JMeter: SSH + egress al ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH para lanzar pruebas JMeter"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "JMeter necesita salida al ALB"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "opticloud-bd-server-sg" }
}

# RDS: solo desde Web Servers
# v4: eliminada regla del pregenerator (ya no existe como worker separado)
resource "aws_security_group" "rds_sg" {
  name        = "opticloud-rds-sg"
  description = "PostgreSQL solo desde Web Servers Django"
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

  tags = { Name = "opticloud-rds-sg" }
}

###############################################################################
# RDS – Persistencia
# Tablas: pregenerated_reports, analysis_jobs, security_audit_log
###############################################################################

resource "aws_db_subnet_group" "opticloud" {
  name       = "opticloud-db-subnet-group"
  subnet_ids = [data.aws_subnet.az_a.id, data.aws_subnet.az_b.id]
  tags       = { Name = "opticloud-db-subnet-group" }
}

resource "aws_db_instance" "opticloud_db" {
  identifier             = "opticloud-postgres"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  storage_type           = "gp2"
  db_name                = "opticloud"
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.opticloud.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot    = true
  publicly_accessible    = false
  multi_az               = false
  tags                   = { Name = "opticloud-postgres-rds" }
}

###############################################################################
# BD SERVER – Solo JMeter (segun diagrama de despliegue v3 confirmado)
#
# v4: reemplaza el worker Python anterior.
# Rol: lanzar pruebas de carga para validar ASR-1 y ASR-2.
# No tiene Django, no accede a RDS, no tiene Pre-Generator.
###############################################################################

resource "aws_instance" "bd_server" {
  ami                    = var.ami_id
  instance_type          = "t3.small"
  subnet_id              = data.aws_subnet.az_a.id
  vpc_security_group_ids = [aws_security_group.bd_server_sg.id]
  key_name               = aws_key_pair.opticloud_key.key_name

  root_block_device {
    volume_size = 8
    volume_type = "gp2"
  }

  user_data = base64encode(file("${path.module}/scripts/setup_bdserver.sh"))

  tags = { Name = "opticloud-bd-server" }
}

###############################################################################
# LAUNCH TEMPLATE – Web Servers A/B/C (identicos entre si)
#
# Todos los componentes del diagrama de componentes en Django:
#   Report Cache + Pre-Generator + Elastic Orchestrator
#   Health Monitor + Exception Handler + Validador de resultados
#   IDS + Autenticador + Anomaly Detector + Audit Logger + Response Manager
#   Cola de trabajos + Procesador de Analisis
###############################################################################

resource "aws_launch_template" "web_server" {
  name_prefix   = "opticloud-web-"
  image_id      = var.ami_id
  instance_type = "t3.small"
  key_name      = aws_key_pair.opticloud_key.key_name

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.web_sg.id]
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 8
      volume_type = "gp2"
    }
  }

  user_data = file("${path.module}/scripts/setup_webserver.sh.b64gz")

  tags = { Name = "opticloud-web-server" }

  depends_on = [aws_db_instance.opticloud_db]
}

###############################################################################
# APPLICATION LOAD BALANCER
###############################################################################

resource "aws_lb" "opticloud_alb" {
  name               = "opticloud-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [data.aws_subnet.az_a.id, data.aws_subnet.az_b.id]
  tags               = { Name = "opticloud-alb" }
}

resource "aws_lb_target_group" "web_tg" {
  name     = "opticloud-web-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/health/"
    port                = "8000"
    protocol            = "HTTP"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = { Name = "opticloud-web-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.opticloud_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

###############################################################################
# AUTO SCALING GROUP
###############################################################################

resource "aws_autoscaling_group" "web_asg" {
  name                = "opticloud-web-asg"
  min_size            = 1
  max_size            = 6
  desired_capacity    = 3
  vpc_zone_identifier = [data.aws_subnet.az_a.id, data.aws_subnet.az_b.id]

  launch_template {
    id      = aws_launch_template.web_server.id
    version = "$Latest"
  }

  target_group_arns         = [aws_lb_target_group.web_tg.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  tag {
    key                 = "Name"
    value               = "opticloud-web-server"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "opticloud-scale-out"
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 60
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "opticloud-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 60
  alarm_description   = "ASR-1: escala OUT cuando CPU > 60%"
  alarm_actions       = [aws_autoscaling_policy.scale_out.arn]
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.web_asg.name }
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "opticloud-scale-in"
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 120
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "opticloud-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 30
  alarm_description   = "ASR-1: escala IN cuando CPU < 30%"
  alarm_actions       = [aws_autoscaling_policy.scale_in.arn]
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.web_asg.name }
}

###############################################################################
# OUTPUTS
###############################################################################

output "alb_dns_name" {
  description = "DNS del ALB - usalo en JMeter y curl para todos los experimentos"
  value       = aws_lb.opticloud_alb.dns_name
}

output "rds_endpoint" {
  description = "Endpoint RDS PostgreSQL"
  value       = aws_db_instance.opticloud_db.address
}

output "bd_server_public_ip" {
  description = "IP publica BD Server (JMeter). Conectar con opticloud_key.pem"
  value       = aws_instance.bd_server.public_ip
}

output "ssh_instrucciones" {
  description = "Como conectarte a las instancias"
  value       = <<-NOTE
    # BD Server (JMeter):
    ssh -i opticloud_key.pem ubuntu@${aws_instance.bd_server.public_ip}

    # Web Servers (IPs del ASG):
    aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=opticloud-web-server" \
                "Name=instance-state-name,Values=running" \
      --query "Reservations[*].Instances[*].PublicIpAddress" \
      --output text --region us-east-2
    ssh -i opticloud_key.pem ubuntu@<IP>
  NOTE
}

output "experimentos_disponibilidad" {
  description = "Comandos curl para los ASRs de Disponibilidad"
  value       = <<-CMDS
    ALB="${aws_lb.opticloud_alb.dns_name}"

    # Verificar que el sistema esta listo:
    curl -s "http://$ALB/health/"

    # [ASR-DISP-DET] Estado normal (worker_ok: true):
    curl -s "http://$ALB/worker/status/"

    # [ASR-DISP-DET] Simular falla (ver detection_ms <= 200):
    curl -s "http://$ALB/worker/status/?fail=1"

    # [ASR-DISP-REP] Recuperacion (ver recovery_ms <= 2000, validacion_ok: true):
    curl -s -X POST "http://$ALB/worker/recover/"

    # Confirmar que volvio a operacional:
    curl -s "http://$ALB/worker/status/"
  CMDS
}

output "experimentos_seguridad" {
  description = "Comandos curl para los ASRs de Seguridad"
  value       = <<-CMDS
    ALB="${aws_lb.opticloud_alb.dns_name}"

    # [ASR-SEG-DET] Acceso anomalo sin token (detection_ms <= 200):
    curl -s "http://$ALB/security/check/"

    # [ASR-SEG-DET] Acceso legitimo:
    curl -s -H "X-Opticloud-Token: test123" -A "Mozilla/5.0" \
         "http://$ALB/security/check/"

    # [ASR-SEG-DET] Flood de reportes:
    curl -s "http://$ALB/security/check/?flood=1"

    # [ASR-SEG-REP] Bloquear IP sospechosa:
    curl -s -X POST "http://$ALB/security/block/" \
         -H "Content-Type: application/json" \
         -d '{"ip":"1.2.3.4","motivo":"generacion_masiva_reportes"}'

    # Verificar que la IP quedo bloqueada:
    curl -s -H "X-Forwarded-For: 1.2.3.4" "http://$ALB/security/check/"

    # Ver audit log completo:
    curl -s "http://$ALB/security/audit/"
  CMDS
}

output "experimentos_jmeter" {
  description = "Comandos para pruebas de carga desde el BD Server"
  value       = <<-CMDS
    # 1. SSH al BD Server:
    ssh -i opticloud_key.pem ubuntu@${aws_instance.bd_server.public_ip}

    # 2. Configurar ALB en los planes JMeter:
    bash /opt/correr_pruebas.sh ${aws_lb.opticloud_alb.dns_name}

    # 3. [ASR-2] Latencia 5000 usuarios:
    jmeter -n -t /opt/asr_latencia.jmx -l /opt/resultados_asr_lat.jtl

    # 4. [ASR-1] Escalabilidad 12000 usuarios:
    jmeter -n -t /opt/asr_escalabilidad.jmx -l /opt/resultados_asr1.jtl

    # Ver promedio de latencia:
    awk -F, 'NR>1{sum+=$2;n++} END{printf "Promedio: %.1f ms\n", sum/n}' \
        /opt/resultados_asr_lat.jtl
  CMDS
}
