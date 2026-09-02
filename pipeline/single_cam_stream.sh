#!/usr/bin/env bash
# Single-camera capture + software H.264 encode, pushed to a local MediaMTX
# instance over RTSP, via rpicam-vid's libav backend. No compositor needed
# with one camera — use pip_stream.sh instead once a second camera is added
# for the PiP layout (note: pip_stream.sh still uses the GStreamer approach
# below and needs the same rework — see CLAUDE.md).
#
# This deliberately does NOT use GStreamer's rtspclientsink: that element
# ships in GStreamer's Rust plugin set, which isn't packaged for Debian
# trixie (confirmed on real Pi 5 hardware — apt has no
# gstreamer1.0-plugins-rs, only unbuilt Rust source crates). rpicam-vid's
# built-in libav output sidesteps that entirely.
set -euo pipefail

# CAM is the numeric camera index from `rpicam-hello --list-cameras`
# (e.g. the "0" in "0 : ov5647 [...]"), not a libcamera ID string.
CAM="${CAM:-0}"

WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FRAMERATE="${FRAMERATE:-20}"
BITRATE="${BITRATE:-2500000}"  # bits per second

MEDIAMTX_HOST="${MEDIAMTX_HOST:-127.0.0.1}"
MEDIAMTX_PORT="${MEDIAMTX_PORT:-8554}"
STREAM_PATH="${STREAM_PATH:-robot}"

# --libav-video-codec is forced to libx264 (software): the libav backend's
# own default (h264_v4l2m2m) assumes a hardware V4L2 encoder that Pi 5
# doesn't have.
exec rpicam-vid -t 0 --camera "${CAM}" \
  --codec libav --libav-video-codec libx264 --libav-format rtsp --low-latency \
  --width "${WIDTH}" --height "${HEIGHT}" --framerate "${FRAMERATE}" \
  --bitrate "${BITRATE}" \
  -o "rtsp://${MEDIAMTX_HOST}:${MEDIAMTX_PORT}/${STREAM_PATH}"
