#!/bin/sh
# Removes the patched amdgpu override so the stock module loads at the next boot. Run as root.
set -e
VER=$(uname -r)
DST=/usr/lib/modules/$VER/updates
steamos-readonly disable
trap 'steamos-readonly enable' EXIT
rm -f $DST/amdgpu.ko.zst
rmdir --ignore-fail-on-non-empty $DST 2>/dev/null || true
depmod -a $VER
echo "amdgpu now resolves to: $(modinfo -k $VER -n amdgpu)"
echo "Reboot to load the stock module."
