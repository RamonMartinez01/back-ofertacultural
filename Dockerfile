# ==========================================
# FASE 1: BUILDER (Entorno de compilación)
# ==========================================
FROM python:3.11-slim AS builder

# Evitar escritura de bytecodes y buffer de logs
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /build

# Instalamos compiladores y dependencias de sistema
# Todo en una sola capa limpia
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

# En lugar de instalar directamente, creamos "wheels" (binarios precompilados)
# Esto compila el código C de las librerías para pasarlo a la fase final
RUN pip wheel --no-cache-dir --no-deps --wheel-dir /build/wheels -r requirements.txt

# ==========================================
# FASE 2: RUNNER (Entorno de producción)
# ==========================================
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Creamos un usuario sin privilegios por seguridad
RUN addgroup --system appgroup && adduser --system --group appuser

WORKDIR /app

# Instalamos SOLO la librería de ejecución de Postgres (ya no necesitamos gcc ni -dev)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    && rm -rf /var/lib/apt/lists/*

# Copiamos las wheels compiladas desde la fase 'builder'
COPY --from=builder /build/wheels /wheels
COPY --from=builder /build/requirements.txt .

# Instalamos las librerías a partir de nuestras wheels, sin descargar nada de internet
RUN pip install --no-cache /wheels/*

# Copiamos el código fuente y le damos propiedad al usuario sin privilegios
COPY --chown=appuser:appgroup . .

# Le decimos a Docker que ejecute el contenedor con este usuario seguro
USER appuser

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--forwarded-allow-ips", "*"]