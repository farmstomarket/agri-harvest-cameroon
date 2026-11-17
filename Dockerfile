# syntax=docker/dockerfile:1.7
FROM python:3.12-slim AS builder
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install -r requirements.txt

FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"
RUN groupadd -g 1001 appgroup \
    && useradd -u 1001 -g appgroup -s /usr/sbin/nologin -m appuser
COPY --from=builder /opt/venv /opt/venv
WORKDIR /app
COPY --chown=appuser:appgroup . .
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import socket,sys; s=socket.socket(); s.settimeout(3); sys.exit(0 if s.connect_ex(('127.0.0.1',8000))==0 else 1)"
LABEL org.opencontainers.image.title="agri-harvest-cameroon" \
      org.opencontainers.image.vendor="Farms2Market" \
      maintainer="devops@farmstomarket.co"
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
