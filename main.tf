###############################################################################
# OptiCloud – main.tf (v5 – CORREGIDO)
#
# CORRECCIONES RESPECTO A LA VERSION ANTERIOR:
#
#  1. CRITICO: file() → templatefile() en el Launch Template.
#     file() carga el script .sh como texto plano — las variables
#     ${var.db_username} etc. NO se sustituyen. templatefile() las reemplaza
#     ANTES de codificar user_data, por lo que Django recibe las credenciales
#     reales de RDS. Esto es la causa raiz de Target.FailedHealthChecks.
#
#  2. CRITICO: "availabilityZone" → "availability-zone" en los filtros
#     de aws_subnet. El nombre correcto del filtro AWS es con guion y
#     minusculas. Con el nombre incorrecto los data sources fallaban
#     silenciosamente y usaban subnets aleatorias.
#
#  3. instance_type t3.small → t3.micro (ajuste de presupuesto).
#
#  4. health_check_grace_period aumentado a 300 s para dar tiempo a que
#     user_data termine (apt-get + pip pueden tardar >2 min en t3.micro).
#
#  5. health_check del ALB: interval aumentado a 30 s y unhealthy_threshold
#     a 5 para no marcar unhealthy durante el arranque inicial.
#
# ASRs validados por este despliegue:
#   ASR-DISP-DET  deteccion falla <= 200 ms  → GET /worker/status/?fail=1
#   ASR-DISP-REP  recuperacion   <= 2000 ms  → POST /worker/recover/
#   ASR-SEG-DET   deteccion anomalia <= 200 ms → GET /security/check/
#   ASR-SEG-REP   bloqueo IP inmediato        → POST /security/block/
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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
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
# KEY PAIR
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
# VPC – Default VPC
###############################################################################

data "aws_vpc" "default" {
  default = true
}

# CORRECCION: "availabilityZone" → "availability-zone" (con guion, minusculas)
# El filtro incorrecto causaba que los data sources devolvieran subnets
# de zonas incorrectas o fallaran silenciosamente.
data "aws_subnet" "az_a" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-2a"]
  }
}

data "aws_subnet" "az_b" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-2b"]
  }
}

###############################################################################
# SECURITY GROUPS
###############################################################################

# ALB: acepta trafico HTTP:80 desde Internet
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

# Web Servers: Django en :8000 (solo desde ALB) + SSH
resource "aws_security_group" "web_sg" {
  name        = "opticloud-web-sg"
  description = "ALB to Django port 8000 and SSH for ASR tests"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Django desde el ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "SSH para depuracion y experimentos ASR"
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

# BD Server: solo SSH (JMeter solo necesita salida al ALB)
resource "aws_security_group" "bd_server_sg" {
  name        = "opticloud-bd-server-sg"
  description = "BD Server (JMeter): SSH + egress libre"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH para lanzar pruebas JMeter"
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

  tags = { Name = "opticloud-bd-server-sg" }
}

# RDS: solo acepta conexiones desde los Web Servers
resource "aws_security_group" "rds_sg" {
  name        = "opticloud-rds-sg"
  description = "PostgreSQL solo desde Web Servers"
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
# RDS – Persistencia (tablas: pregenerated_reports, analysis_jobs, audit_log)
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
# BD SERVER – JMeter para pruebas de carga
###############################################################################

resource "aws_instance" "bd_server" {
  ami                    = var.ami_id
  instance_type          = "t3.micro"   # CORREGIDO: t3.small → t3.micro
  subnet_id              = data.aws_subnet.az_a.id
  vpc_security_group_ids = [aws_security_group.bd_server_sg.id]
  key_name               = aws_key_pair.opticloud_key.key_name

  root_block_device {
    volume_size = 8
    volume_type = "gp2"
  }

  # setup_bdserver.sh no usa variables Terraform → file() es correcto aqui
  user_data = base64encode(file("${path.module}/scripts/setup_bdserver.sh"))

  tags = { Name = "opticloud-bd-server" }
}

###############################################################################
# S3 + IAM – Almacena el script de setup del Web Server
#
# PROBLEMA: user_data tiene limite de 16384 bytes. El script setup_webserver.sh
# pesa ~28 KB con todo el codigo Django embebido.
#
# SOLUCION: Terraform sube el script a S3 (con variables RDS ya sustituidas).
# user_data es un mini-script de ~400 bytes que lo descarga y ejecuta.
###############################################################################

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "scripts" {
  bucket        = "opticloud-scripts-${random_id.bucket_suffix.hex}"
  force_destroy = true
  tags          = { Name = "opticloud-scripts" }
}

resource "aws_s3_bucket_public_access_block" "scripts" {
  bucket                  = aws_s3_bucket.scripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Subir el script con las credenciales RDS ya sustituidas
resource "aws_s3_object" "setup_webserver" {
  bucket  = aws_s3_bucket.scripts.id
  key     = "setup_webserver.sh"
  content = templatefile("${path.module}/scripts/setup_webserver.sh", {
    db_host = aws_db_instance.opticloud_db.address
    db_user = var.db_username
    db_pass = var.db_password
  })
  content_type = "text/x-shellscript"
}

# IAM Role para que las instancias EC2 puedan leer desde S3
resource "aws_iam_role" "web_server_role" {
  name = "opticloud-web-server-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "s3_read_scripts" {
  name = "opticloud-s3-read-scripts"
  role = aws_iam_role.web_server_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.scripts.arn}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "web_server_profile" {
  name = "opticloud-web-server-profile"
  role = aws_iam_role.web_server_role.name
}

###############################################################################
# LAUNCH TEMPLATE – Web Servers A/B/C
#
# user_data es un mini-script (~400 bytes) que descarga el script real
# desde S3 y lo ejecuta. Esto resuelve el limite de 16384 bytes de user_data.
###############################################################################

resource "aws_launch_template" "web_server" {
  name_prefix   = "opticloud-web-"
  image_id      = var.ami_id
  instance_type = "t3.micro"

  key_name = aws_key_pair.opticloud_key.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.web_server_profile.name
  }

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

  user_data = base64encode(
    "#!/bin/bash\nexec > /var/log/opticloud-bootstrap.log 2>&1\napt-get update -y\napt-get install -y curl unzip\ncurl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip\nunzip -q /tmp/awscliv2.zip -d /tmp\n/tmp/aws/install\naws s3 cp s3://${aws_s3_bucket.scripts.id}/setup_webserver.sh /tmp/setup_webserver.sh --region us-east-2\nchmod +x /tmp/setup_webserver.sh\nbash /tmp/setup_webserver.sh\n"
  )

  tags = { Name = "opticloud-web-server" }

  depends_on = [
    aws_db_instance.opticloud_db,
    aws_s3_object.setup_webserver,
    aws_iam_instance_profile.web_server_profile,
  ]
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
    path     = "/health/"
    port     = "8000"
    protocol = "HTTP"
    # CORRECCION: interval y threshold mas altos para tolerar el arranque lento
    # de user_data en t3.micro (apt-get + pip pueden tardar 3-4 minutos).
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
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
  min_size            = 3
  max_size            = 6
  desired_capacity    = 3
  vpc_zone_identifier = [data.aws_subnet.az_a.id, data.aws_subnet.az_b.id]

  launch_template {
    id      = aws_launch_template.web_server.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.web_tg.arn]
  health_check_type = "ELB"

  # CORRECCION: 300 s de gracia para que user_data termine antes de que el
  # ALB empiece a evaluar la salud de las instancias.
  health_check_grace_period = 300

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
  alarm_description   = "Escala OUT cuando CPU > 60%"
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
  alarm_description   = "Escala IN cuando CPU < 30%"
  alarm_actions       = [aws_autoscaling_policy.scale_in.arn]
  dimensions          = { AutoScalingGroupName = aws_autoscaling_group.web_asg.name }
}

###############################################################################
# OUTPUTS
###############################################################################

output "alb_dns_name" {
  description = "DNS del ALB – punto de entrada para todos los experimentos"
  value       = aws_lb.opticloud_alb.dns_name
}

output "rds_endpoint" {
  description = "Endpoint RDS PostgreSQL"
  value       = aws_db_instance.opticloud_db.address
}

output "bd_server_public_ip" {
  description = "IP publica BD Server (JMeter)"
  value       = aws_instance.bd_server.public_ip
}

output "ssh_instrucciones" {
  description = "Como conectarte a las instancias"
  value       = <<-NOTE
    # BD Server (JMeter):
    ssh -i opticloud_key.pem ubuntu@${aws_instance.bd_server.public_ip}

    # Listar IPs de los Web Servers del ASG:
    aws ec2 describe-instances \
      --filters "Name=tag:Name,Values=opticloud-web-server" \
                "Name=instance-state-name,Values=running" \
      --query "Reservations[*].Instances[*].PublicIpAddress" \
      --output text --region us-east-2

    # Conectar a un Web Server:
    ssh -i opticloud_key.pem ubuntu@<IP>

    # Ver log de arranque en el Web Server:
    tail -f /var/log/opticloud-setup.log

    # Ver errores de gunicorn:
    tail -f /var/log/gunicorn-error.log
  NOTE
}

output "experimentos_disponibilidad" {
  description = "Comandos curl para los ASRs de Disponibilidad (copiar y pegar)"
  value       = <<-CMDS
    ALB="${aws_lb.opticloud_alb.dns_name}"

    # 0. Verificar que el sistema esta listo (debe retornar {"status":"ok"}):
    curl -s "http://$ALB/health/"

    # ── ASR-DISP-DET ── deteccion de falla <= 200 ms ──────────────────────
    # 1a. Estado normal (worker_ok: true, detection_ms <= 200):
    curl -s "http://$ALB/worker/status/" | python3 -m json.tool

    # 1b. Simular falla (worker_ok pasa a false, detection_ms <= 200):
    curl -s "http://$ALB/worker/status/?fail=1" | python3 -m json.tool

    # ── ASR-DISP-REP ── recuperacion <= 2000 ms, sin perdida de datos ─────
    # 2. Ejecutar recuperacion (recovery_ms <= 2000, validacion_ok: true):
    curl -s -X POST "http://$ALB/worker/recover/" | python3 -m json.tool

    # 3. Confirmar que volvio a operacional:
    curl -s "http://$ALB/worker/status/" | python3 -m json.tool
  CMDS
}

output "experimentos_seguridad" {
  description = "Comandos curl para los ASRs de Seguridad (copiar y pegar)"
  value       = <<-CMDS
    ALB="${aws_lb.opticloud_alb.dns_name}"

    # ── ASR-SEG-DET ── deteccion de anomalia <= 200 ms ────────────────────
    # 1a. Acceso anomalo sin token (anomalo: true, detection_ms <= 200):
    curl -s "http://$ALB/security/check/" | python3 -m json.tool

    # 1b. Acceso legitimo (anomalo: false):
    curl -s -H "X-Opticloud-Token: test123" -A "Mozilla/5.0" \
         "http://$ALB/security/check/" | python3 -m json.tool

    # 1c. Flood de reportes (anomalia: comportamiento_flood_detectado):
    curl -s "http://$ALB/security/check/?flood=1" | python3 -m json.tool

    # ── ASR-SEG-REP ── bloqueo de IP inmediato ────────────────────────────
    # 2a. Bloquear una IP:
    curl -s -X POST "http://$ALB/security/block/" \
         -H "Content-Type: application/json" \
         -d '{"ip":"1.2.3.4","motivo":"generacion_masiva_reportes"}' \
         | python3 -m json.tool

    # 2b. Verificar que la IP quedo bloqueada (ip_en_lista_negra):
    curl -s -H "X-Forwarded-For: 1.2.3.4" \
         "http://$ALB/security/check/" | python3 -m json.tool

    # 3. Ver audit log completo:
    curl -s "http://$ALB/security/audit/" | python3 -m json.tool
  CMDS
}

output "experimentos_jmeter" {
  description = "Comandos JMeter desde el BD Server"
  value       = <<-CMDS
    # 1. SSH al BD Server:
    ssh -i opticloud_key.pem ubuntu@${aws_instance.bd_server.public_ip}

    # 2. Configurar el ALB en los planes JMeter:
    bash /opt/correr_pruebas.sh ${aws_lb.opticloud_alb.dns_name}

    # 3. [ASR-LAT] Latencia con 5000 usuarios sostenidos:
    jmeter -n -t /opt/asr_latencia.jmx -l /opt/resultados_asr_lat.jtl

    # 4. [ASR-1] Escalabilidad con 12000 usuarios en pico:
    jmeter -n -t /opt/asr_escalabilidad.jmx -l /opt/resultados_asr1.jtl

    # 5. Ver promedio de latencia del resultado:
    awk -F, 'NR>1{sum+=$2;n++} END{printf "Promedio: %.1f ms\n", sum/n}' \
        /opt/resultados_asr_lat.jtl
  CMDS
}
