#!/bin/sh
# Ports the whole Hades series (v73 base..nocore) to the Valve 7.2 tree as one
# cumulative diff, so hunks anchor on upstream code only and never on code an
# earlier Hades patch added. 7.3 split amdgpu_dm.c, so the connector and
# freesync parts are pointed back at amdgpu_dm.c.
# Usage: port2.sh <fuzz> [apply]   (without "apply" it is a dry run)
DV=/home/deck/dev/dv
G="git -c safe.directory=*"
F=${1:-1}
OUT=$DV/port2
mkdir -p "$OUT"
cd "$DV/src" || exit 1
$G -C $DV/v73 diff $(cat $DV/v73.base) nocore -- . ':!*.rej' ':!drivers/gpu/drm/i915' \
    ':!drivers/video/hdmi.c' ':!include/linux/hdmi.h' \
  | sed -e 's#amdgpu_dm/amdgpu_dm_connector\.c#amdgpu_dm/amdgpu_dm.c#g' \
        -e 's#amdgpu_dm/amdgpu_dm_freesync\.c#amdgpu_dm/amdgpu_dm.c#g' \
  > "$OUT/all.diff"
if [ "$2" = apply ]; then
  $G checkout -q -f 7.2.7-valve2 2>/dev/null
  $G clean -qfd drivers include
  $G branch -D dv-port >/dev/null 2>&1
  $G checkout -q -b dv-port
  rm -f "$OUT"/*.rej
  patch -p1 -F$F --no-backup-if-mismatch -r "$OUT/all.rej" < "$OUT/all.diff" > "$OUT/apply-F$F.log" 2>&1
else
  patch -p1 -F$F --dry-run < "$OUT/all.diff" > "$OUT/dry-F$F.log" 2>&1
fi
LOG=$(ls -t "$OUT"/*F$F.log | head -1)
echo "F$F: $(grep -c FAILED $LOG) failed, $(grep -c 'with fuzz' $LOG) fuzzed, $(grep -c '^Hunk' $LOG) moved, $(grep -c '^@@' $OUT/all.diff) hunks"
