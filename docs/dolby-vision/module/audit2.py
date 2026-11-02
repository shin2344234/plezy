"""Checks where each hunk of the cumulative port landed.

Replays port2/all.diff at fuzz 0 on copies of the 7.2 files, then compares, for every applied
hunk, the function enclosing its landing line with the function in the 7.3 hunk header.
7.2 names that differ only by the amdgpu_dm_ prefix count as the same function.
Usage: python3 -I audit2.py
"""
import re
import subprocess
import tempfile
from pathlib import Path

DV = Path("/home/deck/dev/dv")
DIFF = DV / "port2/all.diff"
GIT = ["git", "-c", "safe.directory=*", "-C", str(DV / "src")]
FUNC = re.compile(r"^(?:[A-Za-z_]\w*\s+)*\**\s*([A-Za-z_]\w*)\s*\(")


def name_of(text):
    m = FUNC.match(text.strip())
    return m.group(1) if m else text.strip()[:40]


def enclosing(lines, lineno):
    for i in range(min(lineno, len(lines)) - 1, -1, -1):
        s = lines[i]
        if s and not s[0].isspace() and s[0] not in "{}#/*" and "(" in s and not s.rstrip().endswith(";"):
            return name_of(s)
    return "?"


def same(a, b):
    strip = lambda s: re.sub(r"^(amdgpu_dm_|STATIC_IFN_KUNIT\s+)", "", s)
    return a == b or strip(a) == strip(b)


def main():
    text = DIFF.read_text()
    paths = sorted(set(re.findall(r"^\+\+\+ b/(\S+)", text, re.M)))
    heads, path, n = [], None, 0
    for line in text.splitlines():
        if line.startswith("+++ b/"):
            path, n = line[6:], 0
        elif line.startswith("@@"):
            n += 1
            heads.append((path, n, line.split("@@", 2)[2].strip()))
    with tempfile.TemporaryDirectory() as tmp:
        for p in paths:
            r = subprocess.run(GIT + ["show", f"7.2.7-valve2:{p}"], capture_output=True, text=True)
            if r.returncode == 0:
                (Path(tmp) / p).parent.mkdir(parents=True, exist_ok=True)
                (Path(tmp) / p).write_text(r.stdout)
        log = subprocess.run(["patch", "-p1", "-F0", "-r", "-", "--no-backup-if-mismatch", "-i", str(DIFF)],
                             cwd=tmp, capture_output=True, text=True).stdout
        sections, cur = [], None
        for line in log.splitlines():
            m = re.match(r"patching file (\S+)", line)
            if m:
                cur = m.group(1)
                sections.append(cur)
        # hunk headers per diff section, in order
        sec_heads, idx = [], -1
        last = None
        for p, n, ctx in heads:
            if n == 1:
                sec_heads.append([])
            sec_heads[-1].append(ctx)
        sec = -1
        bad = 0
        for line in log.splitlines():
            if line.startswith("patching file"):
                sec += 1
                cur = line.split()[2]
                lines = (Path(tmp) / cur).read_text().splitlines() if (Path(tmp) / cur).exists() else []
                continue
            m = re.match(r"Hunk #(\d+) succeeded at (\d+)", line)
            if not m:
                continue
            k, at = int(m.group(1)), int(m.group(2))
            want = name_of(sec_heads[sec][k - 1]) if sec_heads[sec][k - 1] else ""
            got = enclosing(lines, at + 3)
            if want and not same(want, got):
                bad += 1
                print(f"{cur} hunk {k} at {at}: 7.3 '{want}', landed in '{got}'")
        print(f"{bad} hunks to look at")


main()
