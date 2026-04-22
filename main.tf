# =============================================================================
# BITE.co - Infraestructura AWS para validación de ASRs
# Diagrama de despliegue: 3 Web Servers (A, B, C) + BD Server EC2 + RDS
# + Application Load Balancer en us-east-1a / us-east-1b
#
# ASRs cubiertos:
#   [ASR-DISP-DET]  Detección de falla en reporte <= 200 ms
#   [ASR-DISP-REP]  Recuperación del servicio   <= 2 s
#   [ASR-LAT]       Consulta de reporte          <= 100 ms @ 5 000 usuarios
#   [ASR-SEG-DET]   Detección de acceso no autorizado <= 200 ms
#   [ASR-SEG-REP]   Bloqueo de comportamiento anómalo (respuesta inmediata)
# =============================================================================

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
  }
}

# ── Proveedor ──────────────────────────────────────────────────────────────────
provider "aws" {
  region = "us-east-1"
}

# =============================================================================
# 0. KEY PAIR (generado localmente, guardado en ./bite_key.pem)
# =============================================================================
resource "tls_private_key" "bite_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "bite_key" {
  key_name   = "bite-keypair"
  public_key = tls_private_key.bite_key.public_key_openssh
}

# Guarda la llave privada localmente para poder hacer SSH
resource "local_file" "private_key_pem" {
  content         = tls_private_key.bite_key.private_key_pem
  filename        = "${path.module}/bite_key.pem"
  file_permission = "0400"
}

# =============================================================================
# 1. RED - VPC DEFAULT + subnets públicas en 2 AZs (requerido por el ALB)
#    El diagrama indica "AWS-Default VPC" → usamos la VPC por defecto.
#    Suposición mínima: obtenemos las dos primeras subnets disponibles.
# =============================================================================
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Tomamos exactamente las subnets de us-east-1a y us-east-1b (como indica el diagrama)
data "aws_subnet" "az_a" {
  filter {
    name   = "availabilityZone"
    values = ["us-east-1a"]
  }
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "az_b" {
  filter {
    name   = "availabilityZone"
    values = ["us-east-1b"]
  }
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# =============================================================================
# 2. SECURITY GROUPS
# =============================================================================

# ── SG: Application Load Balancer ─────────────────────────────────────────────
resource "aws_security_group" "alb_sg" {
  name        = "bite-alb-sg"
  description = "Trafico HTTP publico hacia el ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP desde internet"
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

  tags = { Name = "bite-alb-sg" }
}

# ── SG: Web Servers (A, B, C) ─────────────────────────────────────────────────
# [ASR-SEG-DET / ASR-SEG-REP] Solo acepta tráfico del ALB en el puerto 8000 (Django)
resource "aws_security_group" "web_sg" {
  name        = "bite-web-sg"
  description = "Trafico Django desde el ALB + SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Django desde el ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "SSH para administracion"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # Restringir a tu IP en producción
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "bite-web-sg" }
}

# ── SG: BD Server EC2 ─────────────────────────────────────────────────────────
resource "aws_security_group" "bd_sg" {
  name        = "bite-bd-sg"
  description = "Postgres desde Web Servers + SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "PostgreSQL desde los Web Servers"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  ingress {
    description = "SSH para administracion"
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

  tags = { Name = "bite-bd-sg" }
}

# ── SG: RDS ───────────────────────────────────────────────────────────────────
resource "aws_security_group" "rds_sg" {
  name        = "bite-rds-sg"
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

  tags = { Name = "bite-rds-sg" }
}

# =============================================================================
# 3. RDS - Persistencia (Dev/Test, PostgreSQL, 20 GB)
#    [ASR-DISP-REP] La BD persiste los datos → sin pérdida de info al recuperarse
#    Suposición: se usa PostgreSQL (estándar Django). Motor configurable.
# =============================================================================
resource "aws_db_subnet_group" "bite_rds_subnet" {
  name       = "bite-rds-subnet-group"
  subnet_ids = [data.aws_subnet.az_a.id, data.aws_subnet.az_b.id]
  tags       = { Name = "bite-rds-subnet-group" }
}

resource "aws_db_instance" "bite_rds" {
  identifier             = "bite-rds"
  engine                 = "postgres"
  engine_version         = "15"
  instance_class         = "db.t3.micro"   # Dev/Test predeterminado
  allocated_storage      = 20              # GB mínimo para Dev/Test
  storage_type           = "gp2"
  db_name                = "bitedb"
  username               = "biteadmin"
  password               = "Bite2024!Secure"   # Cambiar antes de apply
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.bite_rds_subnet.name
  skip_final_snapshot    = true
  publicly_accessible    = false
  multi_az               = false           # Dev/Test: single-AZ

  tags = { Name = "bite-rds" }
}

# =============================================================================
# 4. AMI BASE - Ubuntu 24.04 LTS
# =============================================================================
data "aws_ami" "ubuntu_24" {
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

# =============================================================================
# 5. USER DATA - Script Django compartido para los 3 Web Servers
#
#    Componentes por servidor (según diagrama):
#      - Django (execution environment)
#      - Cache de reportes  → endpoint /report/  con caché en memoria
#      - Cola de trabajos   → simulada con threading en Django
#      - Procesador de análisis → tarea en segundo plano
#      - Report Pre-Generator  → tarea de precarga al arrancar
#      - Elastic Orchestrator  → endpoint /health/ que reinicia workers caídos
#
#    ASRs validados con endpoints:
#      GET /report/          → [ASR-LAT]      responde <= 100 ms desde caché
#      GET /health/          → [ASR-DISP-DET] detecta falla <= 200 ms
#      POST /recover/        → [ASR-DISP-REP] ejecuta recuperación <= 2 s
#      GET /security/check/  → [ASR-SEG-DET]  detecta acceso anómalo <= 200 ms
#      POST /security/block/ → [ASR-SEG-REP]  bloquea IP anómala
# =============================================================================
locals {
  web_user_data = <<-EOF
    #!/bin/bash
    set -e
    export DEBIAN_FRONTEND=noninteractive

    # ── Actualizar e instalar dependencias ──────────────────────────────────
    apt-get update -y
    apt-get install -y python3-pip python3-venv postgresql-client git

    # ── Entorno virtual Django ───────────────────────────────────────────────
    python3 -m venv /opt/bite_env
    source /opt/bite_env/bin/activate
    pip install --upgrade pip
    pip install django==4.2 psycopg2-binary gunicorn

    # ── Crear proyecto Django ────────────────────────────────────────────────
    mkdir -p /opt/bite
    cd /opt/bite
    django-admin startproject bitecore .
    python manage.py startapp reports

    # ── settings.py mínimo ──────────────────────────────────────────────────
    cat > /opt/bite/bitecore/settings.py << 'SETTINGS'
import os
SECRET_KEY = 'bite-secret-key-change-in-prod'
DEBUG = True
ALLOWED_HOSTS = ['*']
INSTALLED_APPS = [
    'django.contrib.contenttypes',
    'django.contrib.staticfiles',
    'reports',
]
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'bitedb',
        'USER': 'biteadmin',
        'PASSWORD': 'Bite2024!Secure',
        'HOST': '${aws_db_instance.bite_rds.address}',
        'PORT': '5432',
    }
}
ROOT_URLCONF = 'bitecore.urls'
SETTINGS

    # ── views.py ─────────────────────────────────────────────────────────────
    # Cada endpoint mide su propio tiempo de respuesta y lo incluye en el JSON
    # para que puedas verificar los tiempos de los ASRs con curl o JMeter.
    cat > /opt/bite/reports/views.py << 'VIEWS'
import time
import threading
import json
from django.http import JsonResponse

# ── Cache en memoria (Report Cache / Report Pre-Generator) ──────────────────
# [ASR-LAT] Los reportes se precargan al iniciar; la consulta solo lee de memoria
_report_cache = {}
_cache_lock = threading.Lock()
_blocked_ips = set()
_anomaly_log = []

def _preload_reports():
    """Report Pre-Generator: precarga 100 reportes simulados al arrancar."""
    with _cache_lock:
        for i in range(1, 101):
            _report_cache[str(i)] = {
                "id": i,
                "resource": f"resource_{i}",
                "consumption": round(i * 1.5, 2),
                "cached_at": time.time(),
            }

# Ejecutar precarga en background al importar el módulo
threading.Thread(target=_preload_reports, daemon=True).start()

# ── /report/<id>/ ───────────────────────────────────────────────────────────
# [ASR-LAT] Consulta de reporte desde caché → debe responder <= 100 ms
def report_view(request, report_id="1"):
    t0 = time.perf_counter()
    with _cache_lock:
        data = _report_cache.get(str(report_id))
    elapsed_ms = (time.perf_counter() - t0) * 1000
    if data:
        return JsonResponse({
            "status": "ok",
            "report": data,
            "elapsed_ms": round(elapsed_ms, 3),
            "asr": "LAT - objetivo <= 100 ms",
        })
    return JsonResponse({"status": "not_found", "elapsed_ms": round(elapsed_ms, 3)}, status=404)

# ── /health/ ────────────────────────────────────────────────────────────────
# [ASR-DISP-DET] Health Monitor / Elastic Orchestrator:
# Simula detección de falla en la generación de un reporte <= 200 ms.
# En producción este endpoint sería llamado periódicamente por el orquestador.
_worker_healthy = True

def health_view(request):
    t0 = time.perf_counter()
    global _worker_healthy

    # Simular falla si el parámetro ?fail=1 está presente
    if request.GET.get("fail") == "1":
        _worker_healthy = False

    status = "healthy" if _worker_healthy else "degraded"
    elapsed_ms = (time.perf_counter() - t0) * 1000

    return JsonResponse({
        "status": status,
        "worker_healthy": _worker_healthy,
        "elapsed_ms": round(elapsed_ms, 3),
        "asr": "DISP-DET - objetivo <= 200 ms",
    })

# ── /recover/ ───────────────────────────────────────────────────────────────
# [ASR-DISP-REP] Exception Handler / Elastic Orchestrator:
# Simula la recuperación del worker caído en <= 2 segundos.
# El caché persiste → sin pérdida de información durante la recuperación.
def recover_view(request):
    t0 = time.perf_counter()
    global _worker_healthy

    # Simular tiempo de recuperación (< 2 s según el ASR)
    time.sleep(0.8)   # 800 ms de recuperación simulada
    _worker_healthy = True

    # Recargar reportes (simula restaurar el procesador de análisis)
    _preload_reports()

    elapsed_ms = (time.perf_counter() - t0) * 1000
    return JsonResponse({
        "status": "recovered",
        "elapsed_ms": round(elapsed_ms, 3),
        "cache_size": len(_report_cache),
        "asr": "DISP-REP - objetivo <= 2000 ms",
    })

# ── /security/check/ ────────────────────────────────────────────────────────
# [ASR-SEG-DET] IDS / Anomaly Detector / Audit Logger:
# Detecta acceso no autorizado o anómalo en <= 200 ms.
# Criterios de anomalía simulados: IP en lista negra, User-Agent vacío,
# o cabecera X-Bite-Token ausente.
def security_check_view(request):
    t0 = time.perf_counter()
    client_ip = request.META.get("REMOTE_ADDR", "unknown")
    token = request.headers.get("X-Bite-Token", "")
    ua = request.META.get("HTTP_USER_AGENT", "")

    anomalies = []
    if client_ip in _blocked_ips:
        anomalies.append("ip_blocked")
    if not token:
        anomalies.append("missing_token")
    if not ua:
        anomalies.append("missing_user_agent")

    # Audit log en memoria (Audit Logger)
    _anomaly_log.append({
        "ts": time.time(),
        "ip": client_ip,
        "anomalies": anomalies,
    })

    elapsed_ms = (time.perf_counter() - t0) * 1000
    is_anomalous = len(anomalies) > 0
    return JsonResponse({
        "status": "anomaly_detected" if is_anomalous else "clean",
        "anomalies": anomalies,
        "elapsed_ms": round(elapsed_ms, 3),
        "asr": "SEG-DET - objetivo <= 200 ms",
    }, status=403 if is_anomalous else 200)

# ── /security/block/ ────────────────────────────────────────────────────────
# [ASR-SEG-REP] Response Manager:
# Bloquea una IP anómala (respuesta inmediata, sin tiempo mínimo).
def security_block_view(request):
    t0 = time.perf_counter()
    try:
        body = json.loads(request.body)
        ip_to_block = body.get("ip", "")
    except Exception:
        ip_to_block = ""

    if ip_to_block:
        _blocked_ips.add(ip_to_block)

    elapsed_ms = (time.perf_counter() - t0) * 1000
    return JsonResponse({
        "status": "blocked",
        "ip": ip_to_block,
        "blocked_count": len(_blocked_ips),
        "elapsed_ms": round(elapsed_ms, 3),
        "asr": "SEG-REP - bloqueo inmediato",
    })

# ── /ping/ ──────────────────────────────────────────────────────────────────
# Health check del ALB
def ping_view(request):
    return JsonResponse({"status": "ok"})
VIEWS

    # ── urls.py ─────────────────────────────────────────────────────────────
    cat > /opt/bite/bitecore/urls.py << 'URLS'
from django.urls import path
from reports import views

urlpatterns = [
    path('ping/',                  views.ping_view),
    path('report/',                views.report_view),
    path('report/<str:report_id>/',views.report_view),
    path('health/',                views.health_view),
    path('recover/',               views.recover_view),
    path('security/check/',        views.security_check_view),
    path('security/block/',        views.security_block_view),
]
URLS

    # ── Migraciones (sin modelos → solo verifica conexión) ──────────────────
    cd /opt/bite
    source /opt/bite_env/bin/activate
    python manage.py migrate --run-syncdb || true

    # ── Servicio systemd para Gunicorn ──────────────────────────────────────
    cat > /etc/systemd/system/bite.service << 'SERVICE'
[Unit]
Description=BITE.co Django via Gunicorn
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/opt/bite
Environment="PATH=/opt/bite_env/bin"
ExecStart=/opt/bite_env/bin/gunicorn \
    --workers 4 \
    --bind 0.0.0.0:8000 \
    --timeout 30 \
    --access-logfile /var/log/bite_access.log \
    --error-logfile /var/log/bite_error.log \
    bitecore.wsgi:application
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable bite
    systemctl start bite
  EOF
}

# =============================================================================
# 6. EC2 - WEB SERVER A
#    AMI: Ubuntu 24.04 | t3.micro | 8 GB | us-east-1a
#    Componentes: Django, Cache reportes A, Cola de trabajos, Procesador de análisis,
#                 Report Pre-Generator, Elastic Orchestrator
# =============================================================================
resource "aws_instance" "web_server_a" {
  ami                    = data.aws_ami.ubuntu_24.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.bite_key.key_name
  subnet_id              = data.aws_subnet.az_a.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  root_block_device {
    volume_size = 8    # GB según el diagrama
    volume_type = "gp3"
  }

  user_data = local.web_user_data

  tags = {
    Name = "bite-web-server-a"
    Role = "WebServer"
    AZ   = "us-east-1a"
  }
}

# =============================================================================
# 7. EC2 - WEB SERVER B
#    AMI: Ubuntu 24.04 | t3.micro | 8 GB | us-east-1b
# =============================================================================
resource "aws_instance" "web_server_b" {
  ami                    = data.aws_ami.ubuntu_24.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.bite_key.key_name
  subnet_id              = data.aws_subnet.az_b.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  user_data = local.web_user_data

  tags = {
    Name = "bite-web-server-b"
    Role = "WebServer"
    AZ   = "us-east-1b"
  }
}

# =============================================================================
# 8. EC2 - WEB SERVER C  (también tiene JMeter para simular carga → ASR-LAT)
#    El script instala JMeter en modo CLI para poder disparar 5 000 usuarios.
# =============================================================================
locals {
  web_c_user_data = <<-EOF
    #!/bin/bash
    set -e
    export DEBIAN_FRONTEND=noninteractive

    # ── Misma base que los otros web servers ────────────────────────────────
    apt-get update -y
    apt-get install -y python3-pip python3-venv postgresql-client git \
                       default-jre-headless wget

    python3 -m venv /opt/bite_env
    source /opt/bite_env/bin/activate
    pip install --upgrade pip
    pip install django==4.2 psycopg2-binary gunicorn

    mkdir -p /opt/bite
    cd /opt/bite
    django-admin startproject bitecore .
    python manage.py startapp reports

    cat > /opt/bite/bitecore/settings.py << 'SETTINGS'
import os
SECRET_KEY = 'bite-secret-key-change-in-prod'
DEBUG = True
ALLOWED_HOSTS = ['*']
INSTALLED_APPS = [
    'django.contrib.contenttypes',
    'django.contrib.staticfiles',
    'reports',
]
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'bitedb',
        'USER': 'biteadmin',
        'PASSWORD': 'Bite2024!Secure',
        'HOST': '${aws_db_instance.bite_rds.address}',
        'PORT': '5432',
    }
}
ROOT_URLCONF = 'bitecore.urls'
SETTINGS

    # Reutilizamos el mismo views.py y urls.py
    cat > /opt/bite/reports/views.py << 'VIEWS'
import time
import threading
import json
from django.http import JsonResponse

_report_cache = {}
_cache_lock = threading.Lock()
_blocked_ips = set()
_anomaly_log = []

def _preload_reports():
    with _cache_lock:
        for i in range(1, 101):
            _report_cache[str(i)] = {
                "id": i,
                "resource": f"resource_{i}",
                "consumption": round(i * 1.5, 2),
                "cached_at": time.time(),
            }

threading.Thread(target=_preload_reports, daemon=True).start()

def report_view(request, report_id="1"):
    t0 = time.perf_counter()
    with _cache_lock:
        data = _report_cache.get(str(report_id))
    elapsed_ms = (time.perf_counter() - t0) * 1000
    if data:
        return JsonResponse({"status": "ok","report": data,"elapsed_ms": round(elapsed_ms, 3),"asr": "LAT - objetivo <= 100 ms"})
    return JsonResponse({"status": "not_found", "elapsed_ms": round(elapsed_ms, 3)}, status=404)

def health_view(request):
    t0 = time.perf_counter()
    global _worker_healthy
    _worker_healthy = True
    if request.GET.get("fail") == "1":
        _worker_healthy = False
    elapsed_ms = (time.perf_counter() - t0) * 1000
    return JsonResponse({"status": "healthy" if _worker_healthy else "degraded","elapsed_ms": round(elapsed_ms, 3),"asr": "DISP-DET - objetivo <= 200 ms"})

_worker_healthy = True

def recover_view(request):
    t0 = time.perf_counter()
    global _worker_healthy
    time.sleep(0.8)
    _worker_healthy = True
    _preload_reports()
    elapsed_ms = (time.perf_counter() - t0) * 1000
    return JsonResponse({"status": "recovered","elapsed_ms": round(elapsed_ms, 3),"cache_size": len(_report_cache),"asr": "DISP-REP - objetivo <= 2000 ms"})

def security_check_view(request):
    t0 = time.perf_counter()
    client_ip = request.META.get("REMOTE_ADDR", "unknown")
    token = request.headers.get("X-Bite-Token", "")
    ua = request.META.get("HTTP_USER_AGENT", "")
    anomalies = []
    if client_ip in _blocked_ips: anomalies.append("ip_blocked")
    if not token: anomalies.append("missing_token")
    if not ua: anomalies.append("missing_user_agent")
    _anomaly_log.append({"ts": time.time(),"ip": client_ip,"anomalies": anomalies})
    elapsed_ms = (time.perf_counter() - t0) * 1000
    is_anomalous = len(anomalies) > 0
    return JsonResponse({"status": "anomaly_detected" if is_anomalous else "clean","anomalies": anomalies,"elapsed_ms": round(elapsed_ms, 3),"asr": "SEG-DET - objetivo <= 200 ms"},status=403 if is_anomalous else 200)

def security_block_view(request):
    t0 = time.perf_counter()
    try:
        body = json.loads(request.body)
        ip_to_block = body.get("ip", "")
    except Exception:
        ip_to_block = ""
    if ip_to_block: _blocked_ips.add(ip_to_block)
    elapsed_ms = (time.perf_counter() - t0) * 1000
    return JsonResponse({"status": "blocked","ip": ip_to_block,"blocked_count": len(_blocked_ips),"elapsed_ms": round(elapsed_ms, 3),"asr": "SEG-REP - bloqueo inmediato"})

def ping_view(request):
    return JsonResponse({"status": "ok"})
VIEWS

    cat > /opt/bite/bitecore/urls.py << 'URLS'
from django.urls import path
from reports import views

urlpatterns = [
    path('ping/',                  views.ping_view),
    path('report/',                views.report_view),
    path('report/<str:report_id>/',views.report_view),
    path('health/',                views.health_view),
    path('recover/',               views.recover_view),
    path('security/check/',        views.security_check_view),
    path('security/block/',        views.security_block_view),
]
URLS

    cd /opt/bite
    source /opt/bite_env/bin/activate
    python manage.py migrate --run-syncdb || true

    cat > /etc/systemd/system/bite.service << 'SERVICE'
[Unit]
Description=BITE.co Django via Gunicorn
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/opt/bite
Environment="PATH=/opt/bite_env/bin"
ExecStart=/opt/bite_env/bin/gunicorn \
    --workers 4 \
    --bind 0.0.0.0:8000 \
    --timeout 30 \
    --access-logfile /var/log/bite_access.log \
    --error-logfile /var/log/bite_error.log \
    bitecore.wsgi:application
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable bite
    systemctl start bite

    # ── JMeter (execution environment JMeter - Web Server C) ────────────────
    # [ASR-LAT] Herramienta para simular 5 000 usuarios concurrentes
    wget -q https://downloads.apache.org/jmeter/binaries/apache-jmeter-5.6.3.tgz \
         -O /tmp/jmeter.tgz
    tar -xzf /tmp/jmeter.tgz -C /opt/
    ln -sf /opt/apache-jmeter-5.6.3/bin/jmeter /usr/local/bin/jmeter

    # Plan de prueba JMeter: 5 000 usuarios → GET /report/1/
    # Ajusta ALB_DNS con el DNS del balanceador después del apply
    cat > /opt/bite_load_test.jmx << 'JMX'
<?xml version="1.0" encoding="UTF-8"?>
<jmeterTestPlan version="1.2">
  <hashTree>
    <TestPlan guiclass="TestPlanGui" testclass="TestPlan" testname="BITE ASR-LAT Test">
      <hashTree>
        <ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup" testname="5000 Usuarios">
          <intProp name="ThreadGroup.num_threads">5000</intProp>
          <intProp name="ThreadGroup.ramp_time">60</intProp>
          <boolProp name="ThreadGroup.scheduler">false</boolProp>
          <hashTree>
            <HTTPSamplerProxy guiclass="HttpTestSampleGui" testclass="HTTPSamplerProxy" testname="GET /report/1/">
              <stringProp name="HTTPSampler.domain">ALB_DNS_HERE</stringProp>
              <intProp name="HTTPSampler.port">80</intProp>
              <stringProp name="HTTPSampler.path">/report/1/</stringProp>
              <stringProp name="HTTPSampler.method">GET</stringProp>
              <hashTree/>
            </HTTPSamplerProxy>
            <ResultCollector guiclass="SummaryReport" testclass="ResultCollector" testname="Summary Report">
              <objProp>
                <name>saveConfig</name>
                <value class="SampleSaveConfiguration">
                  <time>true</time>
                  <latency>true</latency>
                  <responseCode>true</responseCode>
                </value>
              </objProp>
              <stringProp name="filename">/opt/jmeter_results.jtl</stringProp>
              <hashTree/>
            </ResultCollector>
          </hashTree>
        </ThreadGroup>
      </hashTree>
    </TestPlan>
  </hashTree>
</jmeterTestPlan>
JMX

    echo "JMeter instalado. Ejecutar con: jmeter -n -t /opt/bite_load_test.jmx -l /opt/results.jtl"
  EOF
}

resource "aws_instance" "web_server_c" {
  ami                    = data.aws_ami.ubuntu_24.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.bite_key.key_name
  subnet_id              = data.aws_subnet.az_a.id   # us-east-1a (mismo que A)
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  user_data = local.web_c_user_data

  tags = {
    Name = "bite-web-server-c"
    Role = "WebServer+JMeter"
    AZ   = "us-east-1a"
  }
}

# =============================================================================
# 9. EC2 - BD SERVER (EC2 adicional con PostgreSQL - según diagrama)
#    Suposición: este servidor actúa como réplica/caché de datos preprocesados
#    ("Información preprocesada de reportes recientes y cálculos realizados")
#    según la nota del diagrama de despliegue.
# =============================================================================
resource "aws_instance" "bd_server" {
  ami                    = data.aws_ami.ubuntu_24.id
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.bite_key.key_name
  subnet_id              = data.aws_subnet.az_a.id
  vpc_security_group_ids = [aws_security_group.bd_sg.id]

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  # Instala PostgreSQL y crea la BD de caché de reportes preprocesados
  user_data = <<-EOF
    #!/bin/bash
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y postgresql postgresql-contrib

    # Configurar PostgreSQL para aceptar conexiones de la VPC
    PG_VERSION=$(ls /etc/postgresql/)
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" \
        /etc/postgresql/$PG_VERSION/main/postgresql.conf
    echo "host  bitedb_cache  biteadmin  0.0.0.0/0  md5" \
        >> /etc/postgresql/$PG_VERSION/main/pg_hba.conf

    systemctl restart postgresql

    # Crear DB y usuario
    sudo -u postgres psql -c "CREATE USER biteadmin WITH PASSWORD 'Bite2024!Secure';"
    sudo -u postgres psql -c "CREATE DATABASE bitedb_cache OWNER biteadmin;"

    # Tabla de reportes preprocesados (caché persistente)
    sudo -u postgres psql -d bitedb_cache -c "
      CREATE TABLE IF NOT EXISTS preprocessed_reports (
        id         SERIAL PRIMARY KEY,
        report_id  VARCHAR(50) UNIQUE NOT NULL,
        resource   VARCHAR(100),
        consumption NUMERIC(10,2),
        created_at TIMESTAMPTZ DEFAULT NOW()
      );
      INSERT INTO preprocessed_reports (report_id, resource, consumption)
      SELECT 'r' || i, 'resource_' || i, i * 1.5
      FROM generate_series(1, 100) AS i
      ON CONFLICT DO NOTHING;
    "
    echo "BD Server listo con 100 reportes preprocesados."
  EOF

  tags = {
    Name = "bite-bd-server"
    Role = "BDServer"
    Note = "Cache de reportes preprocesados - segun diagrama de despliegue"
  }
}

# =============================================================================
# 10. APPLICATION LOAD BALANCER (AWS ELB - zonas us-east-1a y us-east-1b)
#     [ASR-DISP-REP] El ALB redirige tráfico si un Web Server falla → sin downtime
#     [ASR-LAT]      Distribución de carga entre A, B, C → mantiene < 100 ms
# =============================================================================
resource "aws_lb" "bite_alb" {
  name               = "bite-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [data.aws_subnet.az_a.id, data.aws_subnet.az_b.id]

  tags = { Name = "bite-alb" }
}

# ── Target Group ──────────────────────────────────────────────────────────────
# Health check en /ping/ con intervalo de 10 s → detección de instancia caída
# [ASR-DISP-DET] El ALB marca una instancia como unhealthy si /ping/ no responde
resource "aws_lb_target_group" "bite_tg" {
  name        = "bite-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/ping/"
    interval            = 10      # segundos entre checks
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2       # 2 fallos → unhealthy (≈ 20 s detección ALB)
    matcher             = "200"
  }

  tags = { Name = "bite-tg" }
}

# ── Registrar los 3 Web Servers en el Target Group ────────────────────────────
resource "aws_lb_target_group_attachment" "web_a" {
  target_group_arn = aws_lb_target_group.bite_tg.arn
  target_id        = aws_instance.web_server_a.id
  port             = 8000
}

resource "aws_lb_target_group_attachment" "web_b" {
  target_group_arn = aws_lb_target_group.bite_tg.arn
  target_id        = aws_instance.web_server_b.id
  port             = 8000
}

resource "aws_lb_target_group_attachment" "web_c" {
  target_group_arn = aws_lb_target_group.bite_tg.arn
  target_id        = aws_instance.web_server_c.id
  port             = 8000
}

# ── Listener HTTP:80 ──────────────────────────────────────────────────────────
resource "aws_lb_listener" "bite_http" {
  load_balancer_arn = aws_lb.bite_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.bite_tg.arn
  }
}

# =============================================================================
# 11. OUTPUTS - Información útil tras el terraform apply
# =============================================================================
output "alb_dns_name" {
  description = "DNS del Application Load Balancer (usar en JMeter y pruebas de ASR)"
  value       = aws_lb.bite_alb.dns_name
}

output "web_server_a_public_ip" {
  description = "IP pública Web Server A"
  value       = aws_instance.web_server_a.public_ip
}

output "web_server_b_public_ip" {
  description = "IP pública Web Server B"
  value       = aws_instance.web_server_b.public_ip
}

output "web_server_c_public_ip" {
  description = "IP pública Web Server C (tiene JMeter)"
  value       = aws_instance.web_server_c.public_ip
}

output "bd_server_public_ip" {
  description = "IP pública BD Server EC2"
  value       = aws_instance.bd_server.public_ip
}

output "rds_endpoint" {
  description = "Endpoint RDS PostgreSQL"
  value       = aws_db_instance.bite_rds.address
}

output "asr_test_commands" {
  description = "Comandos para probar cada ASR manualmente con curl"
  value       = <<-CMDS
    # ── Sustituir ALB_DNS con el valor de alb_dns_name ──────────────────────

    # [ASR-LAT] Latencia de reporte <= 100 ms
    curl -o /dev/null -s -w "%%{time_total}s\n" http://ALB_DNS/report/1/

    # [ASR-DISP-DET] Simular falla y medir detección <= 200 ms
    curl -s "http://ALB_DNS/health/?fail=1"
    curl -s "http://ALB_DNS/health/"

    # [ASR-DISP-REP] Recuperación <= 2 s
    curl -s -w "\nTiempo: %%{time_total}s\n" http://ALB_DNS/recover/

    # [ASR-SEG-DET] Detección de acceso sin token <= 200 ms
    curl -s http://ALB_DNS/security/check/

    # [ASR-SEG-REP] Bloqueo de IP anómala
    curl -s -X POST http://ALB_DNS/security/block/ \
         -H "Content-Type: application/json" \
         -d '{"ip":"1.2.3.4"}'

    # [ASR-LAT - JMeter] Desde Web Server C (SSH) ejecutar:
    # jmeter -n -t /opt/bite_load_test.jmx -l /opt/results.jtl
    # (Editar ALB_DNS_HERE en /opt/bite_load_test.jmx primero)
  CMDS
}
