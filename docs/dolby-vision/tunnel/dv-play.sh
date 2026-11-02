#!/bin/sh
# Plays a Dolby Vision profile 5 or 8 source through the tunnel on tty2 with
# the patched mpv, then returns to gamescope on tty1. The exit trap clears the
# tunnel even when mpv dies, so gamescope's commits are not refused.
# Usage: dv-play.sh seconds hz source [mpv options]. Run as root.
# hz is the mode's refresh as mpv's --drm-mode takes it, e.g. 24 or 23.98.
D=/home/deck/dev/dvmpv
DV=/home/deck/dev/dv
SECS=$1
HZ=$2
SRC=$3
shift 3
back() {
  $DV/dvframe reset
  chvt 1
}
trap back EXIT
trap 'exit 1' INT TERM HUP
chvt 2
sleep 1
# The ssh terminal is not tty2, so mpv takes commands on its IPC socket.
XDG_RUNTIME_DIR=/run/user/1000 LD_LIBRARY_PATH=$D/lib $D/mpv/build/mpv \
  --no-config --vo=gpu-next --gpu-api=opengl --gpu-context=drm \
  --drm-dvbridge --drm-mode=3840x2160@"$HZ" \
  --hwdec=vaapi --length="$SECS" --input-ipc-server=/tmp/dvmpv.sock \
  --msg-level=vo=v --log-file=$D/play.log \
  "$@" "$SRC"
echo "mpv exit $?"
