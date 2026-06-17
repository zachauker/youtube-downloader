#!/bin/sh
set -e

# ── VPN setup (required when PIA credentials are provided) ───────────────────
if [ -n "${PIA_USER:-}" ] && [ -n "${PIA_PASS:-}" ]; then
    /vpn/pia-connect.sh
else
    echo "[VPN] PIA_USER/PIA_PASS not set — starting WITHOUT VPN"
fi

# ── Start FastAPI backend (nginx proxies /api/ to it) ─────────────────────────
uvicorn main:app --host 127.0.0.1 --port 8000 &

# ── Start nginx in foreground (keeps the container alive) ─────────────────────
exec nginx -g "daemon off;"
