#!/bin/sh
set -e

# Start FastAPI backend on localhost (nginx proxies /api/ to it)
uvicorn main:app --host 127.0.0.1 --port 8000 &

# Start nginx in foreground (keeps the container alive)
exec nginx -g "daemon off;"
