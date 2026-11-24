#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Update a Seedsow save that already has seedsow-semi-untethered, over the launcher's HTTP server.

On the console: start Seedsow on the user with the exploit save and press Y in the launcher (HTTP
server, port 8080). Then, on the PC, after build.py:

  python3 upload_save.py SWITCH-IP [--dir out/save] [--port 8080] [--dry-run]

It sends every file in out/save/ except:
  - the launcher's protected files (core.lua, http.lua, inject.lua, inject.iet, proggy.ttf,
    save9999.dat, saveg.dat, system.dat): the server refuses them, and the save already has them;
  - seedswap.nro: too big for the server. Copy out/sd/ to the SD card instead; it has
    switch/seedswap.nro.
inject2.lua (the launcher menu) goes last, so the new menu only appears once everything else is in.
Each file is one PUT /save?path=<name>; the server writes it and commits the save.
"""
import argparse
import sys
import urllib.error
import urllib.request
from pathlib import Path

PROTECTED = {"core.lua", "http.lua", "inject.lua", "inject.iet", "proggy.ttf",
             "save9999.dat", "saveg.dat", "system.dat"}
TOO_BIG = {"seedswap.nro"}
BODY_CAP = 0x40000 - 0x1000      # http.lua's limit
LAST = "inject2.lua"


def request(method, url, data=None, timeout=60):
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/octet-stream")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("switch_ip", help="the Switch 2's IP address (the launcher shows it after Y)")
    ap.add_argument("--dir", default=str(Path(__file__).resolve().parent / "out" / "save"),
                    help="the save files (default: out/save next to this script)")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--dry-run", action="store_true", help="list what would be sent, send nothing")
    a = ap.parse_args(argv)

    src = Path(a.dir)
    if not src.is_dir():
        sys.exit("%s not found: run build.py first" % src)
    files = sorted(p for p in src.iterdir() if p.is_file() and p.name not in PROTECTED | TOO_BIG)
    files.sort(key=lambda p: p.name == LAST)
    if not any(p.name == LAST for p in files):
        sys.exit("%s has no %s: is this the Seedsow save from build.py?" % (src, LAST))
    big = [p.name for p in files if p.stat().st_size > BODY_CAP]
    if big:
        sys.exit("too big for the launcher's server: " + ", ".join(big))

    base = "http://%s:%d" % (a.switch_ip, a.port)
    print("%d files to %s:" % (len(files), base))
    for p in files:
        print("  %-20s %7d B" % (p.name, p.stat().st_size))
    if a.dry_run:
        return 0

    try:
        code, body = request("GET", base + "/status", timeout=10)
    except OSError as e:
        sys.exit("can't reach %s (%s). Is Seedsow's launcher on the HTTP server (Y)?" % (base, e))
    if code != 200 or "HTTP server" not in body:
        sys.exit("%s isn't the launcher's HTTP server (got %d)" % (base, code))

    for i, p in enumerate(files, 1):
        data = p.read_bytes()
        code, body = request("PUT", "%s/save?path=%s" % (base, p.name), data)
        want = "wrote %d bytes to save:/%s" % (len(data), p.name)
        if code != 200 or want not in body:
            print("FAILED at %s: %d %s" % (p.name, code, body.strip()))
            print("Nothing after it was sent. Restart Seedsow, press Y and run this again.")
            return 1
        print("[%d/%d] %s" % (i, len(files), p.name))
    print("Done. Close Seedsow fully (HOME -> X -> Close) and start it again: the launcher shows")
    print("the new A/B/Y menu.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
