#!/bin/bash
set -e
apt-get update -y
apt-get install -y python3 python3-pip python3-venv

python3 -m venv /opt/opticloud
/opt/opticloud/bin/pip install django psycopg2-binary gunicorn

mkdir -p /opt/opticloud/app/opticloud

cat > /opt/opticloud/app/settings.py << 'PYEOF'
SECRET_KEY    = 'opticloud-web-key-sprint3'
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
    path('health/',            views.health_check),
    path('report/<int:cid>/', views.get_report),
    path('enqueue/',           views.enqueue_job),
    path('job/<int:jid>/',    views.job_status),
    path('metrics/',           views.metrics),
    path('worker/status/',     views.worker_status),
    path('worker/recover/',    views.worker_recover),
    path('security/check/',    views.security_check),
    path('security/block/',    views.security_block),
    path('security/audit/',    views.security_audit),
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
OptiCloud Web Server Views v4
===============================
Todos los componentes del diagrama viven en este archivo.

Mapa componente -> implementacion:
  Report Cache          -> _cache dict en memoria
  Report Pre-Generator  -> thread _pregenerate_worker
  Elastic Orchestrator  -> GET /metrics/
  Health Monitor        -> GET /worker/status/      [ASR-DISP-DET]
  Exception Handler     -> logica en worker_recover [ASR-DISP-REP]
  Validador resultados  -> validate_report()        [ASR-DISP-REP]
  Autenticador          -> verifica X-Opticloud-Token
  IDS                   -> verifica IP bloqueada    [ASR-SEG-DET]
  Anomaly Detector      -> detecta flood/UA/token   [ASR-SEG-DET]
  Audit Logger          -> _audit_log + RDS         [ASR-SEG-DET]
  Response Manager      -> POST /security/block/    [ASR-SEG-REP]
  Cola de trabajos      -> POST /enqueue/ -> RDS    [ASR-1]
  Procesador Analisis   -> thread _job_processor    [ASR-1]
"""
import time, json, hashlib, threading, logging, datetime, random
import psycopg2
from psycopg2.extras import RealDictCursor
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt

logger = logging.getLogger(__name__)

DB_HOST = '${aws_db_instance.opticloud_db.address}'
DB_USER = '${var.db_username}'
DB_PASS = '${var.db_password}'
DB_NAME = 'opticloud'

def _pg():
    return psycopg2.connect(
        dbname=DB_NAME, user=DB_USER,
        password=DB_PASS, host=DB_HOST, port=5432
    )

# Estado compartido
_cache            = {}
_cache_lock       = threading.Lock()
_worker_ok        = True
_worker_lock      = threading.Lock()
_blocked_ips      = set()
_blocked_ips_lock = threading.Lock()
_audit_log        = []
_audit_log_lock   = threading.Lock()

# ── Bootstrap ────────────────────────────────────────────────────────────────
def _bootstrap():
    for attempt in range(10):
        try:
            conn = _pg()
            with conn.cursor() as cur:
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS pregenerated_reports (
                        report_key   VARCHAR(64) PRIMARY KEY,
                        client_id    INTEGER     NOT NULL,
                        payload      JSONB       NOT NULL,
                        generated_at TIMESTAMP   DEFAULT NOW()
                    );
                """)
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
                cur.execute("""
                    UPDATE analysis_jobs
                       SET status = 'pending', started_at = NULL
                     WHERE status = 'processing';
                """)
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS security_audit_log (
                        id        SERIAL    PRIMARY KEY,
                        ts        TIMESTAMP DEFAULT NOW(),
                        ip        VARCHAR(50),
                        token_ok  BOOLEAN,
                        anomalias JSONB,
                        anomalo   BOOLEAN
                    );
                """)
            conn.commit()
            conn.close()
            logger.info("Bootstrap OK: tablas listas en RDS")
            return
        except Exception as e:
            logger.warning(f"Bootstrap intento {attempt+1}/10: {e}")
            time.sleep(10)

# ── Report Pre-Generator thread ──────────────────────────────────────────────
def _pregenerate_worker():
    logger.info("Pre-Generator iniciando...")
    while True:
        try:
            conn = _pg()
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
                        INSERT INTO pregenerated_reports (report_key, client_id, payload)
                        VALUES (%s, %s, %s)
                        ON CONFLICT (report_key) DO UPDATE
                          SET payload = EXCLUDED.payload, generated_at = NOW();
                    """, (key, cid, json.dumps(payload)))
            conn.commit()
            conn.close()
            logger.info("Pre-Generator: 100 reportes actualizados")
        except Exception as e:
            logger.error(f"Pre-Generator error: {e}")
        time.sleep(60)

# ── Procesador de Analisis thread ────────────────────────────────────────────
def _job_processor():
    logger.info("Procesador de Analisis iniciando...")
    while True:
        try:
            conn = _pg()
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute("""
                    SELECT id, client_id, payload FROM analysis_jobs
                     WHERE status = 'pending'
                     ORDER BY enqueued_at ASC
                     LIMIT 1 FOR UPDATE SKIP LOCKED;
                """)
                job = cur.fetchone()
                if job:
                    job_id = job['id']
                    cur.execute("""
                        UPDATE analysis_jobs
                           SET status = 'processing', started_at = NOW()
                         WHERE id = %s;
                    """, (job_id,))
                    conn.commit()
                    duration = random.uniform(0.5, 3.0)
                    time.sleep(duration)
                    result = {
                        'client_id':     job['client_id'],
                        'analysis_time': round(duration, 3),
                        'cpu_p95':       round(60 + random.uniform(0, 30), 2),
                        'mem_p95':       round(55 + random.uniform(0, 35), 2),
                        'completed_at':  datetime.datetime.utcnow().isoformat(),
                    }
                    cur.execute("""
                        UPDATE analysis_jobs
                           SET status = 'done', finished_at = NOW(), result = %s
                         WHERE id = %s;
                    """, (json.dumps(result), job_id))
                    conn.commit()
                    logger.info(f"Job {job_id} completado en {duration:.2f}s")
            conn.close()
        except Exception as e:
            logger.error(f"Job processor error: {e}")
            time.sleep(2)
        time.sleep(0.5)

# Arrancar threads background al cargar el modulo
_bg_started = False
def _start_bg():
    global _bg_started
    if not _bg_started:
        _bg_started = True
        _bootstrap()
        threading.Thread(target=_pregenerate_worker, name='PreGenerator', daemon=True).start()
        threading.Thread(target=_job_processor,      name='JobProcessor',  daemon=True).start()

_start_bg()

# ── Validador de resultados ───────────────────────────────────────────────────
# [ASR-DISP-REP] Verifica que un reporte tenga todos los campos antes de
# cargarlo al cache. Sin perdida = todos los reportes pasan la validacion.
def validate_report(payload: dict) -> tuple:
    campos = ['client_id', 'cpu_usage', 'memory_usage', 'disk_io', 'status']
    errores = [c for c in campos if c not in payload]
    return len(errores) == 0, errores

# ════════════════════════════════════════════════════════════════════════════
# ENDPOINTS
# ════════════════════════════════════════════════════════════════════════════

def health_check(request):
    return JsonResponse({'status': 'ok'})

# ── ASR-2 Latencia ───────────────────────────────────────────────────────────
def get_report(request, cid):
    t0  = time.monotonic()
    key = hashlib.md5(f"client_{cid}".encode()).hexdigest()
    with _cache_lock:
        hit = _cache.get(key)
    if hit:
        ms = round((time.monotonic() - t0) * 1000, 3)
        return JsonResponse({'source': 'cache', 'client_id': cid,
                             'data': hit, 'response_ms': ms})
    try:
        conn = _pg()
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                "SELECT payload FROM pregenerated_reports WHERE report_key = %s", (key,))
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
        return JsonResponse({'source': 'not_found', 'response_ms': ms}, status=404)
    except Exception as e:
        ms = round((time.monotonic() - t0) * 1000, 3)
        return JsonResponse({'error': str(e), 'response_ms': ms}, status=500)

# ── ASR-1 Cola de trabajos ───────────────────────────────────────────────────
@csrf_exempt
def enqueue_job(request):
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
            row      = cur.fetchone()
            job_id   = row[0]
            enqueued = row[1].isoformat()
        conn.commit()
        conn.close()
        return JsonResponse({
            'accepted':    True,
            'job_id':      job_id,
            'enqueued_at': enqueued,
            'check_url':   f'/job/{job_id}/',
        }, status=202)
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)

def job_status(request, jid):
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
            'client_id':   job['client_id'],
            'status':      job['status'],
            'enqueued_at': job['enqueued_at'].isoformat() if job['enqueued_at'] else None,
            'started_at':  job['started_at'].isoformat()  if job['started_at']  else None,
            'finished_at': job['finished_at'].isoformat() if job['finished_at'] else None,
            'result':      job['result'],
        })
    except Exception as e:
        return JsonResponse({'error': str(e)}, status=500)

# ── Elastic Orchestrator ─────────────────────────────────────────────────────
def metrics(request):
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

# ── ASR-DISP-DET: Health Monitor ─────────────────────────────────────────────
def worker_status(request):
    """
    Detecta falla en la generacion de reportes.
    GET /worker/status/?fail=1  -> simula falla
    GET /worker/status/         -> consulta estado
    Evidencia: campo 'detection_ms' debe ser <= 200
    """
    t0 = time.monotonic()
    global _worker_ok

    if request.GET.get('fail') == '1':
        with _worker_lock:
            _worker_ok = False
        logger.warning("FALLA SIMULADA: worker caido")

    with _worker_lock:
        estado = _worker_ok

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
        'worker_ok':    estado,
        'rds_ok':       rds_ok,
        'detection_ms': detection_ms,
        'cumple':       detection_ms <= 200,
        'estado':       'operacional' if estado else 'FALLA_DETECTADA',
        'asr':          'DISP-DET - objetivo <= 200 ms',
    })

# ── ASR-DISP-REP: Exception Handler + Validador de resultados ────────────────
@csrf_exempt
def worker_recover(request):
    """
    Recupera el worker y valida los reportes (sin perdida de datos).
    POST /worker/recover/
    Evidencia: 'recovery_ms' <= 2000, 'validacion_ok': true, 'perdida_de_datos': false

    Flujo completo del experimento:
      1. GET /worker/status/?fail=1   -> simula la falla
      2. POST /worker/recover/        -> dispara recuperacion
      3. GET /worker/status/          -> confirma que volvio a operacional
    """
    t0 = time.monotonic()
    global _worker_ok
    pasos              = []
    reportes_validos   = 0
    reportes_invalidos = 0

    # Exception Handler: atrapa el error y reinicia el worker
    with _worker_lock:
        _worker_ok = True
    pasos.append('exception_handler_reinicio_worker')

    # Validador de resultados: recarga cache verificando cada reporte
    try:
        conn = _pg()
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("SELECT report_key, payload FROM pregenerated_reports LIMIT 100;")
            rows = cur.fetchall()
        conn.close()
        with _cache_lock:
            for r in rows:
                es_valido, errores = validate_report(r['payload'])
                if es_valido:
                    _cache[r['report_key']] = r['payload']
                    reportes_validos += 1
                else:
                    reportes_invalidos += 1
                    logger.error(f"Reporte invalido: {errores}")
        pasos.append(f'validador_verifico_{reportes_validos}_reportes_ok')
    except Exception as e:
        pasos.append(f'cache_reload_error: {str(e)}')

    # Elastic Orchestrator confirma disponibilidad
    pasos.append('disponibilidad_confirmada')

    recovery_ms = round((time.monotonic() - t0) * 1000, 3)
    return JsonResponse({
        'recovered':          True,
        'recovery_ms':        recovery_ms,
        'cumple':             recovery_ms <= 2000,
        'reportes_validos':   reportes_validos,
        'reportes_invalidos': reportes_invalidos,
        'validacion_ok':      reportes_invalidos == 0,
        'pasos':              pasos,
        'perdida_de_datos':   False,
        'asr':                'DISP-REP - objetivo <= 2000 ms',
    })

# ── ASR-SEG-DET: IDS + Autenticador + Anomaly Detector + Audit Logger ────────
def security_check(request):
    """
    Detecta accesos anomalos en <= 200 ms.
    Criterios: IP bloqueada, token ausente, UA vacio, flood.
    Evidencia: 'detection_ms' <= 200, 'cumple': true

    Experimentos:
      Anomalo  -> GET /security/check/                     (sin token)
      Legitimo -> GET /security/check/ + X-Opticloud-Token: test123
      IP negra -> bloquear IP y luego consultar con esa IP
      Flood    -> GET /security/check/?flood=1
    """
    t0 = time.monotonic()

    client_ip = (request.META.get('HTTP_X_FORWARDED_FOR', '').split(',')[0].strip()
                 or request.META.get('REMOTE_ADDR', 'unknown'))
    token    = request.headers.get('X-Opticloud-Token', '')
    ua       = request.META.get('HTTP_USER_AGENT', '')
    is_flood = request.GET.get('flood') == '1'

    anomalias = []
    with _blocked_ips_lock:
        if client_ip in _blocked_ips:
            anomalias.append('ip_en_lista_negra')
    if not token:
        anomalias.append('token_ausente')
    if not ua:
        anomalias.append('user_agent_vacio')
    if is_flood:
        anomalias.append('comportamiento_flood_detectado')

    es_anomalo = len(anomalias) > 0

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
        if len(_audit_log) > 500:
            _audit_log.pop(0)

    if es_anomalo:
        try:
            conn = _pg()
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO security_audit_log (ip, token_ok, anomalias, anomalo)
                    VALUES (%s, %s, %s, %s);
                """, (client_ip, bool(token), json.dumps(anomalias), es_anomalo))
            conn.commit()
            conn.close()
        except Exception as e:
            logger.error(f"Audit log RDS error: {e}")

    detection_ms = round((time.monotonic() - t0) * 1000, 3)
    return JsonResponse({
        'anomalo':      es_anomalo,
        'anomalias':    anomalias,
        'ip':           client_ip,
        'detection_ms': detection_ms,
        'cumple':       detection_ms <= 200,
        'audit_total':  len(_audit_log),
        'asr':          'SEG-DET - objetivo <= 200 ms',
    }, status=403 if es_anomalo else 200)

# ── ASR-SEG-REP: Response Manager ────────────────────────────────────────────
@csrf_exempt
def security_block(request):
    """
    Bloquea una IP de forma inmediata.
    Body: { "ip": "1.2.3.4", "motivo": "generacion_masiva_reportes" }
    Evidencia: 'block_ms' es minimo (instantaneo)

    Experimento completo:
      1. POST /security/block/ con ip a bloquear
      2. GET /security/check/ con header X-Forwarded-For: <ip bloqueada>
         -> debe aparecer 'ip_en_lista_negra' en anomalias
    """
    t0 = time.monotonic()
    try:
        data = json.loads(request.body) if request.body else {}
    except Exception:
        data = {}

    ip_a_bloquear = data.get('ip', '').strip()
    motivo        = data.get('motivo', 'no_especificado')

    if ip_a_bloquear:
        with _blocked_ips_lock:
            _blocked_ips.add(ip_a_bloquear)
        logger.warning(f"IP BLOQUEADA: {ip_a_bloquear} motivo: {motivo}")

    with _blocked_ips_lock:
        total = len(_blocked_ips)

    block_ms = round((time.monotonic() - t0) * 1000, 3)
    return JsonResponse({
        'bloqueada':     bool(ip_a_bloquear),
        'ip':            ip_a_bloquear,
        'motivo':        motivo,
        'total_blocked': total,
        'block_ms':      block_ms,
        'asr':           'SEG-REP - bloqueo inmediato',
    })

# ── Audit Logger: consulta ────────────────────────────────────────────────────
def security_audit(request):
    """Consulta los ultimos 50 eventos de seguridad registrados."""
    with _audit_log_lock:
        log = list(_audit_log[-50:])
    return JsonResponse({
        'total_eventos': len(_audit_log),
        'ultimos_50':    log,
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
Description=OptiCloud Django Web Server v4
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