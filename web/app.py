"""Serves the HUD web page. Video comes straight from MediaMTX's own WHEP
endpoint (the browser talks to MediaMTX directly, not through this app);
this app just serves the static page and lets the front end know where to
find MediaMTX and the telemetry websocket.
"""

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

app = FastAPI()
app.mount("/", StaticFiles(directory="static", html=True), name="static")
