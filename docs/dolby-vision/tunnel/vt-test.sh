#!/bin/sh
# VT handoff test: leave gamescope's tty1 for tty2, take DRM master there with modetest,
# show its test pattern for a few seconds, and switch back. Checks after each round that
# gamescope is the same process and logind holds master again for it.
# Usage: vt-test.sh [rounds] [hold seconds]. Run as root.
N=${1:-1}
HOLD=${2:-4}
CONN=$(modetest -M amdgpu -c 2>/dev/null | awk '$3 == "connected" && $4 ~ /^HDMI/ {print $1; exit}')
CRTC=$(modetest -M amdgpu -p 2>/dev/null | sed -n '/^CRTCs/,/^Planes/p' | awk '$1 ~ /^[0-9]+$/ && $2 != 0 {print $1; exit}')
MODE=$(modetest -M amdgpu -p 2>/dev/null | sed -n '/^CRTCs/,/^Planes/p' | awk '$1 ~ /^[0-9]+$/ && $2 != 0 {gsub(/[()]/, "", $4); print $4; exit}')
CLIENTS=$(ls -d /sys/kernel/debug/dri/0000:*/clients | head -1)
GS=$(pgrep -f '^gamescope ' | head -1)
echo "connector $CONN, crtc $CRTC, mode $MODE, gamescope pid $GS"
[ -n "$CONN" ] && [ -n "$CRTC" ] && [ -n "$MODE" ] && [ -n "$GS" ] || { echo "setup lookup failed"; exit 1; }

logind_master() { awk '$1 == "systemd-logind" {print $4; exit}' "$CLIENTS"; }

fail=0
i=1
while [ $i -le $N ]; do
  since=$(date '+%Y-%m-%d %H:%M:%S')
  chvt 2
  sleep 1
  away=$(logind_master)
  sleep $HOLD | modetest -M amdgpu -s "$CONN@$CRTC:$MODE" >/tmp/vt-test.modetest 2>&1
  mt=$?
  chvt 1
  sleep 4
  back=$(logind_master)
  now=$(pgrep -f '^gamescope ' | head -1)
  errs=$(journalctl --since "$since" _COMM=gamescope-wl --no-pager -o cat 2>/dev/null | grep -ciE 'error|fail|lost|abort')
  ok=yes
  [ "$away" = n ] && [ $mt -eq 0 ] && [ "$back" = y ] && [ "$now" = "$GS" ] || ok=no
  [ $ok = yes ] || fail=$((fail + 1))
  echo "round $i: master away=$away modetest=$mt master back=$back gamescope=$now journal errors=$errs ok=$ok"
  [ $ok = yes ] || tail -5 /tmp/vt-test.modetest
  i=$((i + 1))
done
echo "active vt: $(cat /sys/class/tty/tty0/active), failed rounds: $fail of $N"
