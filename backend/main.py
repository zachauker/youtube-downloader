import asyncio
import json
import os
import uuid
import threading
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Optional, AsyncGenerator

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import yt_dlp

DOWNLOAD_DIR = Path(os.environ.get("DOWNLOAD_DIR", "/downloads"))
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
DB_PATH = DATA_DIR / "downloads.db"

DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
DATA_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="YT Downloader")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Global state ──────────────────────────────────────────────────────────────
items: dict[str, dict] = {}        # id → item dict
queue_order: list[str] = []        # insertion-ordered ids
sse_queues: list[asyncio.Queue] = []
state_lock = threading.Lock()
worker_trigger = threading.Event()
main_loop: Optional[asyncio.AbstractEventLoop] = None


# ── Database ──────────────────────────────────────────────────────────────────
def get_db():
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = get_db()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS history (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            title TEXT,
            quality TEXT,
            status TEXT NOT NULL,
            error TEXT,
            file_path TEXT,
            created_at TEXT NOT NULL,
            completed_at TEXT
        )
    """)
    conn.commit()
    conn.close()


init_db()


# ── Helpers ───────────────────────────────────────────────────────────────────
def broadcast(event_type: str, data: dict):
    """Thread-safe push to all SSE subscribers."""
    if not main_loop:
        return
    payload = json.dumps({"type": event_type, "data": data})

    async def _push():
        for q in list(sse_queues):
            await q.put(payload)

    asyncio.run_coroutine_threadsafe(_push(), main_loop)


FORMAT_MAP = {
    "best":   "bestvideo*+bestaudio*/best",
    "1080p":  "bestvideo*[height<=1080]+bestaudio*/best[height<=1080]/best",
    "720p":   "bestvideo*[height<=720]+bestaudio*/best[height<=720]/best",
    "480p":   "bestvideo*[height<=480]+bestaudio*/best[height<=480]/best",
    "360p":   "bestvideo*[height<=360]+bestaudio*/best[height<=360]/best",
    "audio":  "bestaudio[ext=m4a]/bestaudio",
}


# ── Download worker (runs in its own thread) ──────────────────────────────────
def _worker():
    while True:
        worker_trigger.wait()
        worker_trigger.clear()

        while True:
            with state_lock:
                next_id = next(
                    (i for i in queue_order if items[i]["status"] == "queued"),
                    None,
                )
                if not next_id:
                    break
                items[next_id]["status"] = "downloading"
                item = dict(items[next_id])

            broadcast("update", items[next_id])

            def make_hook(item_id: str):
                def hook(d):
                    if d["status"] == "downloading":
                        raw = d.get("_percent_str", "0%").strip().rstrip("%")
                        try:
                            pct = float(raw)
                        except ValueError:
                            pct = 0.0
                        with state_lock:
                            if item_id in items:
                                items[item_id]["progress"] = pct
                                items[item_id]["speed"] = d.get("_speed_str", "").strip()
                                items[item_id]["eta"] = d.get("_eta_str", "").strip()
                                snapshot = dict(items[item_id])
                        broadcast("update", snapshot)
                    elif d["status"] == "finished":
                        with state_lock:
                            if item_id in items:
                                items[item_id]["progress"] = 100.0
                                snapshot = dict(items[item_id])
                        broadcast("update", snapshot)
                return hook

            fmt = FORMAT_MAP.get(item["quality"], FORMAT_MAP["best"])
            ydl_opts: dict = {
                "format": fmt,
                "outtmpl": str(DOWNLOAD_DIR / "%(uploader)s/%(title)s.%(ext)s"),
                "progress_hooks": [make_hook(next_id)],
                "merge_output_format": "mp4",
                "noplaylist": False,
                "extractor_args": {
                    "youtube": {
                        "player_client": ["web", "default"],
                    }
                },
            }
            cookie_file = DOWNLOAD_DIR / "cookies.txt"
            if cookie_file.exists():
                ydl_opts["cookiefile"] = str(cookie_file)
            if item["quality"] == "audio":
                ydl_opts["postprocessors"] = [{
                    "key": "FFmpegExtractAudio",
                    "preferredcodec": "mp3",
                    "preferredquality": "192",
                }]
                ydl_opts["outtmpl"] = str(DOWNLOAD_DIR / "%(uploader)s/%(title)s.%(ext)s")

            try:
                with yt_dlp.YoutubeDL(ydl_opts) as ydl:
                    info = ydl.extract_info(item["url"], download=True)

                if info is None:
                    raise Exception(
                        "yt-dlp returned no data — the video may be unavailable, "
                        "age-restricted, or this VPN exit-node is blocked by YouTube. "
                        "Check the container logs for details."
                    )

                title = "Unknown"
                if info:
                    if info.get("_type") == "playlist":
                        title = info.get("title", "Playlist")
                    else:
                        title = info.get("title", "Unknown")

                completed_at = datetime.now().isoformat()
                with state_lock:
                    items[next_id].update(
                        status="complete",
                        title=title,
                        progress=100.0,
                        completed_at=completed_at,
                    )
                    snapshot = dict(items[next_id])

                conn = get_db()
                conn.execute(
                    "INSERT OR REPLACE INTO history VALUES (?,?,?,?,?,?,?,?,?)",
                    (next_id, item["url"], title, item["quality"],
                     "complete", None, None, item["created_at"], completed_at),
                )
                conn.commit()
                conn.close()

            except Exception as exc:
                error_msg = str(exc)
                completed_at = datetime.now().isoformat()
                with state_lock:
                    items[next_id].update(
                        status="failed",
                        error=error_msg,
                        completed_at=completed_at,
                    )
                    snapshot = dict(items[next_id])

                conn = get_db()
                conn.execute(
                    "INSERT OR REPLACE INTO history VALUES (?,?,?,?,?,?,?,?,?)",
                    (next_id, item["url"], items[next_id].get("title"),
                     item["quality"], "failed", error_msg, None,
                     item["created_at"], completed_at),
                )
                conn.commit()
                conn.close()

            broadcast("update", snapshot)


threading.Thread(target=_worker, daemon=True).start()


# ── Startup ───────────────────────────────────────────────────────────────────
@app.on_event("startup")
async def startup():
    global main_loop
    main_loop = asyncio.get_event_loop()


# ── Request models ─────────────────────────────────────────────────────────────
class DownloadRequest(BaseModel):
    url: str
    quality: str = "best"


# ── API routes ────────────────────────────────────────────────────────────────
@app.post("/api/download")
async def add_download(req: DownloadRequest):
    item_id = str(uuid.uuid4())
    item = {
        "id": item_id,
        "url": req.url,
        "quality": req.quality,
        "status": "queued",
        "title": None,
        "progress": 0.0,
        "speed": None,
        "eta": None,
        "error": None,
        "created_at": datetime.now().isoformat(),
        "completed_at": None,
    }
    with state_lock:
        items[item_id] = item
        queue_order.append(item_id)

    worker_trigger.set()
    broadcast("update", item)
    return item


@app.get("/api/queue")
async def get_queue():
    with state_lock:
        return [
            dict(items[i])
            for i in queue_order
            if items[i]["status"] in ("queued", "downloading")
        ]


@app.get("/api/history")
async def get_history():
    conn = get_db()
    rows = conn.execute(
        "SELECT * FROM history ORDER BY created_at DESC LIMIT 200"
    ).fetchall()
    conn.close()
    return [dict(r) for r in rows]


@app.delete("/api/queue/{item_id}")
async def cancel_item(item_id: str):
    with state_lock:
        if item_id not in items:
            raise HTTPException(404, "Not found")
        if items[item_id]["status"] != "queued":
            raise HTTPException(400, "Only queued items can be cancelled")
        items[item_id]["status"] = "cancelled"
        snapshot = dict(items[item_id])
    broadcast("update", snapshot)
    return {"ok": True}


@app.get("/api/info")
async def get_info(url: str):
    """Fetch title / playlist count without downloading."""
    loop = asyncio.get_event_loop()

    def _fetch():
        opts: dict = {
            "quiet": True,
            "no_warnings": True,
            "extract_flat": True,
            "noplaylist": False,
        }
        cookie_file = DOWNLOAD_DIR / "cookies.txt"
        if cookie_file.exists():
            opts["cookiefile"] = str(cookie_file)
        with yt_dlp.YoutubeDL(opts) as ydl:
            return ydl.extract_info(url, download=False)

    try:
        info = await loop.run_in_executor(None, _fetch)
    except Exception as exc:
        raise HTTPException(400, str(exc))

    if not info:
        raise HTTPException(400, "Could not fetch info")

    is_playlist = info.get("_type") == "playlist"
    entries = list(info.get("entries") or []) if is_playlist else []
    return {
        "title": info.get("title", "Unknown"),
        "is_playlist": is_playlist,
        "count": len(entries) if is_playlist else 1,
        "thumbnail": info.get("thumbnail"),
        "duration": info.get("duration"),
    }


@app.get("/api/events")
async def sse(request=None):
    """Server-Sent Events endpoint for real-time progress."""
    q: asyncio.Queue = asyncio.Queue()
    sse_queues.append(q)

    with state_lock:
        initial = [dict(items[i]) for i in queue_order]

    async def generate() -> AsyncGenerator[str, None]:
        try:
            for item in initial:
                yield f"data: {json.dumps({'type': 'update', 'data': item})}\n\n"
            while True:
                try:
                    payload = await asyncio.wait_for(q.get(), timeout=25)
                    yield f"data: {payload}\n\n"
                except asyncio.TimeoutError:
                    yield ": heartbeat\n\n"
        finally:
            try:
                sse_queues.remove(q)
            except ValueError:
                pass

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
