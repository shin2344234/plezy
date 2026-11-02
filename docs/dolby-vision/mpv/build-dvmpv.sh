#!/bin/bash
# Builds the mpv CLI with the Dolby Vision tunnel against the libmpv window
# prefix (static FFmpeg n8.0.1, libplacebo 7.360.1). Run inside plezy-build.
set -euo pipefail

P=/home/deck/dev/plezy/build/libmpv-window/prefix
export PKG_CONFIG_PATH="$P/lib/pkgconfig:$P/lib/x86_64-linux-gnu/pkgconfig"
cd /home/deck/dev/dvmpv/mpv

if [ ! -f build/build.ninja ]; then
  meson setup build \
    --prefix=/home/deck/dev/dvmpv/prefix \
    -Dlibmpv=false \
    -Dcplayer=true \
    -Dgpl=true \
    -Dbuild-date=false \
    -Dlua=enabled \
    -Djavascript=disabled \
    -Dcplugins=disabled \
    -Dmanpage-build=disabled \
    -Djack=disabled \
    -Dvulkan=enabled \
    -Dgl=enabled \
    -Degl=enabled \
    -Ddrm=enabled \
    -Dgbm=enabled \
    -Degl-drm=enabled \
    -Dvaapi=enabled \
    -Dvaapi-drm=enabled \
    -Dalsa=enabled \
    -Dpulse=enabled \
    -Dpipewire=enabled \
    -Dwayland=disabled \
    -Dx11=disabled \
    -Dvdpau=disabled \
    -Dcuda-hwaccel=disabled \
    -Dcuda-interop=disabled \
    -Dsdl2-gamepad=enabled
fi

ninja -C build -j"$(nproc)"
ls -la build/mpv
