#!/bin/sh
set -e

# Print a clear message if anything in this script fails
trap 'echo "[STARTUP] FATAL: startup failed at line $LINENO — check the logs above" >&2' EXIT

# ── VPN ──────────────────────────────────────────────────────────────────────
if [ -n "${PIA_USER:-}" ] && [ -n "${PIA_PASS:-}" ]; then
    /vpn/pia-connect.sh
else
    echo "[STARTUP] WARNING: PIA_USER/PIA_PASS not set — starting WITHOUT VPN"
fi

# ── Backend ───────────────────────────────────────────────────────────────────
echo "[STARTUP] Starting FastAPI backend..."
uvicorn main:app --host 127.0.0.1 --port 8000 &

# ── nginx ─────────────────────────────────────────────────────────────────────
echo "[STARTUP] Starting nginx on port ${WEBUI_PORT:-8090}..."

# Disable the trap now that startup succeeded
trap - EXIT
exec nginx -g "daemon off;"
