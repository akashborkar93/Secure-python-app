# =============================================================================
# Dockerfile - Recipe for building the app's container image
# =============================================================================
# We use a "multi-stage build": two stages in one file.
#   Stage 1 (builder): installs the libraries. Needs tools we don't want in the final image.
#   Stage 2 (final):   a clean small image that only copies in what the app needs.
# Result: a smaller, safer image.

# ---------- Stage 1: builder ----------
# "slim" = a small Debian-based Python image. Pinned to a version, never "latest".
FROM python:3.12-slim AS builder

# Create an isolated Python environment at /venv and make it the default python.
RUN python -m venv /venv
ENV PATH="/venv/bin:$PATH"

# Copy ONLY the requirements first. Docker caches this layer, so libraries are
# not re-downloaded unless requirements.txt changes (faster rebuilds).
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---------- Stage 2: final image ----------
FROM python:3.12-slim

# PYTHONUNBUFFERED=1 : show logs immediately.
# PYTHONDONTWRITEBYTECODE=1 : don't write .pyc files (keeps the filesystem clean/read-only friendly).
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/venv/bin:$PATH"

# SECURITY: create a normal user. Running as root inside containers is risky.
# UID 10001 is a fixed number so Kubernetes can verify we are not root.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin appuser

WORKDIR /app

# Copy the installed libraries from stage 1 and the app code from our folder.
COPY --from=builder /venv /venv
COPY main.py .

# From here on, run as the non-root user.
USER 10001

# Document that the app listens on port 8000 (does not publish it by itself).
EXPOSE 8000

# Start the web server. 0.0.0.0 = accept connections from outside the container.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
