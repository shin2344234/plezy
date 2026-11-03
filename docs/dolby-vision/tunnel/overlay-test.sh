#!/bin/sh
# Checks that UI drawn with overlay-add survives the Dolby Vision pack pass.
# Plays the profile 5 sample through dv-play.sh and, over mpv's IPC socket,
# shows the test overlay at 203 cd/m2 from 6 s, at 100 cd/m2 from 14 s, and
# removes it at 22 s. The sample runs 30 s. Run as root.
D=/home/deck/dev/dvmpv
DV=/home/deck/dev/dv
SOCK=/tmp/dvmpv.sock
OV=/tmp/overlay-test.bgra
python3 -I "$DV/make-overlay.py" "$OV"
send() {
  echo "$1" | socat - UNIX-CONNECT:$SOCK | grep -v -i token
}
add() {
  send '{"command": {"name": "overlay-add", "id": 0, "x": 0, "y": 0, "file": "'$OV'", "offset": 0, "fmt": "bgra", "w": 1920, "h": 1080, "stride": 7680, "dw": 3840, "dh": 2160, "max_luma": '$1'}}'
}
(
  sleep 6
  echo "overlay at 203 cd/m2"
  add 203
  sleep 8
  echo "overlay at 100 cd/m2"
  add 100
  sleep 8
  echo "overlay removed"
  send '{"command": ["overlay-remove", 0]}'
) &
MPV=$D/mpv-master/build/mpv "$D/dv-play.sh" 28 60 "$D/samples/Test Jellyfin 4K DV P5.mp4" --osd-level=0
wait
grep -E "overlay|Dropped|tunnel|error" $D/play.log | grep -v -i token | tail -15
