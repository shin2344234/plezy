#!/bin/sh
# Plays part of a Plex title headless with the mpv master build and reports
# what the FEL path did: the EL split, the EL decoder, the pairing, and any
# BL frame shown alone. Nothing goes to the screen. Run as root.
# Usage: dv-fel-check.sh "title substring" [start seconds] [seconds] [hwdec]
D=/home/deck/dev/dvmpv
NAME=$1
START=${2:-900}
SECS=${3:-20}
HWDEC=${4:-vaapi-copy}
LOG=$D/fel-check.log
URL=$(awk -F'\t' -v n="$NAME" 'index(tolower($3), tolower(n)) { print $4; exit }' /root/dvplex-list.tsv)
[ -n "$URL" ] || { echo "no title matches $NAME" >&2; exit 1; }
rm -f "$LOG"
XDG_RUNTIME_DIR=/run/user/1000 LD_LIBRARY_PATH=$D/lib "$D/mpv-master/build/mpv" \
  --no-config --include=/root/dvplex.conf --vo=null --ao=null --hwdec="$HWDEC" \
  --start="$START" --length="$SECS" -v --log-file="$LOG" "$URL" >/dev/null 2>&1
echo "mpv exit $?"
grep -i -E "splitter|dovi_split|el_pair|enhancement|emitting BL|stale EL|Using hardware decoding|hwdec|Dolby Vision" "$LOG" |
  grep -v -i "token" | sed 's/^\[ *[0-9.]*\]//' | sort | uniq -c | sort -rn | head -30
