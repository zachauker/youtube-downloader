# ── Stage 1: Build the React frontend ────────────────────────────────────────
FROM node:22-alpine AS frontend-builder

WORKDIR /app
COPY frontend/package.json frontend/package-lock.json* ./
RUN npm install

COPY frontend/ .
RUN npm run build

# ── Stage 2: Runtime — Python backend + nginx in one container ───────────────
FROM python:3.12-slim

# nginx + ffmpeg (required by yt-dlp to merge video/audio streams)
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

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

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
