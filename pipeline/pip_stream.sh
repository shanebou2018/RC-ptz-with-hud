#!/usr/bin/env bash
# Dual-camera PiP capture + composite + software H.264 encode, pushed to a
# local MediaMTX instance over RTSP.
#
# Rebuilt around the same RTSP push mechanism single_cam_stream.sh uses
# (ffmpeg's own libav RTSP muxer, confirmed working on this Pi) instead of
# GStreamer's compositor + rtspclientsink -- rtspclientsink isn't available
# on Debian trixie (see CLAUDE.md's "Video pipeline constraint" section).
#
# Both rpicam-vid processes run for this script's ENTIRE lifetime and are
# never restarted for a swap -- only which FIFO feeds ffmpeg's "main" vs
# "inset" role changes. This matters: Raspberry Pi camera hardware init
# (sensor mode negotiation, AWB/AGC convergence) takes 1-3+ seconds, which
# an earlier version of this script paid on every swap because it killed
# and relaunched rpicam-vid. Keeping the cameras always-on means a swap
# only restarts the much lighter ffmpeg process -- no camera hardware
# touched at all. While ffmpeg is down between restarts, rpicam-vid's
# write() calls to their FIFOs simply block (standard named-pipe
# backpressure) rather than erroring -- frames resume the instant the new
# ffmpeg reopens the pipes, camera lock never lost.
#
# Live camera swap: send this script's process SIGUSR1 (e.g. `kill -USR1
# $(cat "$PIDFILE")`) and it restarts just its ffmpeg composite/encode
# stage with MAIN_CAM/INSET_CAM's roles flipped. The web app's POST
# /api/pip/swap endpoint does exactly that; the HUD page's "P" key calls
# it (and re-negotiates its WHEP connection shortly after, since MediaMTX
# treats the new RTSP publish as a fresh stream that existing WebRTC
# viewers don't pick up on their own).
#
# NOT YET TESTED ON HARDWARE (the swap path specifically -- the underlying
# dual-camera stream itself is already verified).
set -uo pipefail

# Camera indices are libcamera's own numbers from `rpicam-hello
# --list-cameras`, not fixed hardware slots -- they can renumber any time a
# camera is added/removed/reseated, so re-check before trusting these.
MAIN_CAM="${MAIN_CAM:-0}"
INSET_CAM="${INSET_CAM:-1}"

# Both cameras always capture at this same resolution -- since neither is
# ever restarted, there's no separate "inset capture size" to worry about
# anymore; whichever role a camera plays, ffmpeg scales it down for the
# inset box as needed (see INSET_WIDTH/INSET_HEIGHT). Kept at a size known
# safe from the row-stride corruption bug hit during development (height
# must be a multiple of 16 -- 720 is, arbitrary small sizes like 180
# weren't; see git history) rather than an arbitrary small resolution.
CAM_WIDTH="${CAM_WIDTH:-1280}"
CAM_HEIGHT="${CAM_HEIGHT:-720}"

INSET_WIDTH="${INSET_WIDTH:-480}"
INSET_HEIGHT="${INSET_HEIGHT:-270}"
FRAMERATE="${FRAMERATE:-20}"
BITRATE="${BITRATE:-2500k}"  # ffmpeg's own suffix notation, unlike single_cam_stream.sh's raw bps
INSET_MARGIN="${INSET_MARGIN:-20}"

MEDIAMTX_HOST="${MEDIAMTX_HOST:-127.0.0.1}"
MEDIAMTX_PORT="${MEDIAMTX_PORT:-8554}"
STREAM_PATH="${STREAM_PATH:-robot}"

# web/app.py's /api/pip/swap endpoint reads this to find who to signal.
PIDFILE="${PIDFILE:-/tmp/rc-hud-pip-stream.pid}"
echo $$ > "${PIDFILE}"

RUN_DIR="$(mktemp -d /tmp/pip_stream.XXXXXX)"
# Fixed to which physical camera they carry -- CAM_A is always MAIN_CAM's
# feed, CAM_B is always INSET_CAM's, for the life of this script. "Which
# one is visually the main/inset" is decided purely by ffmpeg's input
# order each time it (re)starts, not by which camera writes to which FIFO.
CAM_A_FIFO="${RUN_DIR}/cam_a.yuv"
CAM_B_FIFO="${RUN_DIR}/cam_b.yuv"
mkfifo "${CAM_A_FIFO}" "${CAM_B_FIFO}"

CAM_A_PID=""
CAM_B_PID=""
FFMPEG_PID=""
SWAPPED=0
SWAP_REQUESTED=0
STOPPING=0

stop_ffmpeg() {
  [ -n "${FFMPEG_PID}" ] && kill "${FFMPEG_PID}" 2>/dev/null
  [ -n "${FFMPEG_PID}" ] && wait "${FFMPEG_PID}" 2>/dev/null
  FFMPEG_PID=""
}

final_cleanup() {
  stop_ffmpeg
  [ -n "${CAM_A_PID}" ] && kill "${CAM_A_PID}" 2>/dev/null
  [ -n "${CAM_B_PID}" ] && kill "${CAM_B_PID}" 2>/dev/null
  [ -n "${CAM_A_PID}" ] && wait "${CAM_A_PID}" 2>/dev/null
  [ -n "${CAM_B_PID}" ] && wait "${CAM_B_PID}" 2>/dev/null
  rm -rf "${RUN_DIR}"
  rm -f "${PIDFILE}"
}
trap final_cleanup EXIT
trap 'STOPPING=1' INT TERM
trap 'SWAP_REQUESTED=1' USR1

# Started once, run continuously -- see the header comment for why. Both
# rpicam-vid blocks opening a FIFO for write until something opens it for
# read, so starting these before ffmpeg is safe -- no manual wait needed.
rpicam-vid -t 0 --camera "${MAIN_CAM}" --codec yuv420 \
  --width "${CAM_WIDTH}" --height "${CAM_HEIGHT}" --framerate "${FRAMERATE}" \
  -o "${CAM_A_FIFO}" &
CAM_A_PID=$!

rpicam-vid -t 0 --camera "${INSET_CAM}" --codec yuv420 \
  --width "${CAM_WIDTH}" --height "${CAM_HEIGHT}" --framerate "${FRAMERATE}" \
  -o "${CAM_B_FIFO}" &
CAM_B_PID=$!

while [ "${STOPPING}" -eq 0 ]; do
  if [ "${SWAPPED}" -eq 0 ]; then
    MAIN_FIFO="${CAM_A_FIFO}"; INSET_FIFO="${CAM_B_FIFO}"
  else
    MAIN_FIFO="${CAM_B_FIFO}"; INSET_FIFO="${CAM_A_FIFO}"
  fi

  ffmpeg -loglevel warning \
    -f rawvideo -pix_fmt yuv420p -s "${CAM_WIDTH}x${CAM_HEIGHT}" -r "${FRAMERATE}" -i "${MAIN_FIFO}" \
    -f rawvideo -pix_fmt yuv420p -s "${CAM_WIDTH}x${CAM_HEIGHT}" -r "${FRAMERATE}" -i "${INSET_FIFO}" \
    -filter_complex "[1:v]scale=${INSET_WIDTH}:${INSET_HEIGHT}[pip];[0:v][pip]overlay=W-w-${INSET_MARGIN}:H-h-${INSET_MARGIN}[out]" \
    -map "[out]" -c:v libx264 -preset ultrafast -tune zerolatency -b:v "${BITRATE}" \
    -f rtsp -rtsp_transport tcp "rtsp://${MEDIAMTX_HOST}:${MEDIAMTX_PORT}/${STREAM_PATH}" &
  FFMPEG_PID=$!

  # Wait for either a swap request or ffmpeg exiting on its own (a real
  # error -- MediaMTX unreachable, etc). Polled quickly (50ms) since this
  # is now the entire swap-detection latency budget that matters.
  CRASHED=1
  while kill -0 "${FFMPEG_PID}" 2>/dev/null; do
    if [ "${SWAP_REQUESTED}" -eq 1 ]; then
      SWAP_REQUESTED=0
      SWAPPED=$((1 - SWAPPED))
      CRASHED=0
      break
    fi
    if [ "${STOPPING}" -eq 1 ]; then
      CRASHED=0
      break
    fi
    sleep 0.05
  done

  stop_ffmpeg

  # Crash-loop guard: only pause before restarting if ffmpeg exited on its
  # own (not a deliberate swap or a stop request), so a real, persistent
  # failure doesn't spin the loop instantly forever.
  if [ "${CRASHED}" -eq 1 ] && [ "${STOPPING}" -eq 0 ]; then
    sleep 2
  fi
done
