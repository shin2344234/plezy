#!/usr/bin/python3 -I
# Runs dv-tunnel's play path with mpv's null video and audio outputs and
# without the VT switch or dvframe, so the IPC relay and its filter can be
# tested without anything on the TV. Run as root with requests on stdin.
# Usage: test-relay.py [dv-tunnel path]
import importlib.machinery
import subprocess
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/var/lib/dvtunnel/dv-tunnel"
h = importlib.machinery.SourceFileLoader("dv_tunnel", path).load_module()
real_run = subprocess.run


def run(args, **kwargs):
    if args[0] in ("chvt", h.DVFRAME):
        sys.stderr.write("skipped: " + " ".join(args) + "\n")
        return subprocess.CompletedProcess(args, 0)
    return real_run(args, **kwargs)


h.subprocess.run = run
h.time.sleep = lambda _: None
h.MPV_ARGS = ["--no-config", "--idle=yes", "--terminal=no", "--vo=null", "--ao=null",
              "--log-file=/tmp/test-relay.log"]
sys.argv = [path, "play", "24"]
sys.exit(h.main())
