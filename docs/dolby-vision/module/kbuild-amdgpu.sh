#!/bin/sh
# Runs inside the kbuild distrobox. Builds amdgpu.ko as an external module
# against the prepared tree. Usage: kbuild-amdgpu.sh <log name>
set -e
DV=/home/deck/dev/dv
export PATH=$DV/gcc161/usr/bin:$PATH
export KBUILD_BUILD_HOST=archlinux KBUILD_BUILD_USER=linux-neptune-72
cd "$DV/src"
make -j16 CC=gcc HOSTCC=gcc KBUILD_MODPOST_WARN=1 M=drivers/gpu/drm/amd/amdgpu modules > "$DV/$1.log" 2>&1
echo "exit $?" >> "$DV/$1.log"
