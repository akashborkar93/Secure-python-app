"""
test_main.py - Automated tests for the app.

Run them with:   pytest
Each function starting with "test_" is one test. A test passes if every
"assert" line is true. CI will run these on every code change.
"""

from fastapi.testclient import TestClient

from main import app

# TestClient lets us call the app in memory, without starting a real server.
client = TestClient(app)


def test_home_returns_message():
    response = client.get("/")
    assert response.status_code == 200
    assert "Hello" in response.json()["message"]


def test_liveness_probe():
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "alive"}


def test_readiness_probe():
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_metrics_endpoint_counts_requests():
    client.get("/")  # make one request so there is something to count
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "http_requests_total" in response.text
