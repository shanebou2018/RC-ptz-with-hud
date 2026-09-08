#!/usr/bin/env bash
# Dual-camera PiP capture + composite + software H.264 encode, pushed to a
# local MediaMTX instance over RTSP.
#
# Built around the same RTSP push mechanism single_cam_stream.sh uses
# (ffmpeg's own libav RTSP muxer, confirmed working on this Pi) instead of
# GStreamer's compositor + rtspclientsink -- rtspclientsink isn't available
# on Debian trixie (see CLAUDE.md's "Video pipeline constraint" section).
#
# Camera roles (MAIN_CAM/INSET_CAM) are fixed for the life of this script --
# there is no live swap. An earlier version restarted just its ffmpeg stage
# on SIGUSR1 to swap roles while keeping both cameras running, but that
# proved unreliable on real hardware (MediaMTX didn't always release the
# old RTSP publish session before the new ffmpeg tried to reconnect,
# leaving the stream down until a full service restart). Swap the roles by
# setting MAIN_CAM/INSET_CAM and restarting the service instead.
set -euo pipefail

# Camera indices are libcamera's own numbers from `rpicam-hello
# --list-cameras`, not fixed hardware slots -- they can renumber any time a
# camera is added/removed/reseated, so re-check before trusting these.
MAIN_CAM="${MAIN_CAM:-0}"
INSET_CAM="${INSET_CAM:-1}"

# Both cameras capture at this same resolution; ffmpeg scales the inset
# down for its on-screen box (see INSET_WIDTH/INSET_HEIGHT). Height must be
# a multiple of 16 -- arbitrary small sizes like 180 aren't and corrupt the
# raw pipe (row-stride padding mismatch, see git history).
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

RUN_DIR="$(mktemp -d /tmp/pip_stream.XXXXXX)"
MAIN_FIFO="${RUN_DIR}/main.yuv"
INSET_FIFO="${RUN_DIR}/inset.yuv"
mkfifo "${MAIN_FIFO}" "${INSET_FIFO}"

MAIN_PID=""
INSET_PID=""
FFMPEG_PID=""

cleanup() {
  [ -n "${FFMPEG_PID}" ] && kill "${FFMPEG_PID}" 2>/dev/null
  [ -n "${MAIN_PID}" ] && kill "${MAIN_PID}" 2>/dev/null
  [ -n "${INSET_PID}" ] && kill "${INSET_PID}" 2>/dev/null
  [ -n "${FFMPEG_PID}" ] && wait "${FFMPEG_PID}" 2>/dev/null
  [ -n "${MAIN_PID}" ] && wait "${MAIN_PID}" 2>/dev/null
  [ -n "${INSET_PID}" ] && wait "${INSET_PID}" 2>/dev/null
  rm -rf "${RUN_DIR}"
}
trap cleanup EXIT INT TERM

# rpicam-vid blocks opening a FIFO for write until something opens it for
# read, so starting these before ffmpeg is safe -- no manual wait needed.
rpicam-vid -t 0 --camera "${MAIN_CAM}" --codec yuv420 \
  --width "${CAM_WIDTH}" --height "${CAM_HEIGHT}" --framerate "${FRAMERATE}" \
  -o "${MAIN_FIFO}" &
MAIN_PID=$!

rpicam-vid -t 0 --camera "${INSET_CAM}" --codec yuv420 \
  --width "${CAM_WIDTH}" --height "${CAM_HEIGHT}" --framerate "${FRAMERATE}" \
  -o "${INSET_FIFO}" &
INSET_PID=$!

ffmpeg -loglevel warning \
  -f rawvideo -pix_fmt yuv420p -s "${CAM_WIDTH}x${CAM_HEIGHT}" -r "${FRAMERATE}" -i "${MAIN_FIFO}" \
  -f rawvideo -pix_fmt yuv420p -s "${CAM_WIDTH}x${CAM_HEIGHT}" -r "${FRAMERATE}" -i "${INSET_FIFO}" \
  -filter_complex "[1:v]scale=${INSET_WIDTH}:${INSET_HEIGHT}[pip];[0:v][pip]overlay=W-w-${INSET_MARGIN}:H-h-${INSET_MARGIN}[out]" \
  -map "[out]" -c:v libx264 -preset ultrafast -tune zerolatency -b:v "${BITRATE}" \
  -f rtsp -rtsp_transport tcp "rtsp://${MEDIAMTX_HOST}:${MEDIAMTX_PORT}/${STREAM_PATH}" &
FFMPEG_PID=$!
wait "${FFMPEG_PID}"
