#!/bin/bash
# Builds dvtest against the same static FFmpeg as the patched mpv. Run inside
# plezy-build.
set -euo pipefail
P=/home/deck/dev/plezy/build/libmpv-window/prefix
export PKG_CONFIG_PATH="$P/lib/pkgconfig:$P/lib/x86_64-linux-gnu/pkgconfig"
D=/home/deck/dev/dvmpv
cc -O2 -Wall -o "$D/dvtest" "$D/dvtest.c" -I"$D/mpv/video/out" \
  $(pkg-config --cflags libavformat libavcodec libavutil) \
  $(pkg-config --static --libs libavformat libavcodec libavutil) -lm
ls -la "$D/dvtest"
