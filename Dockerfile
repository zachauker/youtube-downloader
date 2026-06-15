# ── Stage 1: Build the React frontend ────────────────────────────────────────
FROM node:22-alpine AS frontend-builder

WORKDIR /app
COPY frontend/package.json frontend/package-lock.json* ./
RUN npm install

COPY frontend/ .
RUN npm run build

# ── Stage 2: Static ffmpeg binary (single ~60MB file, no apt deps) ───────────
FROM mwader/static-ffmpeg:latest AS ffmpeg

# ── Stage 3: Runtime — Python backend + nginx in one container ───────────────
FROM python:3.12-slim

# nginx only — no ffmpeg via apt
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    && rm -rf /var/lib/apt/lists/* \
    # Remove Debian's default site so it doesn't shadow our config
    && rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default

# Drop in the static ffmpeg/ffprobe binaries
COPY --from=ffmpeg /ffmpeg  /usr/local/bin/ffmpeg
COPY --from=ffmpeg /ffprobe /usr/local/bin/ffprobe

# Python dependencies
WORKDIR /app
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Backend source
COPY backend/ .

# Built frontend → nginx web root
COPY --from=frontend-builder /app/dist /usr/share/nginx/html

# nginx config
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8090

ENTRYPOINT ["/entrypoint.sh"]
