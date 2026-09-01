#!/usr/bin/env bash
# Single-camera capture + software H.264 encode, pushed to a local MediaMTX
# instance over RTSP. No compositor needed with one camera — use
# pip_stream.sh instead once a second camera is added for the PiP layout.
set -euo pipefail

# camera-name is libcamera's own ID, not an arbitrary label — run
# `libcamera-hello --list-cameras` (or `rpicam-hello --list-cameras`) on the
# Pi and set this to the real ID printed there before running this script.
CAM="${CAM:-cam0}"

WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FRAMERATE="${FRAMERATE:-20}"
BITRATE="${BITRATE:-2500}"

MEDIAMTX_HOST="${MEDIAMTX_HOST:-127.0.0.1}"
MEDIAMTX_PORT="${MEDIAMTX_PORT:-8554}"
STREAM_PATH="${STREAM_PATH:-robot}"

exec gst-launch-1.0 -e \
  libcamerasrc camera-name="${CAM}" \
  ! "video/x-raw,width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE}/1" \
  ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast bitrate="${BITRATE}" key-int-max=30 \
  ! rtspclientsink location="rtsp://${MEDIAMTX_HOST}:${MEDIAMTX_PORT}/${STREAM_PATH}"
