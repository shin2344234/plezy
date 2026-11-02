#!/bin/sh
# Plays the Jellyfin 4K profile 5 clip for 30 seconds through the tunnel and
# reads mpv's per-pass GPU timings from the IPC socket 15 seconds in, to show
# where a build spends its frame time. Run as root.
# Usage: dv-passes.sh label [mpv binary]
D=/home/deck/dev/dvmpv
LABEL=$1
export MPV=${2:-$D/mpv/build/mpv}
OUT=$D/passes-$LABEL.json
rm -f "$OUT"
"$D/dv-play.sh" 30 60 "$D/samples/Test Jellyfin 4K DV P5.mp4" > "$D/passes-$LABEL.out" 2>&1 &
sleep 15
echo '{"command": ["get_property", "vo-passes"]}' | socat - /tmp/dvmpv.sock > "$OUT"
wait
grep -E 'mpv exit|Dropped' "$D/passes-$LABEL.out" | tail -2
python3 - "$OUT" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))["data"]
for kind in ("fresh", "redraw"):
    passes = data.get(kind) or []
    total = sum(p["avg"] for p in passes)
    print(f"{kind}: {len(passes)} passes, {total / 1e6:.2f} ms avg in all")
    for p in passes:
        print(f"  {p['avg'] / 1e6:6.2f} ms avg {p['peak'] / 1e6:6.2f} ms peak  {p['desc']}")
EOF
