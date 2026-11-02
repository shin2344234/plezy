#!/bin/sh
# Plays Sinners (profile 7 MEL), the Jellyfin 4K profile 5 clip and The Amateur
# (8.1) for 30 seconds each through the tunnel with the mpv master build, and
# keeps each run's log as play-<name>.log. Run as root.
D=/home/deck/dev/dvmpv
export MPV=$D/mpv-master/build/mpv
url() { awk -F'\t' -v n="$1" 'index(tolower($3), n) { print $4; exit }' /root/dvplex-list.tsv; }
run() {
  name=$1
  shift
  "$D/dv-play.sh" "$@" 2>&1 | grep -E 'mpv exit|FEL|Dropped' | grep -v -i token
  cp "$D/play.log" "$D/play-$name.log"
  sleep 3
}
run sinners 30 23.98 "$(url sinners)" --include=/root/dvplex.conf --start=900
run p5 30 60 "$D/samples/Test Jellyfin 4K DV P5.mp4"
run amateur 30 23.98 "$(url amateur)" --include=/root/dvplex.conf --start=900
