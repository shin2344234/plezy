#!/bin/sh
# Installs the tunnel helper for Plezy into /var/lib/dvtunnel, owned by root,
# with copies of the mpv master build, its libraries and dvframe. Root runs
# these files, so none of them may stay writable by deck. /var survives
# SteamOS updates. Also installs the sudoers rule. Run as root from the folder
# that holds dv-tunnel, input.conf and dvtunnel.sudoers.
set -eu
D=/home/deck/dev/dvmpv
DV=/home/deck/dev/dv
T=/var/lib/dvtunnel
S=$(cd "$(dirname "$0")" && pwd)

visudo -c -f "$S/dvtunnel.sudoers"
install -d -o root -g root -m 0755 "$T" "$T/lib"
install -o root -g root -m 0755 "$D/mpv-master/build/mpv" "$T/mpv"
install -o root -g root -m 0644 "$D"/lib/*.so* "$T/lib/"
install -o root -g root -m 0755 "$DV/dvframe" "$T/dvframe"
install -o root -g root -m 0755 "$S/dv-tunnel" "$T/dv-tunnel"
install -o root -g root -m 0644 "$S/input.conf" "$T/input.conf"
install -o root -g root -m 0440 "$S/dvtunnel.sudoers" /etc/sudoers.d/zz-dvtunnel
ls -l "$T" /etc/sudoers.d/zz-dvtunnel
