#!/usr/bin/env bash
# Dual-camera PiP capture + software H.264 encode, pushed to a local MediaMTX
# instance over RTSP. Pi 5 has no hardware H.264 encoder, so this is all CPU
# (x264enc) — keep resolution/framerate modest (see CLAUDE.md).
set -euo pipefail

# camera-name values are libcamera's own IDs, not arbitrary labels — run
# `libcamera-hello --list-cameras` (or `rpicam-hello --list-cameras`) on the
# Pi and set these to the real IDs printed there before running this script.
MAIN_CAM="${MAIN_CAM:-cam0}"
INSET_CAM="${INSET_CAM:-cam1}"

MAIN_WIDTH="${MAIN_WIDTH:-1280}"
MAIN_HEIGHT="${MAIN_HEIGHT:-720}"
INSET_WIDTH="${INSET_WIDTH:-320}"
INSET_HEIGHT="${INSET_HEIGHT:-180}"
FRAMERATE="${FRAMERATE:-20}"
BITRATE="${BITRATE:-2500}"

INSET_XPOS="${INSET_XPOS:-$((MAIN_WIDTH - INSET_WIDTH - 20))}"
INSET_YPOS="${INSET_YPOS:-$((MAIN_HEIGHT - INSET_HEIGHT - 20))}"

MEDIAMTX_HOST="${MEDIAMTX_HOST:-127.0.0.1}"
MEDIAMTX_PORT="${MEDIAMTX_PORT:-8554}"
STREAM_PATH="${STREAM_PATH:-robot}"

exec gst-launch-1.0 -e \
  compositor name=comp \
    sink_0::xpos=0 sink_0::ypos=0 sink_0::width="${MAIN_WIDTH}" sink_0::height="${MAIN_HEIGHT}" \
    sink_1::xpos="${INSET_XPOS}" sink_1::ypos="${INSET_YPOS}" sink_1::width="${INSET_WIDTH}" sink_1::height="${INSET_HEIGHT}" zorder=1 \
  ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast bitrate="${BITRATE}" key-int-max=30 \
  ! rtspclientsink location="rtsp://${MEDIAMTX_HOST}:${MEDIAMTX_PORT}/${STREAM_PATH}" \
  libcamerasrc camera-name="${MAIN_CAM}" ! "video/x-raw,width=${MAIN_WIDTH},height=${MAIN_HEIGHT},framerate=${FRAMERATE}/1" ! comp.sink_0 \
  libcamerasrc camera-name="${INSET_CAM}" ! "video/x-raw,width=${INSET_WIDTH},height=${INSET_HEIGHT},framerate=${FRAMERATE}/1" ! comp.sink_1
