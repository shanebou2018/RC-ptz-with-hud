"""Serves the HUD web page. Video comes straight from MediaMTX's own WHEP
endpoint (the browser talks to MediaMTX directly, not through this app);
this app just serves the static page and lets the front end know where to
find MediaMTX and the telemetry websocket.

Also exposes a small control endpoint for the dual-camera PiP swap: POST
/api/pip/swap sends SIGUSR1 to pipeline/pip_stream.sh (found via the PID
file that script writes on startup), which restarts its own capture with
MAIN_CAM/INSET_CAM's roles flipped -- see that script for how and why.
Returns 503 if pip_stream.sh isn't running (e.g. still on
single_cam_stream.sh, or not started yet).
"""

import os
import signal

from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles

app = FastAPI()

PIP_STREAM_PIDFILE = os.environ.get("PIP_STREAM_PIDFILE", "/tmp/rc-hud-pip-stream.pid")


@app.post("/api/pip/swap")
def swap_pip():
    try:
        with open(PIP_STREAM_PIDFILE) as f:
            pid = int(f.read().strip())
        os.kill(pid, signal.SIGUSR1)
    except (OSError, ValueError) as exc:
        raise HTTPException(
            status_code=503,
            detail=f"pip_stream.sh not running or not signalable: {exc}",
        ) from exc
    return {"ok": True}


app.mount("/", StaticFiles(directory="static", html=True), name="static")
