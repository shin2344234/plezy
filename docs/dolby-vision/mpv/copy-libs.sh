#!/bin/bash
# Copies the libraries the SteamOS host lacks out of plezy-build.
set -euo pipefail
D=/home/deck/dev/dvmpv
mkdir -p "$D/lib"
for l in libunibreak.so.5 liblua5.2.so.0 libdisplay-info.so.1; do
  src=$(ldd "$D/mpv/build/mpv" | awk -v l="$l" '$1 == l { print $3 }')
  cp -L "$src" "$D/lib/$l"
done
ls -la "$D/lib"
