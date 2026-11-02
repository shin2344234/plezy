#!/bin/bash
# Builds the mpv CLI with the Dolby Vision tunnel from mpv master, which has
# profile 7 FEL, against libplacebo 7.387.0 from build-libplacebo.sh and
# FFmpeg n8.0.1 with dovi_split from build-ffmpeg.sh. The rest comes from the
# libmpv window prefix, through a copy without its own libplacebo, FFmpeg and
# libmpv, since its include directory would otherwise put the old headers
# ahead of the new ones. Vulkan is off because mpv master wants Vulkan headers
# 1.4.309 and the container has 1.3.275; the tunnel uses the EGL context.
# The first run clones mpv at the pinned commit and applies
# dvbridge-master.patch, which must sit next to this script. Run inside
# plezy-build. Pass setup to configure the build again from scratch.
set -euo pipefail

COMMIT=a687796d9d0efded1787d497167facd462b8f2ee
P=/home/deck/dev/plezy/build/libmpv-window/prefix
D=/home/deck/dev/dvmpv
LP="$D/lp-prefix"
FF="$D/ff-prefix"
BP="$D/base-prefix"
export PKG_CONFIG_PATH="$LP/lib/x86_64-linux-gnu/pkgconfig:$LP/lib/pkgconfig:$FF/lib/pkgconfig:$BP/lib/pkgconfig:$BP/lib/x86_64-linux-gnu/pkgconfig"

if [ ! -d "$BP" ]; then
  cp -a "$P" "$BP"
  rm -rf "$BP"/include/{libplacebo,libav*,libsw*,mpv}
  rm -f "$BP"/lib/{libav*,libsw*}.a "$BP"/lib/pkgconfig/{libav*,libsw*}.pc \
    "$BP"/lib/x86_64-linux-gnu/{libplacebo.a,libmpv.so*} \
    "$BP"/lib/x86_64-linux-gnu/pkgconfig/{libplacebo,mpv}.pc
  grep -rl "$P" "$BP" --include='*.pc' | xargs sed -i "s|$P|$BP|g"
fi

cd "$D"
if [ ! -d mpv-master/.git ]; then
  git init -q mpv-master
  git -C mpv-master fetch -q --depth 1 https://github.com/mpv-player/mpv.git "$COMMIT"
  git -C mpv-master checkout -q FETCH_HEAD
  git -C mpv-master apply "$D/dvbridge-master.patch"
fi
cd mpv-master

if [ ! -f build/build.ninja ] || [ "${1:-}" = setup ]; then
  rm -rf build
  meson setup build \
    --prefix="$D/prefix" \
    -Dlibmpv=false \
    -Dcplayer=true \
    -Dgpl=true \
    -Dbuild-date=false \
    -Dlua=enabled \
    -Djavascript=disabled \
    -Dcplugins=disabled \
    -Dmanpage-build=disabled \
    -Djack=disabled \
    -Dvulkan=disabled \
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
