"""
main.py - The demo web application.

This is a small web service built with FastAPI. It has four endpoints (URLs):

    GET /         -> a friendly hello message (the "real" feature of the app)
    GET /healthz  -> "liveness"  check: "is the process alive?"  (Kubernetes uses this)
    GET /readyz   -> "readiness" check: "can it take traffic?"   (Kubernetes uses this)
    GET /metrics  -> numbers about the app, in the format Prometheus understands
"""

import os
import time

from fastapi import FastAPI, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

# Settings come from environment variables, so the same Docker image can behave
# differently in dev and prod without being rebuilt (a "12-factor app" habit).
APP_ENV = os.getenv("APP_ENV", "local")        # e.g. "dev" or "prod"
APP_VERSION = os.getenv("APP_VERSION", "dev")  # we will set this to the git commit later

# Create the web application object.
app = FastAPI(title="Secure Python Demo App")

# --- Prometheus metrics ------------------------------------------------------
# A Counter only goes up. We count every request, labelled by path, method and status code.
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total number of HTTP requests",
    ["method", "path", "status"],
)
# A Histogram records how long things take (here: seconds per request).
REQUEST_LATENCY = Histogram(
    "http_request_duration_seconds",
    "How long requests take, in seconds",
    ["method", "path"],
)


@app.middleware("http")
async def record_metrics(request: Request, call_next):
    """Runs around EVERY request: measures the time and updates the metrics."""
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = time.perf_counter() - start

    path = request.url.path
    REQUEST_COUNT.labels(request.method, path, response.status_code).inc()
    REQUEST_LATENCY.labels(request.method, path).observe(elapsed)
    return response


@app.get("/")
def home():
    """The main page: returns a small JSON message."""
    return {
        "message": "Hello from the Secure Python Demo App!",
        "environment": APP_ENV,
        "version": APP_VERSION,
    }


@app.get("/healthz")
def liveness():
    """Liveness probe: if this answers, the process is alive. Kubernetes restarts the pod if it stops."""
    return {"status": "alive"}


@app.get("/readyz")
def readiness():
    """Readiness probe: if this answers, the pod may receive traffic.
    A real app would also check its database here. We have none, so we just say ready."""
    return {"status": "ready"}


@app.get("/metrics")
def metrics():
    """Prometheus calls this URL regularly to collect the numbers above."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
