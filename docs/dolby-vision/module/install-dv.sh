#!/bin/sh
# Installs the patched amdgpu.ko.zst as an override in updates/, which depmod searches before
# the stock kernel/ tree. Takes effect at the next boot. Run as root.
set -e
VER=$(uname -r)
SRC=/home/deck/dev/dv/out/amdgpu.ko.zst
SUM=e4fc75a27df95e268b31dc732dac75a5fb2f87e0a01a7bd53e4516ac360b959a
DST=/usr/lib/modules/$VER/updates
echo "$SUM  $SRC" | sha256sum -c -
steamos-readonly disable
trap 'steamos-readonly enable' EXIT
mkdir -p $DST
cp $SRC $DST/amdgpu.ko.zst
depmod -a $VER
echo "amdgpu now resolves to: $(modinfo -k $VER -n amdgpu)"
echo "Reboot to load it."
