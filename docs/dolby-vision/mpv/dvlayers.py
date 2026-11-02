#!/usr/bin/env python3
# Shows how a profile 7 title in /root/dvplex-list.tsv carries its layers: the
# video streams in the container, the HEVC NAL types of a few seconds of the
# first one, and, when the EL rides in-band as NAL 63, the EL's own stream
# info after unwrapping it. Run as root on the UM870.
# Usage: dvlayers.py "title substring" [seconds into the movie] [seconds to read]
import collections
import json
import os
import subprocess
import sys

name = sys.argv[1]
start = sys.argv[2] if len(sys.argv) > 2 else "900"
length = sys.argv[3] if len(sys.argv) > 3 else "4"
header = open("/root/dvplex.conf").read().split("=", 1)[1].strip() + "\r\n"
url = next(l.split("\t")[3].strip() for l in open("/root/dvplex-list.tsv")
           if name.lower() in l.split("\t")[2].lower())
work = "/root/dvlayers"
os.makedirs(work, exist_ok=True)

probe = subprocess.run(
    ["ffprobe", "-v", "error", "-headers", header, "-show_streams", "-select_streams", "v",
     "-show_entries", "stream=index,codec_name,width,height,r_frame_rate:stream_side_data",
     "-of", "json", url], capture_output=True, text=True, timeout=120)
for s in json.loads(probe.stdout)["streams"]:
    cfg = next((d for d in s.get("side_data_list", []) if "DOVI" in d.get("side_data_type", "")), {})
    print(f"stream {s['index']}: {s['codec_name']} {s['width']}x{s['height']} {s['r_frame_rate']},"
          f" profile {cfg.get('dv_profile')} bl {cfg.get('bl_present_flag')}"
          f" el {cfg.get('el_present_flag')} rpu {cfg.get('rpu_present_flag')}")

raw = os.path.join(work, "bl.hevc")
subprocess.run(["ffmpeg", "-v", "error", "-y", "-headers", header, "-ss", start, "-i", url,
                "-map", "0:v:0", "-c", "copy", "-bsf:v", "hevc_mp4toannexb", "-t", length,
                "-f", "hevc", raw], check=True, timeout=300)
data = open(raw, "rb").read()


def nals(buf):
    i = buf.find(b"\0\0\1")
    while i >= 0:
        j = buf.find(b"\0\0\1", i + 3)
        end = len(buf) if j < 0 else j
        # A four-byte start code leaves a zero at the end of the previous NAL.
        yield buf[i + 3:end].rstrip(b"\0") if j >= 0 else buf[i + 3:end]
        i = j


types = collections.Counter()
inner = collections.Counter()
el = bytearray()
for n in nals(data):
    t = (n[0] >> 1) & 0x3f
    types[t] += 1
    if t == 63 and len(n) > 2:
        # The EL NAL follows the two-byte NAL 63 header.
        inner[(n[2] >> 1) & 0x3f] += 1
        el += b"\0\0\0\1" + n[2:]
print(f"{len(data)} bytes, NAL types {dict(sorted(types.items()))}")
print(f"inside NAL 63: {dict(sorted(inner.items()))}")
if el:
    path = os.path.join(work, "el.hevc")
    open(path, "wb").write(el)
    out = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-count_frames",
                          "-show_entries", "stream=codec_name,profile,width,height,pix_fmt,"
                          "nb_read_frames", "-of", "json", path],
                         capture_output=True, text=True, timeout=120)
    print("EL:", json.loads(out.stdout)["streams"][0], out.stderr.strip()[-300:])
