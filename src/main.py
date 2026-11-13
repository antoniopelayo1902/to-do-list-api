"""to-do-list-api: FastAPI + PostgreSQL (RDS) + métricas en CloudWatch."""
import json
import logging
import os
import threading
import time
from contextlib import contextmanager
from datetime import datetime, timezone

import boto3
import psycopg2
from botocore.config import Config
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("todo-api")

REGION = os.getenv("AWS_REGION", "us-east-1")
NAMESPACE = os.getenv("METRICS_NAMESPACE", "TodoApp")
SECRET_TTL_SECONDS = 300
# Timeouts cortos: si RDS o la API de AWS no responden, la petición falla rápido en vez de colgarse.
BOTO_CONFIG = Config(connect_timeout=2, read_timeout=3, retries={"max_attempts": 2, "mode": "standard"})
DB_CONNECT_TIMEOUT_SECONDS = 3

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS tasks (
    id         SERIAL PRIMARY KEY,
    title      TEXT        NOT NULL,
    done       BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)
"""

app = FastAPI(title="to-do-list-api")

_clients = {}
_secret_cache = {"value": None, "expires": 0.0}
_schema_ready = False
_schema_lock = threading.Lock()


class TaskIn(BaseModel):
    title: str = Field(..., min_length=1, max_length=200)
    done: bool = False


# --------------------------------------------------------------------------- AWS
def _client(name):
    if name not in _clients:
        _clients[name] = boto3.client(name, region_name=REGION, config=BOTO_CONFIG)
    return _clients[name]


def get_db_credentials():
    """Lee las credenciales de RDS desde Secrets Manager (con caché de 5 min)."""
    now = time.time()
    if _secret_cache["value"] and now < _secret_cache["expires"]:
        return _secret_cache["value"]
    secret_id = os.environ["SECRET_ID"]
    raw = _client("secretsmanager").get_secret_value(SecretId=secret_id)["SecretString"]
    creds = json.loads(raw)
    _secret_cache.update(value=creds, expires=now + SECRET_TTL_SECONDS)
    return creds


def put_metric(name, value, unit="Count"):
    """Publica una métrica propia; un fallo de CloudWatch nunca tumba la petición."""
    if os.getenv("METRICS_ENABLED", "true").lower() != "true":
        return
    try:
        _client("cloudwatch").put_metric_data(
            Namespace=NAMESPACE,
            MetricData=[{"MetricName": name, "Value": float(value), "Unit": unit}],
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("put_metric_data %s failed: %s", name, exc)


def record_db_error(operation, exc):
    logger.error("RDS %s error: %s", operation, exc)
    put_metric("RDSErrors", 1)


# --------------------------------------------------------------------------- DB
@contextmanager
def db_cursor():
    global _schema_ready
    creds = get_db_credentials()
    try:
        conn = psycopg2.connect(
            host=creds["host"],
            port=int(creds.get("port", 5432)),
            dbname=creds["dbname"],
            user=creds["username"],
            password=creds["password"],
            connect_timeout=DB_CONNECT_TIMEOUT_SECONDS,
        )
    except psycopg2.OperationalError:
        # Si se recreó RDS con otra contraseña, el siguiente intento vuelve a leer el secreto.
        _secret_cache["expires"] = 0.0
        raise
    try:
        if not _schema_ready:
            with _schema_lock, conn, conn.cursor() as cur:
                cur.execute(SCHEMA_SQL)
            _schema_ready = True
        with conn, conn.cursor() as cur:
            yield cur
    finally:
        conn.close()


def _row_to_task(row):
    return {"id": row[0], "title": row[1], "done": row[2], "created_at": row[3].isoformat()}


def db_list_tasks():
    with db_cursor() as cur:
        cur.execute("SELECT id, title, done, created_at FROM tasks ORDER BY id")
        return [_row_to_task(r) for r in cur.fetchall()]


def db_create_task(title, done):
    with db_cursor() as cur:
        cur.execute(
            "INSERT INTO tasks (title, done) VALUES (%s, %s) RETURNING id, title, done, created_at",
            (title, done),
        )
        return _row_to_task(cur.fetchone())


def db_count_pending():
    with db_cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM tasks WHERE NOT done")
        return cur.fetchone()[0]


# --------------------------------------------------------------------------- API
@app.get("/tasks")
def list_tasks():
    try:
        tasks = db_list_tasks()
    except Exception as exc:  # noqa: BLE001
        record_db_error("read", exc)
        raise HTTPException(status_code=503, detail="database unavailable")
    put_metric("PendingTasks", sum(1 for t in tasks if not t["done"]))
    return tasks


@app.post("/tasks", status_code=201)
def create_task(task: TaskIn):
    try:
        created = db_create_task(task.title, task.done)
        pending = db_count_pending()
    except Exception as exc:  # noqa: BLE001
        record_db_error("write", exc)
        raise HTTPException(status_code=503, detail="database unavailable")
    put_metric("PendingTasks", pending)
    return created


@app.get("/version")
def version():
    return {"version": os.getenv("APP_VERSION", "dev")}


@app.get("/health")
def health():
    body = {
        "status": "OK",
        "database": "OK",
        "version": os.getenv("APP_VERSION", "dev"),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    try:
        pending = db_count_pending()
    except Exception as exc:  # noqa: BLE001
        record_db_error("health", exc)
        body.update(status="FAIL", database="FAIL")
        return JSONResponse(body, status_code=503)
    put_metric("PendingTasks", pending)
    return body
