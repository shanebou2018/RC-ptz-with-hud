#!/usr/bin/env bash
# Dual-camera PiP capture + composite + software H.264 encode, pushed to a
# local MediaMTX instance over RTSP.
#
# Rebuilt around the same RTSP push mechanism single_cam_stream.sh uses
# (ffmpeg's own libav RTSP muxer, confirmed working on this Pi) instead of
# GStreamer's compositor + rtspclientsink -- rtspclientsink isn't available
# on Debian trixie (see CLAUDE.md's "Video pipeline constraint" section).
#
# Two rpicam-vid processes each write raw YUV420 frames into a named pipe;
# a single ffmpeg process reads both, composites the inset over the main
# feed with its overlay filter, encodes (software libx264 -- Pi 5 has no
# hardware encoder), and pushes RTSP. Confirmed working on real hardware.
#
# Live camera swap: send this script's process SIGUSR1 (e.g. `kill -USR1
# $(cat "$PIDFILE")`) and it restarts its own rpicam-vid/ffmpeg children
# with MAIN_CAM/INSET_CAM's roles flipped -- systemd only ever sees one
# long-running process, so this needs no service restart / sudo. The web
# app's POST /api/pip/swap endpoint does exactly that; the HUD page's "P"
# key calls it. NOT YET TESTED ON HARDWARE (the swap path specifically --
# the underlying dual-camera stream itself is already verified).
set -uo pipefail

# Camera indices are libcamera's own numbers from `rpicam-hello
# --list-cameras`, not fixed hardware slots -- they can renumber any time a
# camera is added/removed/reseated, so re-check before trusting these.
MAIN_CAM="${MAIN_CAM:-0}"
INSET_CAM="${INSET_CAM:-1}"

MAIN_WIDTH="${MAIN_WIDTH:-1280}"
MAIN_HEIGHT="${MAIN_HEIGHT:-720}"

# INSET_CAP_* is what the inset camera actually captures at -- kept at a
# real supported sensor mode (see `rpicam-hello --list-cameras`) rather
# than the small on-screen PiP size, because requesting an arbitrary small
# raw YUV420 resolution directly (e.g. 320x180) risks a row-stride/padding
# mismatch between what rpicam-vid actually outputs and what ffmpeg's
# rawvideo demuxer is told to expect -- corrupts every frame after the
# first into unreadable blocks (confirmed on hardware). ffmpeg's own
# `scale` filter (below) does the actual downscale to
# INSET_WIDTH/INSET_HEIGHT instead.
INSET_CAP_WIDTH="${INSET_CAP_WIDTH:-640}"
INSET_CAP_HEIGHT="${INSET_CAP_HEIGHT:-480}"
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
MAIN_FIFO="${RUN_DIR}/main.yuv"
INSET_FIFO="${RUN_DIR}/inset.yuv"

MAIN_PID=""
INSET_PID=""
FFMPEG_PID=""
SWAPPED=0
SWAP_REQUESTED=0
STOPPING=0

stop_session() {
  [ -n "${FFMPEG_PID}" ] && kill "${FFMPEG_PID}" 2>/dev/null
  [ -n "${MAIN_PID}" ] && kill "${MAIN_PID}" 2>/dev/null
  [ -n "${INSET_PID}" ] && kill "${INSET_PID}" 2>/dev/null
  [ -n "${FFMPEG_PID}" ] && wait "${FFMPEG_PID}" 2>/dev/null
  [ -n "${MAIN_PID}" ] && wait "${MAIN_PID}" 2>/dev/null
  [ -n "${INSET_PID}" ] && wait "${INSET_PID}" 2>/dev/null
  rm -f "${MAIN_FIFO}" "${INSET_FIFO}"
  MAIN_PID=""; INSET_PID=""; FFMPEG_PID=""
}

final_cleanup() {
  stop_session
  rm -rf "${RUN_DIR}"
  rm -f "${PIDFILE}"
}
trap final_cleanup EXIT
trap 'STOPPING=1' INT TERM
trap 'SWAP_REQUESTED=1' USR1

while [ "${STOPPING}" -eq 0 ]; do
  if [ "${SWAPPED}" -eq 0 ]; then
    EFF_MAIN="${MAIN_CAM}"; EFF_INSET="${INSET_CAM}"
  else
    EFF_MAIN="${INSET_CAM}"; EFF_INSET="${MAIN_CAM}"
  fi

  mkfifo "${MAIN_FIFO}" "${INSET_FIFO}"

  # rpicam-vid blocks opening a FIFO for write until something opens it for
  # read, so starting these before ffmpeg is safe -- no manual wait needed.
  rpicam-vid -t 0 --camera "${EFF_MAIN}" --codec yuv420 \
    --width "${MAIN_WIDTH}" --height "${MAIN_HEIGHT}" --framerate "${FRAMERATE}" \
    -o "${MAIN_FIFO}" &
  MAIN_PID=$!

  rpicam-vid -t 0 --camera "${EFF_INSET}" --codec yuv420 \
    --width "${INSET_CAP_WIDTH}" --height "${INSET_CAP_HEIGHT}" --framerate "${FRAMERATE}" \
    -o "${INSET_FIFO}" &
  INSET_PID=$!

  ffmpeg -loglevel warning \
    -f rawvideo -pix_fmt yuv420p -s "${MAIN_WIDTH}x${MAIN_HEIGHT}" -r "${FRAMERATE}" -i "${MAIN_FIFO}" \
    -f rawvideo -pix_fmt yuv420p -s "${INSET_CAP_WIDTH}x${INSET_CAP_HEIGHT}" -r "${FRAMERATE}" -i "${INSET_FIFO}" \
    -filter_complex "[1:v]scale=${INSET_WIDTH}:${INSET_HEIGHT}[pip];[0:v][pip]overlay=W-w-${INSET_MARGIN}:H-h-${INSET_MARGIN}[out]" \
    -map "[out]" -c:v libx264 -preset ultrafast -tune zerolatency -b:v "${BITRATE}" \
    -f rtsp -rtsp_transport tcp "rtsp://${MEDIAMTX_HOST}:${MEDIAMTX_PORT}/${STREAM_PATH}" &
  FFMPEG_PID=$!

  # Wait for either a swap request or ffmpeg exiting on its own (a real
  # error -- rpicam-vid crashing, MediaMTX unreachable, etc).
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
    sleep 0.2
  done

  stop_session

  # Crash-loop guard: only pause before restarting if ffmpeg exited on its
  # own (not a deliberate swap or a stop request), so a real, persistent
  # failure doesn't spin the loop instantly forever.
  if [ "${CRASHED}" -eq 1 ] && [ "${STOPPING}" -eq 0 ]; then
    sleep 2
  fi
done
