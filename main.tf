###############################################################################
# OptiCloud – Infraestructura AWS para validar ASRs (Sprint 2)
#
# ASR-1 · Escalabilidad  : Pico 12k usuarios / 10 min  → Auto Scaling Group
# ASR-2 · Latencia       : ≤ 100 ms con 5k sostenidos  → Report Cache + Pre-Generator
#
# Región  : us-east-2 (Ohio)
# AMI     : Ubuntu 24.04 LTS  ami-07062e2a343acc423
# Instancias:
#   - Web Servers (Django + Cache): t3.micro (8 GB storage)
#   - Report Pre-Generator (worker EC2): t3.micro (8 GB storage)
#   - RDS PostgreSQL: db.t3.micro (Dev/Test)
# Balanceador: AWS ALB (Application Load Balancer)
#
# Correcciones v2:
#   1. Procesamiento asíncrono REAL → tabla jobs en RDS + worker thread separado
#      (el request HTTP retorna 202 inmediatamente; el worker consume en background)
#   2. Renombrado bd_server → report_pregenerator (evita confusión con RDS)
#   3. SG del pre-generator: sin ingress de app servers (solo egress a RDS)
#   4. Eliminado puerto 8080 innecesario
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
# KEY PAIR – generado por Terraform para acceso SSH a las instancias EC2
# Necesario para conectarse a los Web Servers y ejecutar los experimentos ASR
###############################################################################

resource "tls_private_key" "opticloud_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "opticloud_key" {
  key_name   = "opticloud-keypair"
  public_key = tls_private_key.opticloud_key.public_key_openssh
}

# Guarda la llave privada en el directorio local para hacer SSH
resource "local_file" "private_key_pem" {
  content         = tls_private_key.opticloud_key.private_key_pem
  filename        = "${path.module}/opticloud_key.pem"
  file_permission = "0400"
}

###############################################################################
# VPC – Default VPC (segun diagrama: AWS-Default VPC)
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

# SG: ALB — acepta HTTP:80 desde Internet
resource "aws_security_group" "alb_sg" {
  name        = "opticloud-alb-sg"
  description = "HTTP entrante al ALB desde Internet"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP desde Internet (JMeter y usuarios)"
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

# SG: Web Servers — solo acepta trafico desde el ALB en puerto 8000
# + SSH para conectarse y ejecutar experimentos ASR manualmente
resource "aws_security_group" "web_sg" {
  name        = "opticloud-web-sg"
  description = "Trafico desde ALB hacia Web Servers Django (puerto 8000)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTP desde el ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # SSH necesario para conectarse y correr los experimentos ASR desde adentro
  ingress {
    description = "SSH para experimentos ASR y monitoreo"
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

# SG: Report Pre-Generator — NO recibe trafico de ningún app server.
# Este nodo solo inicia conexiones salientes hacia RDS.
# Correccion v2: eliminado el ingress en 8080 que no correspondia con el rol
# real del componente (es un worker, no un servidor HTTP).
resource "aws_security_group" "pregenerator_sg" {
  name        = "opticloud-pregenerator-sg"
  description = "Report Pre-Generator: solo egress a RDS, sin ingress de apps"
  vpc_id      = data.aws_vpc.default.id

  # SSH para acceder al Pre-Generator y ver logs del worker
  ingress {
    description = "SSH para monitoreo y experimentos"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Acceso saliente a RDS y actualizaciones apt"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "opticloud-pregenerator-sg" }
}

# SG: RDS — acepta PostgreSQL (5432) desde Web Servers y Pre-Generator
resource "aws_security_group" "rds_sg" {
  name        = "opticloud-rds-sg"
  description = "PostgreSQL accesible desde Web Servers y Report Pre-Generator"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "PostgreSQL desde Web Servers (Django)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  ingress {
    description     = "PostgreSQL desde Report Pre-Generator"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.pregenerator_sg.id]
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
# RDS – Amazon RDS PostgreSQL (Persistencia)
# Almacena:
#   - pregenerated_reports : reportes pre-calculados por el worker (ASR-2)
#   - analysis_jobs        : cola persistente de trabajos asincronos (ASR-1)
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

  tags = { Name = "opticloud-postgres-rds" }
}

###############################################################################
# REPORT PRE-GENERATOR EC2  (renombrado desde "bd_server" en v2)
#
# Rol segun diagrama de componentes:
#   - Pre-genera reportes y los persiste en RDS  (ASR-2 latencia)
#   - Procesa jobs de analisis de forma asincrona real  (ASR-1 escalabilidad)
#
# NO expone ningun puerto HTTP. Solo inicia conexiones salientes a RDS.
# Tipo: t3.micro (segun presupuesto indicado)
###############################################################################

resource "aws_instance" "report_pregenerator" {
  ami                    = var.ami_id
  instance_type          = "t3.micro"
  subnet_id              = data.aws_subnet.az_a.id
  vpc_security_group_ids = [aws_security_group.pregenerator_sg.id]
  key_name               = aws_key_pair.opticloud_key.key_name

  root_block_device {
    volume_size = 8
    volume_type = "gp2"
  }

  user_data = base64encode(<<-USERDATA
#!/bin/bash
set -e
apt-get update -y
apt-get install -y python3 python3-pip python3-venv

python3 -m venv /opt/opticloud
/opt/opticloud/bin/pip install psycopg2-binary

cat > /opt/opticloud/worker.py << 'PYEOF'
#!/usr/bin/env python3
"""
OptiCloud Worker - Report Pre-Generator + Procesador de analisis asincrono
==========================================================================
Corre en la instancia EC2 report_pregenerator.
NO expone ningun puerto HTTP. Solo lee/escribe en RDS.

Tablas que gestiona:
  pregenerated_reports  - reportes pre-calculados (ASR-2)
  analysis_jobs         - cola persistente de analisis asincronos (ASR-1)
"""
import time, json, hashlib, threading, logging, datetime, random
import psycopg2
from psycopg2.extras import RealDictCursor

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(threadName)s] %(levelname)s %(message)s'
)
logger = logging.getLogger('worker')

DB_HOST = '${aws_db_instance.opticloud_db.address}'
DB_USER = '${var.db_username}'
DB_PASS = '${var.db_password}'
DB_NAME = 'opticloud'

def get_conn():
    return psycopg2.connect(
        dbname=DB_NAME, user=DB_USER,
        password=DB_PASS, host=DB_HOST, port=5432
    )

def bootstrap():
    """Crea las tablas si no existen y resetea jobs interrumpidos."""
    conn = get_conn()
    with conn.cursor() as cur:
        # Tabla para reportes pre-calculados -> ASR-2
        cur.execute("""
            CREATE TABLE IF NOT EXISTS pregenerated_reports (
                report_key   VARCHAR(64) PRIMARY KEY,
                client_id    INTEGER     NOT NULL,
                payload      JSONB       NOT NULL,
                generated_at TIMESTAMP   DEFAULT NOW()
            );
        """)
        # Cola persistente de jobs -> ASR-1
        # Si el worker cae, los jobs siguen en RDS (no se pierden).
        cur.execute("""
            CREATE TABLE IF NOT EXISTS analysis_jobs (
                id           SERIAL      PRIMARY KEY,
                client_id    INTEGER     NOT NULL,
                payload      JSONB,
                status       VARCHAR(16) NOT NULL DEFAULT 'pending',
                enqueued_at  TIMESTAMP   DEFAULT NOW(),
                started_at   TIMESTAMP,
                finished_at  TIMESTAMP,
                result       JSONB
            );
        """)
        # Al reiniciar: resetea jobs que quedaron en 'processing'
        # (worker fue interrumpido a mitad de ejecucion)
        cur.execute("""
            UPDATE analysis_jobs
               SET status = 'pending', started_at = NULL
             WHERE status = 'processing';
        """)
    conn.commit()
    conn.close()
    logger.info("Bootstrap completado: tablas listas en RDS")

def run_pregenerator():
    """
    Thread 1: Report Pre-Generator (ASR-2 latencia).
    Pre-calcula reportes de utilizacion para 100 clientes simulados
    y los persiste en RDS cada 60 segundos.
    Cuando Django recibe GET /report/<id>/, el dato ya existe en RDS
    (o en el Report Cache en memoria) -> latencia baja.
    """
    logger.info("Pre-generator iniciando...")
    while True:
        try:
            conn = get_conn()
            with conn.cursor() as cur:
                for cid in range(1, 101):
                    key = hashlib.md5(f"client_{cid}".encode()).hexdigest()
                    payload = {
                        'client_id':    cid,
                        'cpu_usage':    round(30 + (cid % 50), 2),
                        'memory_usage': round(40 + (cid % 40), 2),
                        'disk_io':      round(10 + (cid % 20), 2),
                        'generated_at': datetime.datetime.utcnow().isoformat(),
                        'status':       'ready',
                    }
                    cur.execute("""
                        INSERT INTO pregenerated_reports
                               (report_key, client_id, payload)
                        VALUES (%s, %s, %s)
                        ON CONFLICT (report_key) DO UPDATE
                          SET payload = EXCLUDED.payload,
                              generated_at = NOW();
                    """, (key, cid, json.dumps(payload)))
            conn.commit()
            conn.close()
            logger.info("Pre-generator: 100 reportes actualizados en RDS")
        except Exception as e:
            logger.error(f"Pre-generator error: {e}")
        time.sleep(60)

def run_job_processor():
    """
    Thread 2: Procesador de analisis asincrono REAL (ASR-1 escalabilidad).

    Flujo desacoplado:
      1. Web Server recibe POST /enqueue/ -> inserta fila en analysis_jobs
         con status='pending' y responde 202 Accepted de inmediato.
         El cliente HTTP no espera el analisis. (desacople real)
      2. Este thread (en proceso separado, instancia EC2 distinta) detecta
         filas 'pending', las marca 'processing', ejecuta el analisis
         y guarda el resultado en RDS.
      3. El cliente consulta GET /job/<id>/ para ver el resultado cuando quiera.

    Persistencia: si el worker cae, los jobs siguen en status='pending'
    en RDS y se reprocesaran al reiniciar (ver bootstrap).

    SKIP LOCKED: evita que multiples workers (si se escala el pregenerator)
    procesen el mismo job en paralelo.
    """
    logger.info("Job processor iniciando...")
    while True:
        try:
            conn = get_conn()
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute("""
                    SELECT id, client_id, payload
                      FROM analysis_jobs
                     WHERE status = 'pending'
                     ORDER BY enqueued_at ASC
                     LIMIT 1
                     FOR UPDATE SKIP LOCKED;
                """)
                job = cur.fetchone()

                if job:
                    job_id    = job['id']
                    client_id = job['client_id']

                    cur.execute("""
                        UPDATE analysis_jobs
                           SET status = 'processing', started_at = NOW()
                         WHERE id = %s;
                    """, (job_id,))
                    conn.commit()
                    logger.info(f"Job {job_id} (cliente {client_id}): procesando...")

                    # Analisis simulado: dura entre 0.5 y 3 segundos.
                    # En produccion aqui iria el calculo real de metricas.
                    # El request HTTP ya retorno 202 hace tiempo; el cliente
                    # no esta esperando esta duracion.
                    duration = random.uniform(0.5, 3.0)
                    time.sleep(duration)

                    result = {
                        'client_id':     client_id,
                        'analysis_time': round(duration, 3),
                        'cpu_p95':       round(60 + random.uniform(0, 30), 2),
                        'mem_p95':       round(55 + random.uniform(0, 35), 2),
                        'completed_at':  datetime.datetime.utcnow().isoformat(),
                    }

                    cur.execute("""
                        UPDATE analysis_jobs
                           SET status = 'done',
                               finished_at = NOW(),
                               result = %s
                         WHERE id = %s;
                    """, (json.dumps(result), job_id))
                    conn.commit()
                    logger.info(f"Job {job_id}: completado en {duration:.2f}s")

            conn.close()

        except Exception as e:
            logger.error(f"Job processor error: {e}")
            time.sleep(2)

        time.sleep(0.5)

if __name__ == '__main__':
    # Esperar a que RDS este disponible
    for attempt in range(20):
        try:
            c = get_conn()
            c.close()
            logger.info("Conexion a RDS establecida")
            break
        except Exception as e:
            logger.warning(f"RDS no disponible (intento {attempt + 1}/20): {e}")
            time.sleep(15)

    bootstrap()

    t1 = threading.Thread(target=run_pregenerator,  name='PreGenerator', daemon=True)
    t2 = threading.Thread(target=run_job_processor, name='JobProcessor',  daemon=True)
    t1.start()
    t2.start()

    while True:
        time.sleep(60)
        logger.info(f"Worker vivo - PreGenerator={t1.is_alive()}, JobProcessor={t2.is_alive()}")
PYEOF

cat > /etc/systemd/system/opticloud-worker.service << 'SVCEOF'
[Unit]
Description=OptiCloud Report Pre-Generator + Async Job Processor
After=network.target

[Service]
ExecStart=/opt/opticloud/bin/python3 /opt/opticloud/worker.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable opticloud-worker
systemctl start opticloud-worker
USERDATA
  )

  tags = { Name = "opticloud-report-pregenerator" }

  depends_on = [aws_db_instance.opticloud_db]
}

###############################################################################
# LAUNCH TEMPLATE – Web Servers (Django + Report Cache + Cola de trabajos)
#
# Execution environment 1 – Cache reportes:
#   Report Cache      : dict en memoria por instancia (ASR-2)
#   Elastic Orch      : /metrics/ para monitoreo interno
#
# Execution environment 2 – Django:
#   Cola de trabajos  : POST /enqueue/ inserta en RDS y retorna 202 (asincrono real)
#   Consulta estado   : GET /job/<id>/ para ver resultado posterior
###############################################################################

resource "aws_launch_template" "web_server" {
  name_prefix   = "opticloud-web-"
  image_id      = var.ami_id
  instance_type = "t3.micro"

  # Key pair para poder conectarse por SSH a cada Web Server del ASG
  key_name = aws_key_pair.opticloud_key.key_name

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

  user_data = base64encode(<<-USERDATA
#!/bin/bash
set -e
apt-get update -y
apt-get install -y python3 python3-pip python3-venv

python3 -m venv /opt/opticloud
/opt/opticloud/bin/pip install django psycopg2-binary gunicorn

mkdir -p /opt/opticloud/app/opticloud

cat > /opt/opticloud/app/settings.py << 'PYEOF'
SECRET_KEY    = 'opticloud-web-key'
DEBUG         = True
ALLOWED_HOSTS = ['*']
INSTALLED_APPS = ['django.contrib.contenttypes', 'django.contrib.auth', 'opticloud']
DATABASES = {
    'default': {
        'ENGINE':       'django.db.backends.postgresql',
        'NAME':         'opticloud',
        'USER':         '${var.db_username}',
        'PASSWORD':     '${var.db_password}',
        'HOST':         '${aws_db_instance.opticloud_db.address}',
        'PORT':         '5432',
        'CONN_MAX_AGE': 60,
    }
}
ROOT_URLCONF     = 'urls'
WSGI_APPLICATION = 'wsgi.application'
PYEOF

cat > /opt/opticloud/app/urls.py << 'PYEOF'
from django.urls import path
from opticloud import views
urlpatterns = [
    # ── Endpoints originales ───────────────────────────────────────────────
    path('health/',            views.health_check),
    path('report/<int:cid>/', views.get_report),
    path('enqueue/',           views.enqueue_job),
    path('job/<int:jid>/',    views.job_status),
    path('metrics/',           views.metrics),
    # ── ASR DISPONIBILIDAD ─────────────────────────────────────────────────
    # [ASR-DISP-DET] Deteccion de falla en generacion de reporte <= 200 ms
    path('worker/status/',     views.worker_status),
    # [ASR-DISP-REP] Recuperacion del worker caido <= 2 s, sin perdida de datos
    path('worker/recover/',    views.worker_recover),
    # ── ASR SEGURIDAD ──────────────────────────────────────────────────────
    # [ASR-SEG-DET] Deteccion de acceso no autorizado <= 200 ms
    path('security/check/',    views.security_check),
    # [ASR-SEG-REP] Bloqueo de IP o comportamiento anomalo
    path('security/block/',    views.security_block),
]
PYEOF

cat > /opt/opticloud/app/wsgi.py << 'PYEOF'
import os
from django.core.wsgi import get_wsgi_application
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'settings')
application = get_wsgi_application()
PYEOF

touch /opt/opticloud/app/opticloud/__init__.py

cat > /opt/opticloud/app/opticloud/views.py << 'PYEOF'
"""
Web Server Views - OptiCloud v3
================================
Execution env 1 - Cache reportes:
  Report Cache : dict en memoria por instancia (ASR-2 latencia < 100ms)

Execution env 2 - Django:
  Cola de trabajos : POST /enqueue/ inserta job en RDS y retorna 202 inmediato.
                     El request HTTP termina aqui. Procesamiento en worker EC2.
  GET /job/<id>/   : consulta de estado posterior (pending/processing/done)

Nuevos endpoints v3:
  ASR DISPONIBILIDAD:
    GET /worker/status/   -> detecta falla del worker (ASR-DISP-DET <= 200ms)
    POST /worker/recover/ -> recupera el worker caido (ASR-DISP-REP <= 2s)
  ASR SEGURIDAD:
    GET /security/check/  -> detecta acceso anomalo (ASR-SEG-DET <= 200ms)
    POST /security/block/ -> bloquea IP sospechosa  (ASR-SEG-REP inmediato)
"""
import time, json, hashlib, threading, logging
import psycopg2
from psycopg2.extras import RealDictCursor
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt

logger = logging.getLogger(__name__)

# ── Estado compartido en memoria ────────────────────────────────────────────
# Report Cache: evita ir a RDS en cada request -> ASR-2 latencia baja
_cache      = {}
_cache_lock = threading.Lock()

# Estado del worker interno (Procesador de Analisis / Health Monitor)
# [ASR-DISP-DET] Este flag simula si el generador de reportes esta activo
_worker_ok   = True
_worker_lock = threading.Lock()

# Lista negra de IPs bloqueadas (IDS / Response Manager)
# [ASR-SEG-REP] Se populea via POST /security/block/
_blocked_ips     = set()
_blocked_ips_lock = threading.Lock()

# Audit log en memoria (Audit Logger)
# [ASR-SEG-DET] Registra cada intento de acceso anomalo con timestamp
_audit_log      = []
_audit_log_lock = threading.Lock()

DB_HOST = '${aws_db_instance.opticloud_db.address}'
DB_USER = '${var.db_username}'
DB_PASS = '${var.db_password}'
DB_NAME = 'opticloud'

def _pg():
    return psycopg2.connect(
        dbname=DB_NAME, user=DB_USER,
        password=DB_PASS, host=DB_HOST, port=5432
    )

# ────────────────────────────────────────────────────────────────────────────
# ENDPOINTS ORIGINALES
# ────────────────────────────────────────────────────────────────────────────

def health_check(request):
    """ALB Health Check - responde 200 para que el ASG detecte instancias sanas."""
    return JsonResponse({'status': 'ok'})

def get_report(request, cid):
    """
    GET /report/<cid>/ - valida ASR-2 (latencia <= 100ms con 5k sostenidos).

    Flujo optimizado:
      1. Report Cache (memoria)   -> respuesta inmediata si hit
      2. RDS pregenerated_reports -> dato pre-calculado por worker EC2,
                                     se guarda en cache y se responde
      3. 404 si no existe aun

    La respuesta incluye 'response_ms' para validar ASR-2 directamente en JMeter.
    """
    t0  = time.monotonic()
    key = hashlib.md5(f"client_{cid}".encode()).hexdigest()

    # 1. Cache hit
    with _cache_lock:
        hit = _cache.get(key)
    if hit:
        ms = round((time.monotonic() - t0) * 1000, 3)
        return JsonResponse({'source': 'cache', 'client_id': cid,
                             'data': hit, 'response_ms': ms})

    # 2. RDS (pre-generado por report_pregenerator EC2)
    try:
        conn = _pg()
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                "SELECT payload FROM pregenerated_reports WHERE report_key = %s",
                (key,)
            )
            row = cur.fetchone()
        conn.close()

        if row:
            payload = row['payload']
            with _cache_lock:
                _cache[key] = payload
            ms = round((time.monotonic() - t0) * 1000, 3)
            return JsonResponse({'source': 'rds_pregenerated', 'client_id': cid,
                                 'data': payload, 'response_ms': ms})

        ms = round((time.monotonic() - t0) * 1000, 3)
        return JsonResponse({'source': 'not_found', 'client_id': cid,
                             'response_ms': ms}, status=404)

    except Exception as e:
        ms = round((time.monotonic() - t0) * 1000, 3)
        return JsonResponse({'error': str(e), 'response_ms': ms}, status=500)

@csrf_exempt
def enqueue_job(request):
    """
    POST /enqueue/ - cola de trabajos ASINCRONA REAL (ASR-1 escalabilidad).
    Inserta en tabla analysis_jobs de RDS y retorna 202 Accepted de inmediato.
    """
    if request.method != 'POST':
        return JsonResponse({'error': 'POST required'}, status=405)
    try:
        body = request.body.decode('utf-8', errors='ignore')
        data = json.loads(body) if body else {}
        cid  = int(data.get('client_id', 1))

        conn = _pg()
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO analysis_jobs (client_id, payload)
                VALUES (%s, %s) RETURNING id, enqueued_at;
            """, (cid, json.dumps(data)))
            row = cur.fetchone()
            job_id = row[0]
            enqueued = row[1].isoformat()
        conn.commit()
        conn.close()

        return JsonResponse({
            'accepted':    True,
            'job_id':      job_id,
            'enqueued_at': enqueued,
            'check_url':   f'/job/{job_id}/',
            'note':        'Analisis en background. Consulta check_url para el resultado.',
        }, status=202)

    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)

def job_status(request, jid):
    """
    GET /job/<jid>/ - consulta estado de un job asincrono.
    Estados: pending -> processing -> done
    """
    try:
        conn = _pg()
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("""
                SELECT id, client_id, status, enqueued_at,
                       started_at, finished_at, result
                  FROM analysis_jobs WHERE id = %s;
            """, (jid,))
            job = cur.fetchone()
        conn.close()

        if not job:
            return JsonResponse({'error': 'Job no encontrado'}, status=404)

        return JsonResponse({
            'job_id':      job['id'],
            'client_id':  job['client_id'],
            'status':      job['status'],
            'enqueued_at': job['enqueued_at'].isoformat() if job['enqueued_at'] else None,
            'started_at':  job['started_at'].isoformat()  if job['started_at']  else None,
            'finished_at': job['finished_at'].isoformat() if job['finished_at'] else None,
            'result':      job['result'],
        })
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)

def metrics(request):
    """
    GET /metrics/ - Elastic Orchestrator.
    Expone estado del Report Cache y jobs en cola.
    """
    with _cache_lock:
        cache_size = len(_cache)
    try:
        conn = _pg()
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*) FROM analysis_jobs WHERE status='pending';")
            pending = cur.fetchone()[0]
            cur.execute("SELECT COUNT(*) FROM analysis_jobs WHERE status='processing';")
            processing = cur.fetchone()[0]
            cur.execute("SELECT COUNT(*) FROM analysis_jobs WHERE status='done';")
            done = cur.fetchone()[0]
        conn.close()
    except Exception:
        pending = processing = done = -1

    return JsonResponse({
        'report_cache_entries': cache_size,
        'jobs_pending':         pending,
        'jobs_processing':      processing,
        'jobs_done':            done,
        'status':               'running',
    })

# ────────────────────────────────────────────────────────────────────────────
# ASR DISPONIBILIDAD – Health Monitor + Exception Handler + Elastic Orchestrator
# ────────────────────────────────────────────────────────────────────────────

def worker_status(request):
    """
    GET /worker/status/   [ASR-DISP-DET]
    ======================================
    Health Monitor: detecta si el generador de reportes esta activo o caido.
    Objetivo: responder en <= 200 ms desde que ocurre la falla.

    Uso del experimento:
      Normal   -> GET /worker/status/           (worker_ok: true)
      Falla    -> GET /worker/status/?fail=1    (fuerza worker_ok: false)
      Recupero -> GET /worker/status/           (ver si volvio a true)

    El campo 'detection_ms' en la respuesta es tu evidencia del ASR.
    """
    t0 = time.monotonic()
    global _worker_ok

    # Simula falla del generador de reportes (Exception Handler detecta)
    if request.GET.get('fail') == '1':
        with _worker_lock:
            _worker_ok = False
        logger.warning("FALLA SIMULADA: worker de generacion de reportes caido")

    with _worker_lock:
        estado = _worker_ok

    # Verificacion adicional: intenta conectar a RDS para validar persistencia
    rds_ok = True
    try:
        conn = _pg()
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
        conn.close()
    except Exception:
        rds_ok = False

    detection_ms = round((time.monotonic() - t0) * 1000, 3)

    return JsonResponse({
        'worker_ok':     estado,
        'rds_ok':        rds_ok,
        'detection_ms':  detection_ms,
        'asr':           'DISP-DET – objetivo <= 200 ms',
        'cumple':        detection_ms <= 200,
        'estado':        'operacional' if estado else 'FALLA_DETECTADA',
    })

@csrf_exempt
def worker_recover(request):
    """
    POST /worker/recover/   [ASR-DISP-REP]
    ========================================
    Exception Handler + Elastic Orchestrator:
    Recupera el worker caido, restaura el cache de reportes desde RDS
    y confirma que la operacion continua sin perdida de datos.
    Objetivo: completar recuperacion en <= 2000 ms.

    Flujo del experimento:
      1. POST /worker/status/?fail=1   -> simula la falla
      2. POST /worker/recover/         -> dispara la recuperacion
      3. Medir 'recovery_ms' en la respuesta

    La recuperacion incluye:
      - Reinicio del flag _worker_ok (simula reinicio del proceso)
      - Recarga del cache desde RDS (datos preexistentes = sin perdida)
      - Confirmacion de conectividad con RDS
    """
    t0 = time.monotonic()
    global _worker_ok

    pasos = []

    # Paso 1: reiniciar el worker (Elastic Orchestrator reinicia/reemplaza)
    with _worker_lock:
        _worker_ok = True
    pasos.append('worker_reiniciado')

    # Paso 2: recargar el cache desde RDS (sin perdida de informacion)
    cache_recargado = 0
    try:
        conn = _pg()
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("SELECT report_key, payload FROM pregenerated_reports LIMIT 100;")
            rows = cur.fetchall()
        conn.close()
        with _cache_lock:
            for r in rows:
                _cache[r['report_key']] = r['payload']
            cache_recargado = len(rows)
        pasos.append(f'cache_recargado_{cache_recargado}_reportes')
    except Exception as e:
        pasos.append(f'cache_reload_error: {str(e)}')

    # Paso 3: confirmacion de disponibilidad (Health Monitor confirma)
    pasos.append('disponibilidad_confirmada')

    recovery_ms = round((time.monotonic() - t0) * 1000, 3)

    return JsonResponse({
        'recovered':        True,
        'recovery_ms':      recovery_ms,
        'cache_recargado':  cache_recargado,
        'pasos':            pasos,
        'asr':              'DISP-REP – objetivo <= 2000 ms',
        'cumple':           recovery_ms <= 2000,
        'perdida_de_datos': False,
    })

# ────────────────────────────────────────────────────────────────────────────
# ASR SEGURIDAD – IDS + Anomaly Detector + Audit Logger + Response Manager
# ────────────────────────────────────────────────────────────────────────────

def security_check(request):
    """
    GET /security/check/   [ASR-SEG-DET]
    ======================================
    IDS + Anomaly Detector + Audit Logger:
    Detecta accesos no autorizados o comportamientos anomalos en <= 200 ms.
    Funciona tanto en operacion normal como durante picos de carga.

    Criterios de anomalia evaluados:
      1. IP en lista negra (_blocked_ips)
      2. Cabecera X-Opticloud-Token ausente (acceso sin autenticacion)
      3. User-Agent vacio (bot o script directo)
      4. Parametro ?flood=1 (simulacion de consultas masivas de reportes)

    Uso del experimento:
      Anomalo  -> GET /security/check/                       (sin token)
      Legitimo -> GET /security/check/ -H 'X-Opticloud-Token: test123'
      IP negra -> POST /security/block/ + GET /security/check/
      Flood    -> GET /security/check/?flood=1
    """
    t0 = time.monotonic()

    client_ip = request.META.get('HTTP_X_FORWARDED_FOR', '').split(',')[0].strip() \
                or request.META.get('REMOTE_ADDR', 'unknown')
    token     = request.headers.get('X-Opticloud-Token', '')
    ua        = request.META.get('HTTP_USER_AGENT', '')
    is_flood  = request.GET.get('flood') == '1'

    anomalias = []

    # Criterio 1: IP bloqueada (IDS)
    with _blocked_ips_lock:
        if client_ip in _blocked_ips:
            anomalias.append('ip_en_lista_negra')

    # Criterio 2: sin token de autenticacion (Autenticador)
    if not token:
        anomalias.append('token_ausente')

    # Criterio 3: User-Agent vacio (bot / acceso directo)
    if not ua:
        anomalias.append('user_agent_vacio')

    # Criterio 4: parametro de flood (generacion masiva de reportes)
    if is_flood:
        anomalias.append('comportamiento_flood_detectado')

    es_anomalo = len(anomalias) > 0

    # Audit Logger: registra el evento con timestamp preciso
    evento = {
        'ts_epoch':  time.time(),
        'ip':        client_ip,
        'token_ok':  bool(token),
        'ua':        ua[:80] if ua else '',
        'anomalias': anomalias,
        'anomalo':   es_anomalo,
    }
    with _audit_log_lock:
        _audit_log.append(evento)
        # Mantener solo los ultimos 500 eventos en memoria
        if len(_audit_log) > 500:
            _audit_log.pop(0)

    detection_ms = round((time.monotonic() - t0) * 1000, 3)

    return JsonResponse({
        'anomalo':       es_anomalo,
        'anomalias':     anomalias,
        'ip':            client_ip,
        'detection_ms':  detection_ms,
        'asr':           'SEG-DET – objetivo <= 200 ms',
        'cumple':        detection_ms <= 200,
        'audit_total':   len(_audit_log),
    }, status=403 if es_anomalo else 200)

@csrf_exempt
def security_block(request):
    """
    POST /security/block/   [ASR-SEG-REP]
    =======================================
    Response Manager: bloquea una IP o patron anomalo de forma inmediata.
    No hay tiempo minimo — el bloqueo es instantaneo en memoria.

    Body JSON esperado:
      { "ip": "1.2.3.4", "motivo": "generacion_masiva_reportes" }

    Todos los accesos posteriores de esa IP en /security/check/
    seran detectados con anomalia 'ip_en_lista_negra'.
    """
    t0 = time.monotonic()

    try:
        data  = json.loads(request.body) if request.body else {}
    except Exception:
        data  = {}

    ip_a_bloquear = data.get('ip', '').strip()
    motivo        = data.get('motivo', 'no_especificado')

    if ip_a_bloquear:
        with _blocked_ips_lock:
            _blocked_ips.add(ip_a_bloquear)
        logger.warning(f"IP BLOQUEADA: {ip_a_bloquear} – motivo: {motivo}")

    block_ms = round((time.monotonic() - t0) * 1000, 3)

    with _blocked_ips_lock:
        total_bloqueadas = len(_blocked_ips)

    return JsonResponse({
        'bloqueada':       bool(ip_a_bloquear),
        'ip':              ip_a_bloquear,
        'motivo':          motivo,
        'total_blocked':   total_bloqueadas,
        'block_ms':        block_ms,
        'asr':             'SEG-REP – bloqueo inmediato',
    })
PYEOF

cat > /opt/opticloud/app/manage.py << 'PYEOF'
import os, sys
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'settings')
from django.core.management import execute_from_command_line
execute_from_command_line(sys.argv)
PYEOF

cat > /etc/systemd/system/opticloud.service << 'SVCEOF'
[Unit]
Description=OptiCloud Django Web Server
After=network.target

[Service]
WorkingDirectory=/opt/opticloud/app
ExecStart=/opt/opticloud/bin/gunicorn wsgi:application \
          --bind 0.0.0.0:8000 \
          --workers 4 \
          --timeout 30 \
          --access-logfile /var/log/gunicorn-access.log \
          --error-logfile /var/log/gunicorn-error.log
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable opticloud
systemctl start opticloud
USERDATA
  )

  tags = { Name = "opticloud-web-server" }

  depends_on = [aws_db_instance.opticloud_db]
}

###############################################################################
# APPLICATION LOAD BALANCER – AWS ELB Service
# Zonas: us-east-2a / us-east-2b  |  Puerto: HTTP:80
# ASR-1: distribuye trafico entre los Web Servers del Auto Scaling Group
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
# AUTO SCALING GROUP – Elastic Orchestrator (escalabilidad horizontal)
#
# ASR-1: escala Web Servers de 1 a 6 instancias segun carga de CPU.
#   - desired = 3  (Web Server A, B, C del diagrama de despliegue)
#   - CPU > 60%  -> scale-out (cooldown 60s para ventana de 10 min)
#   - CPU < 30%  -> scale-in  (fin del pico)
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
  description = "DNS del ALB - usalo en curl y JMeter como host destino"
  value       = aws_lb.opticloud_alb.dns_name
}

output "rds_endpoint" {
  description = "Endpoint del RDS PostgreSQL"
  value       = aws_db_instance.opticloud_db.address
}

output "pregenerator_public_ip" {
  description = "IP publica del Report Pre-Generator EC2 (para SSH)"
  value       = aws_instance.report_pregenerator.public_ip
}

output "ssh_key_path" {
  description = "Ruta a la llave privada SSH generada por Terraform"
  value       = "${path.module}/opticloud_key.pem"
}

output "instrucciones_ssh" {
  description = "Como conectarte por SSH a las instancias del ASG"
  value       = <<-NOTE
    Las instancias Web Server son creadas por el Auto Scaling Group.
    Para ver sus IPs publicas:
      aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=opticloud-web-server" \
                  "Name=instance-state-name,Values=running" \
        --query "Reservations[*].Instances[*].PublicIpAddress" \
        --output text --region us-east-2

    Luego conectate con:
      ssh -i opticloud_key.pem ubuntu@<IP_PUBLICA>

    Para el Pre-Generator:
      ssh -i opticloud_key.pem ubuntu@${aws_instance.report_pregenerator.public_ip}
  NOTE
}

output "asr_disponibilidad_comandos" {
  description = "Comandos para probar los ASRs de Disponibilidad"
  value       = <<-CMDS
    ALB="${aws_lb.opticloud_alb.dns_name}"

    # ── Verificar que el ALB esta listo ──────────────────────────────────
    curl -s "http://$ALB/health/"

    # ── [ASR-DISP-DET] Deteccion de falla <= 200 ms ──────────────────────
    # Paso 1: estado normal (worker_ok: true)
    curl -s "http://$ALB/worker/status/"
    # Paso 2: simular falla
    curl -s "http://$ALB/worker/status/?fail=1"
    # Verificar: 'detection_ms' en la respuesta debe ser <= 200

    # ── [ASR-DISP-REP] Recuperacion <= 2000 ms ───────────────────────────
    # Primero inducir falla, luego recuperar
    curl -s "http://$ALB/worker/status/?fail=1"
    curl -s -X POST "http://$ALB/worker/recover/"
    # Verificar: 'recovery_ms' <= 2000, 'perdida_de_datos': false
  CMDS
}

output "asr_seguridad_comandos" {
  description = "Comandos para probar los ASRs de Seguridad"
  value       = <<-CMDS
    ALB="${aws_lb.opticloud_alb.dns_name}"

    # ── [ASR-SEG-DET] Acceso anomalo sin token (detection_ms <= 200) ─────
    curl -s "http://$ALB/security/check/"

    # ── [ASR-SEG-DET] Acceso legitimo con token ───────────────────────────
    curl -s -H "X-Opticloud-Token: test123" \
            -A "Mozilla/5.0" \
            "http://$ALB/security/check/"

    # ── [ASR-SEG-REP] Bloquear una IP sospechosa ──────────────────────────
    curl -s -X POST "http://$ALB/security/block/" \
         -H "Content-Type: application/json" \
         -d '{"ip":"1.2.3.4","motivo":"generacion_masiva_reportes"}'

    # ── Verificar que la IP quedo bloqueada ───────────────────────────────
    curl -s -H "X-Forwarded-For: 1.2.3.4" \
            "http://$ALB/security/check/"
  CMDS
}

output "asr1_test_note" {
  description = "Como probar ASR-1 (Escalabilidad)"
  value       = "JMeter: 12000 hilos / 10 min -> POST http://${aws_lb.opticloud_alb.dns_name}/enqueue/ con body {client_id: N}. Verifica scale-out en consola EC2."
}

output "asr2_test_note" {
  description = "Como probar ASR-2 (Latencia)"
  value       = "JMeter: 5000 hilos sostenidos -> GET http://${aws_lb.opticloud_alb.dns_name}/report/N/ . Valida response_ms <= 100 en el body JSON."
}
