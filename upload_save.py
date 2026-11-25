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

Saves made with mac2jb or the early-November http.lua take at most 28,672 bytes per file (issue 3).
Like seedsow-semi-untethered's own uploader, a Lua file over 28,600 bytes is sent with its comment
lines emptied and, if that is not enough, its indentation dropped. Line numbers stay the same.
"""
import argparse
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

PROTECTED = {"core.lua", "http.lua", "inject.lua", "inject.iet", "proggy.ttf",
             "save9999.dat", "saveg.dat", "system.dat"}
TOO_BIG = {"seedswap.nro"}
BODY_CAP = 0x40000 - 0x1000      # http.lua's limit
WIRE_CAP = 28600                 # under 0x7000, the limit of older http.lua saves
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


def wire(p):
    """The bytes sent for file p: LF line ends; a Lua file over WIRE_CAP shrunk as described above."""
    data = p.read_bytes()
    if p.suffix != ".lua":
        return data
    text = data.decode("utf-8").replace("\r\n", "\n")
    if len(text.encode()) <= WIRE_CAP:
        return text.encode()
    if re.search(r"\[=*\[", text):
        return text.encode()       # a long string or block comment: leave it whole
    text = "\n".join("" if re.match(r"^\s*--", line) else line for line in text.split("\n"))
    if len(text.encode()) > WIRE_CAP:
        text = "\n".join(re.sub(r"^\s+", "", line) for line in text.split("\n"))
    return text.encode()


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
    sent = {p.name: wire(p) for p in files}
    big = [p.name for p in files if len(sent[p.name]) > BODY_CAP]
    if big:
        sys.exit("too big for the launcher's server: " + ", ".join(big))

    base = "http://%s:%d" % (a.switch_ip, a.port)
    print("%d files to %s:" % (len(files), base))
    for p in files:
        n = len(sent[p.name])
        print("  %-20s %7d B%s" % (p.name, n, "" if n == p.stat().st_size else " (comments left out)"))
    if a.dry_run:
        return 0

    try:
        code, body = request("GET", base + "/status", timeout=10)
    except OSError as e:
        sys.exit("can't reach %s (%s). Is Seedsow's launcher on the HTTP server (Y)?" % (base, e))
    if code != 200 or "HTTP server" not in body:
        sys.exit("%s isn't the launcher's HTTP server (got %d)" % (base, code))

    for i, p in enumerate(files, 1):
        data = sent[p.name]
        code, body = request("PUT", "%s/save?path=%s" % (base, p.name), data)
        want = "wrote %d bytes to save:/%s" % (len(data), p.name)
        if code != 200 or want not in body:
            print("FAILED at %s: %d %s" % (p.name, code, body.strip()))
            if code == 413:
                print("This save's HTTP server takes smaller files than this one. Use ns2jb and ns2-savekit")
                print("instead (INSTALL.md, step 3).")
            print("Nothing after it was sent. Restart Seedsow, press Y and run this again.")
            return 1
        print("[%d/%d] %s" % (i, len(files), p.name))
    print("Done. Close Seedsow fully (HOME -> X -> Close) and start it again: the launcher shows")
    print("the new A/B/Y menu.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
