#!/bin/sh
# Builds dvframe. Run inside plezy-build.
set -e
cd "$(dirname "$0")"
gcc -O2 -Wall -o dvframe dvframe.c $(pkg-config --cflags --libs libdrm)
echo built
