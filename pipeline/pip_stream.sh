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
# hardware encoder), and pushes RTSP.
#
# NOT YET RUN ON HARDWARE with two cameras attached -- treat this as a
# first draft to test and iterate on, same as single_cam_stream.sh was.
set -euo pipefail

# Camera indices are libcamera's own numbers from `rpicam-hello
# --list-cameras`, not fixed hardware slots -- they can renumber any time a
# camera is added/removed/reseated, so re-check before trusting these.
MAIN_CAM="${MAIN_CAM:-0}"
INSET_CAM="${INSET_CAM:-1}"

MAIN_WIDTH="${MAIN_WIDTH:-1280}"
MAIN_HEIGHT="${MAIN_HEIGHT:-720}"
INSET_WIDTH="${INSET_WIDTH:-320}"
INSET_HEIGHT="${INSET_HEIGHT:-180}"
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
cleanup() {
  [ -n "${MAIN_PID}" ] && kill "${MAIN_PID}" 2>/dev/null || true
  [ -n "${INSET_PID}" ] && kill "${INSET_PID}" 2>/dev/null || true
  rm -rf "${RUN_DIR}"
}
trap cleanup EXIT INT TERM

# rpicam-vid blocks opening a FIFO for write until something opens it for
# read, so starting these before ffmpeg is safe -- no manual wait needed.
rpicam-vid -t 0 --camera "${MAIN_CAM}" --codec yuv420 \
  --width "${MAIN_WIDTH}" --height "${MAIN_HEIGHT}" --framerate "${FRAMERATE}" \
  -o "${MAIN_FIFO}" &
MAIN_PID=$!

rpicam-vid -t 0 --camera "${INSET_CAM}" --codec yuv420 \
  --width "${INSET_WIDTH}" --height "${INSET_HEIGHT}" --framerate "${FRAMERATE}" \
  -o "${INSET_FIFO}" &
INSET_PID=$!

# No `exec` here deliberately -- it would replace this shell (and its EXIT
# trap) with ffmpeg, leaking the two rpicam-vid processes once ffmpeg exits.
ffmpeg -loglevel warning \
  -f rawvideo -pix_fmt yuv420p -s "${MAIN_WIDTH}x${MAIN_HEIGHT}" -r "${FRAMERATE}" -i "${MAIN_FIFO}" \
  -f rawvideo -pix_fmt yuv420p -s "${INSET_WIDTH}x${INSET_HEIGHT}" -r "${FRAMERATE}" -i "${INSET_FIFO}" \
  -filter_complex "[0:v][1:v]overlay=W-w-${INSET_MARGIN}:H-h-${INSET_MARGIN}[out]" \
  -map "[out]" -c:v libx264 -preset ultrafast -tune zerolatency -b:v "${BITRATE}" \
  -f rtsp -rtsp_transport tcp "rtsp://${MEDIAMTX_HOST}:${MEDIAMTX_PORT}/${STREAM_PATH}"
