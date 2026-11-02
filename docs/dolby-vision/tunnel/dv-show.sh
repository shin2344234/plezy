#!/bin/sh
# Shows the static Dolby Vision test frame on tty2, then returns to gamescope on tty1.
# The exit trap clears the tunnel even when dvframe dies, so gamescope's commits are not refused.
# Usage: dv-show.sh [seconds] [hz]. Run as root.
DV=/home/deck/dev/dv
SECS=${1:-20}
HZ=${2:-24}
back() {
  $DV/dvframe reset
  chvt 1
}
trap back EXIT
trap 'exit 1' INT TERM HUP
chvt 2
sleep 1
$DV/dvframe show "$SECS" "$HZ"
echo "dvframe exit $?"
