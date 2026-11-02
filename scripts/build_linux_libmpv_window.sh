#!/usr/bin/env bash
set -euo pipefail

# Builds the Linux libmpv for the X11 window video mode.
#
# Upstream's libmpv comes from edde746/mpv-build with Vulkan and X11 turned
# off, because the Wayland plane renders through OpenGL. The window mode needs
# mpv's own vo=gpu-next window instead: Vulkan, so gamescope's WSI layer can
# hand the swapchain an HDR10 colour space, X11, because gamescope only feeds
# HDR to X11 surfaces, and SDL2 gamepad input, because the window holds focus
# and Plezy ignores the pad while it does.
#
# This clones mpv-build at the commit mpv-build.lock.json pins, flips those
# meson options in its Linux driver, and runs the driver. Nothing else about
# the build changes. Run it on Ubuntu 24.04 with mpv-build's container
# packages plus libvulkan-dev and libsdl2-dev installed.
#
# Environment:
#   WORK_DIR  where mpv-build is cloned and built (default build/libmpv-window)
#   PREFIX    install prefix (default $WORK_DIR/prefix)
#   JOBS      forwarded to the driver

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(realpath -m "${WORK_DIR:-$REPO_ROOT/build/libmpv-window}")"
prefix="$(realpath -m "${PREFIX:-$work_dir/prefix}")"

read -r repo commit < <(python3 - "$REPO_ROOT/mpv-build.lock.json" <<'PY'
import json
import sys

lock = json.load(open(sys.argv[1]))
print(lock["repo"], lock["commit"])
PY
)

src="$work_dir/mpv-build"
if [ ! -d "$src/.git" ]; then
  git clone -q "https://github.com/$repo.git" "$src"
fi
git -C "$src" fetch -q origin "$commit"
git -C "$src" checkout -q --force "$commit"

driver="$src/platforms/linux/build.sh"
# libplacebo and mpv each carry one -Dvulkan=disabled; mpv carries -Dx11.
sed -i \
  -e 's/-Dvulkan=disabled/-Dvulkan=enabled/' \
  -e 's/-Dx11=disabled$/-Dx11=enabled -Dsdl2-gamepad=enabled/' \
  "$driver"
if [ "$(grep -c -- '-Dvulkan=enabled' "$driver")" -ne 2 ] ||
  ! grep -q -- '-Dx11=enabled -Dsdl2-gamepad=enabled' "$driver"; then
  echo "mpv-build's Linux driver no longer has the options this script flips" >&2
  exit 1
fi

src_dir="$work_dir/src"
rm -rf "$src_dir"
cd "$src"
SRCDIR="$src_dir" PREFIX="$prefix" bash "$driver"
echo "libmpv for the window mode is in $prefix"
