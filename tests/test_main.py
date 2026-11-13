"""Pruebas unitarias: la base de datos y CloudWatch se simulan, no se toca AWS."""
import os

os.environ["METRICS_ENABLED"] = "false"

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import main  # noqa: E402


@pytest.fixture
def client():
    return TestClient(main.app)


@pytest.fixture
def metrics(monkeypatch):
    calls = []
    monkeypatch.setattr(main, "put_metric", lambda name, value, unit="Count": calls.append((name, value)))
    return calls


def _boom(*_args, **_kwargs):
    raise RuntimeError("connection refused")


def test_version_reads_env_var(client, monkeypatch):
    monkeypatch.setenv("APP_VERSION", "v9.9.9")
    resp = client.get("/version")
    assert resp.status_code == 200
    assert resp.json() == {"version": "v9.9.9"}


def test_list_tasks_returns_rows_and_reports_pending(client, monkeypatch, metrics):
    rows = [
        {"id": 1, "title": "a", "done": False, "created_at": "2026-11-12T00:00:00+00:00"},
        {"id": 2, "title": "b", "done": True, "created_at": "2026-11-12T00:00:00+00:00"},
    ]
    monkeypatch.setattr(main, "db_list_tasks", lambda: rows)
    resp = client.get("/tasks")
    assert resp.status_code == 200
    assert resp.json() == rows
    assert ("PendingTasks", 1) in metrics


def test_create_task_returns_201(client, monkeypatch, metrics):
    monkeypatch.setattr(
        main,
        "db_create_task",
        lambda title, done: {"id": 7, "title": title, "done": done, "created_at": "2026-11-12T00:00:00+00:00"},
    )
    monkeypatch.setattr(main, "db_count_pending", lambda: 3)
    resp = client.post("/tasks", json={"title": "estudiar", "done": False})
    assert resp.status_code == 201
    assert resp.json()["id"] == 7
    assert resp.json()["title"] == "estudiar"
    assert ("PendingTasks", 3) in metrics


def test_create_task_rejects_empty_title(client, monkeypatch):
    monkeypatch.setattr(main, "db_create_task", _boom)
    resp = client.post("/tasks", json={"title": "", "done": False})
    assert resp.status_code == 422


def test_db_error_on_read_returns_503_and_counts_error(client, monkeypatch, metrics):
    monkeypatch.setattr(main, "db_list_tasks", _boom)
    resp = client.get("/tasks")
    assert resp.status_code == 503
    assert ("RDSErrors", 1) in metrics


def test_db_error_on_write_counts_error(client, monkeypatch, metrics):
    monkeypatch.setattr(main, "db_create_task", _boom)
    resp = client.post("/tasks", json={"title": "x"})
    assert resp.status_code == 503
    assert ("RDSErrors", 1) in metrics


def test_health_ok(client, monkeypatch, metrics):
    monkeypatch.setenv("APP_VERSION", "v1.0.0")
    monkeypatch.setattr(main, "db_count_pending", lambda: 0)
    resp = client.get("/health")
    body = resp.json()
    assert resp.status_code == 200
    assert body["database"] == "OK"
    assert body["version"] == "v1.0.0"
    assert body["timestamp"]


def test_health_fail_when_db_down(client, monkeypatch, metrics):
    monkeypatch.setattr(main, "db_count_pending", _boom)
    resp = client.get("/health")
    assert resp.status_code == 503
    assert resp.json()["database"] == "FAIL"
    assert ("RDSErrors", 1) in metrics
