#!/bin/bash
# Builds libplacebo v7.387.0, the first release mpv's FEL support accepts, as a
# static library in its own prefix. shaderc and lcms2 still come from the
# libmpv window prefix, whose libplacebo 7.360.1 stays as it is for Plezy.
# The options match mpv-build's Linux driver with Vulkan on. Run inside
# plezy-build.
set -euo pipefail

P=/home/deck/dev/plezy/build/libmpv-window/prefix
D=/home/deck/dev/dvmpv
LP="$D/lp-prefix"
export PKG_CONFIG_PATH="$P/lib/pkgconfig:$P/lib/x86_64-linux-gnu/pkgconfig"

cd "$D"
if [ ! -d libplacebo/.git ]; then
  git clone -q --branch v7.387.0 https://github.com/haasn/libplacebo.git libplacebo
fi
cd libplacebo
git checkout -q v7.387.0
git submodule update --init --recursive

rm -rf build
meson setup build \
  --prefix="$LP" \
  --default-library=static \
  -Dvulkan=enabled \
  -Dd3d11=disabled \
  -Ddemos=false \
  -Dtests=false
ninja -C build -j"$(nproc)"
ninja -C build install
# 7.387's convert.cc calls std::to_chars and std::from_chars on floats, and
# the static .pc doesn't say so, which leaves a C program like mpv unlinked.
pc=$(find "$LP" -name libplacebo.pc)
grep -q -- '-lstdc++' "$pc" || sed -i 's/^Libs: .*-lplacebo/& -lstdc++/' "$pc"
grep '^Libs:' "$pc"
pkg-config --modversion "$(find "$LP" -name libplacebo.pc)"
