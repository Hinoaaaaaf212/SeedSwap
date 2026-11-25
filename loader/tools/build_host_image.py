#!/usr/bin/env python3
"""Install image with host slots for SeedSwap's any-host mode (2026-11-23).

  build    --host ID (repeatable; Seedsow first by default) --spares N --guard-user UID --out DIR
           Lists every host's folder (/ns2jb-modloader/contents/<id>/{romfs.bin,exefs.nsp}) in the plan, so
           a host plays whatever game SeedSwap puts there and runs as itself while its folder is empty
           (live sizes). Spare slots get placeholder IDs (01ffffffffffN000) that no game has; SeedSwap
           gives one to another installed game on the console (retitle). The save guard runs in hosting
           mode (program ffffffffffffffff): every listed title, only while it runs a hosted game, may open
           only the guard user's saves. Writes the usual four files plus hosts.ini. --sig-patch adds the
           two FS signature-check hooks (fs-sig-profile.json) for games installed for HOME.
  retitle  --image DIR --slot OLD --to NEW --out DIR
           What SeedSwap does on the console, for checking: every ASCII copy of OLD in context.bin and
           image.lua and the one u64 in the games table become NEW; image.lua's context checksums and
           hosts.ini follow. The runtime looks titles up by ID, so the order of the games table, which a
           fresh build would sort by folder name, does not matter.
  guard    --image DIR --user UID --out DIR
           What SeedSwap does on the console when another play user is chosen: the save guard's user
           (image.lua's guard block, its one raw copy in context.bin, hosts.ini guard_user) becomes UID;
           image.lua's context checksums follow. Never a protected user.
  check    builds images and compares retitled ones with fresh builds (byte for byte where the order is
           the same), and a guard-edited one with a fresh build for that user, and runs the Lua image test.

hosts.ini:  host=<id> per slot in use, spare=<id> per placeholder, context_ids=<n>, image_ids=<n>
            (ASCII copies of one slot's ID in context.bin and image.lua; SeedSwap checks them before editing).
"""
import argparse
import hashlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
PORT = HERE.parent
SEEDSOW = "0100ee5021c9e000"
GUARD_ALL = "ffffffffffffffff"
GUARD_USER = "ffffffffffffffffffffffffffffffff"   # nobody until SeedSwap sets the play user
PROTECTED_USERS = ()   # as s2_ml.lua
FILES = ("image.lua", "runtime.bin", "gateway.bin", "context.bin")
PLACEHOLDER = "01ffffffffff%x000"          # spare N (1..15)
GAMES_OFFSET_RE = re.compile(r"gamesOffset = (\d+),")


def spare_id(n: int) -> str:
    return PLACEHOLDER % n


ROMFS_PARTS = 8    # romfs.bin.00 .. romfs.bin.07: a RomFS split for FAT32 in parts of 0xFFFF0000 bytes (the runtime joins the parts present)


def listing(slots) -> str:
    rows = ["D /ns2jb-modloader/contents/"]
    for s in slots:
        rows += ["D /ns2jb-modloader/contents/%s/" % s,
                 "F 33554432 /ns2jb-modloader/contents/%s/exefs.nsp" % s,
                 "F 33554432 /ns2jb-modloader/contents/%s/romfs.bin" % s]
        rows += ["F 33554432 /ns2jb-modloader/contents/%s/romfs.bin.%02d" % (s, k) for k in range(ROMFS_PARTS)]
    return "\n".join(rows) + "\n"


def build(hosts, spares, guard_user, out: Path, quiet=False, first_spare=1, sig_patch=False):
    slots = list(hosts) + [spare_id(first_spare + i) for i in range(spares)]
    for s in slots:
        if not re.fullmatch(r"01[0-9a-f]{14}", s):
            raise SystemExit("not an application program ID: " + s)
    if len(set(slots)) != len(slots):
        raise SystemExit("a host is listed twice")
    out.mkdir(parents=True, exist_ok=True)
    tree = out / "sd-tree.txt"
    put(tree, listing(slots))
    cmd = ["node", str(HERE / "build_install_image.cjs"), "--tree", str(tree), "--guard-program", GUARD_ALL,
           "--guard-user", guard_user, "--out", str(out)] + (["--sig-patch"] if sig_patch else [])
    for s in slots:
        cmd += ["--title", s]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stdout + r.stderr)
    if not quiet:
        print(r.stdout.strip())
    ctx = (out / "context.bin").read_bytes()
    lua = get(out / "image.lua")
    # every slot's ID is in the plan the same number of times; an ID that also turns up in other data
    # (the FS fingerprint hex, by chance) shows more. Spares must not, since SeedSwap replaces them all.
    seen = {s: (ctx.count(s.encode()), lua.count(s)) for s in slots}
    cids, lids = min(c for c, _ in seen.values()), min(l for _, l in seen.values())
    odd = [s for s in slots[len(hosts):] if seen[s] != (cids, lids)]
    if odd:
        raise SystemExit("spare IDs also found elsewhere in the image: %s; pick other ones" % odd)
    for s in slots:
        if ctx.count(struct.pack("<Q", int(s, 16))) != 1:
            raise SystemExit("slot %s is not in the games table exactly once" % s)
    text = ["# Host slots of this install image (semi-untethered-port/tools/build_host_image.py).",
            "# SeedSwap reads this; when it gives a spare slot to a game it rewrites context.bin, image.lua and this file."]
    text += ["host=" + s for s in hosts] + ["spare=" + s for s in slots[len(hosts):]]
    text += ["context_ids=%d" % cids, "image_ids=%d" % lids, "guard_user=" + guard_user]
    put(out / "hosts.ini", "\n".join(text) + "\n")
    return slots


def get(p: Path) -> str:      # the image's text files are LF on every system (SeedSwap edits them byte for byte)
    return p.read_bytes().decode()


def put(p: Path, text: str):
    p.write_bytes(text.encode())


def adler32(b: bytes) -> int:
    return zlib.adler32(b) & 0xffffffff


def retitle(image: Path, old: str, new: str, out: Path):
    """The console's slot edit (SeedSwap hostimg.c does the same)."""
    ini = get(image / "hosts.ini")
    if "spare=" + old not in ini.splitlines():
        raise SystemExit("%s is not a spare slot" % old)
    if re.search(r"^(host|spare)=%s$" % new, ini, re.M):
        raise SystemExit("%s already has a slot" % new)
    cids = int(re.search(r"^context_ids=(\d+)$", ini, re.M).group(1))
    lids = int(re.search(r"^image_ids=(\d+)$", ini, re.M).group(1))
    ctx = (image / "context.bin").read_bytes()
    lua = get(image / "image.lua")
    oldq, newq = struct.pack("<Q", int(old, 16)), struct.pack("<Q", int(new, 16))
    if ctx.count(old.encode()) != cids or lua.count(old) != lids or ctx.count(oldq) != 1:
        raise SystemExit("the image does not look as hosts.ini says")
    ctx2 = ctx.replace(old.encode(), new.encode()).replace(oldq, newq)
    m = re.search(r'(context = \{\s*file = "context.bin",\s*bytes = (\d+),\s*sha256 = ")([0-9a-f]{64})(",\s*adler32 = )(\d+)', lua)
    if not m or int(m.group(2)) != len(ctx) or m.group(3) != hashlib.sha256(ctx).hexdigest() or int(m.group(5)) != adler32(ctx):
        raise SystemExit("image.lua's context entry does not match context.bin")
    lua2 = lua[:m.start(3)] + hashlib.sha256(ctx2).hexdigest() + m.group(4) + str(adler32(ctx2)) + lua[m.end(5):]
    lua2 = lua2.replace(old, new)
    ini2 = "\n".join(("host=" + new) if line == "spare=" + old else line for line in ini.splitlines()) + "\n"
    out.mkdir(parents=True, exist_ok=True)
    for n in ("runtime.bin", "gateway.bin"):
        shutil.copyfile(image / n, out / n)
    (out / "context.bin").write_bytes(ctx2)
    put(out / "image.lua", lua2)
    put(out / "hosts.ini", ini2)


CONTEXT_RE = re.compile(r'(context = \{\s*file = "context.bin",\s*bytes = (\d+),\s*sha256 = ")([0-9a-f]{64})(",\s*adler32 = )(\d+)')
GUARD_RE = re.compile(r'guard = \{[^}]*?user = "([0-9a-fA-F]{32})"')


def set_guard(image: Path, user: str, out: Path):
    """The console's guard edit (SeedSwap hosts.c hostimg_set_guard does the same)."""
    user = user.lower()
    if not re.fullmatch(r"[0-9a-f]{32}", user) or user == "0" * 32:
        raise SystemExit("not a user ID: " + user)
    if user in PROTECTED_USERS:
        raise SystemExit("the guard must not allow a protected user: " + user)
    lua = get(image / "image.lua")
    ctx = (image / "context.bin").read_bytes()
    m = GUARD_RE.search(lua)
    if lua.count("guard = {") != 1 or not m:
        raise SystemExit("the image has no save guard")
    old = m.group(1)
    if ctx.count(bytes.fromhex(old)) != 1 or ctx.count(bytes.fromhex(user)):
        raise SystemExit("the image does not look as expected")
    c = CONTEXT_RE.search(lua)
    if not c or int(c.group(2)) != len(ctx) or c.group(3) != hashlib.sha256(ctx).hexdigest() or int(c.group(5)) != adler32(ctx):
        raise SystemExit("image.lua's context entry does not match context.bin")
    ctx2 = ctx.replace(bytes.fromhex(old), bytes.fromhex(user))
    lua2 = lua[:m.start(1)] + user + lua[m.end(1):]
    c = CONTEXT_RE.search(lua2)
    lua2 = lua2[:c.start(3)] + hashlib.sha256(ctx2).hexdigest() + c.group(4) + str(adler32(ctx2)) + lua2[c.end(5):]
    out.mkdir(parents=True, exist_ok=True)
    for n in ("runtime.bin", "gateway.bin"):
        shutil.copyfile(image / n, out / n)
    (out / "context.bin").write_bytes(ctx2)
    put(out / "image.lua", lua2)
    if (image / "hosts.ini").exists():
        put(out / "hosts.ini", re.sub(r"^guard_user=[0-9a-fA-F]{32}$", "guard_user=" + user, get(image / "hosts.ini"),
                                      count=1, flags=re.M))


def without_generated(lua: str) -> str:
    return re.sub(r'(generated|file) = "[^"]*",', "", lua)


def check():
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        base = build([SEEDSOW, "0100c9100b06a000"], 2, GUARD_USER, t / "base", quiet=True)
        print("built slots", base)
        cases = [("01ffff0000001000", True),   # sorts where the spare was: a fresh build is the same, byte for byte
                 ("01007ef00011e000", False)]  # sorts first: same bytes apart from the games' order
        for new, same_order in cases:
            retitle(t / "base", spare_id(1), new, t / ("re-" + new))
            build([SEEDSOW, "0100c9100b06a000", new], 1, GUARD_USER, t / ("fresh-" + new), quiet=True, first_spare=2)
            a, b = t / ("re-" + new), t / ("fresh-" + new)
            for n in ("runtime.bin", "gateway.bin"):
                assert (a / n).read_bytes() == (b / n).read_bytes(), n
            ca, cb = (a / "context.bin").read_bytes(), (b / "context.bin").read_bytes()
            if same_order:
                assert ca == cb, "context differs"
                la, lb = without_generated(get(a / "image.lua")), without_generated(get(b / "image.lua"))
                assert la == lb, "image.lua differs"
                assert get(a / "hosts.ini").splitlines()[2:] == get(b / "hosts.ini").splitlines()[2:]
                print("retitle %s -> %s: identical to a fresh build" % (spare_id(1), new))
            else:
                assert len(ca) == len(cb) and sorted(ca) == sorted(cb)
                print("retitle %s -> %s: same bytes as a fresh build in another order (games table sorted "
                      "differently)" % (spare_id(1), new))
            r = subprocess.run(["wsl", "-e", "lua5.1", "-e",
                                'package.path="sd/kaihen/ml/?.lua;"..package.path local I=require("ml_image") '
                                'local function rd(p,m) local f=assert(io.open(p,"rb")) local s=f:read("*a") f:close() return s end '
                                'local img=I.load(rd,"%s") print("ml_image.load ok, "..#img.plan.titles.." titles")' % wsl(a)],
                               cwd=str(PORT), capture_output=True, text=True)
            print("  " + (r.stdout.strip() or r.stderr.strip()))
            assert r.returncode == 0 and "load ok" in r.stdout
        other = "5a5a1c0ffee00010886845d04eb77b99"   # a made-up fourth user
        set_guard(t / "base", other, t / "guard")
        build([SEEDSOW, "0100c9100b06a000"], 2, other, t / "fresh-guard", quiet=True)
        a, b = t / "guard", t / "fresh-guard"
        for n in ("runtime.bin", "gateway.bin", "context.bin"):
            assert (a / n).read_bytes() == (b / n).read_bytes(), n
        assert without_generated(get(a / "image.lua")) == without_generated(get(b / "image.lua")), "image.lua differs"
        assert get(a / "hosts.ini").splitlines()[2:] == get(b / "hosts.ini").splitlines()[2:]
        print("guard %s -> %s: identical to a fresh build" % (GUARD_USER, other))
        for bad_user in (PROTECTED_USERS[0], PROTECTED_USERS[1], "0" * 32, "12345"):
            try:
                set_guard(t / "base", bad_user, t / "bad-guard")
                raise AssertionError("guard %s was allowed" % bad_user)
            except SystemExit as e:
                print("refused as expected: %s" % e)
        for bad in (("0100ee5021c9e000", "01fffffff0000000"), (spare_id(2), "0100c9100b06a000")):
            try:
                retitle(t / "base", bad[0], bad[1], t / "bad")
                raise AssertionError("retitle %s -> %s was allowed" % bad)
            except SystemExit as e:
                print("refused as expected: %s" % e)
    print("CHECK OK")


def wsl(p: Path) -> str:
    s = str(p.resolve()).replace("\\", "/")
    return "/mnt/" + s[0].lower() + s[2:]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--host", action="append", default=[])
    b.add_argument("--spares", type=int, default=2)
    b.add_argument("--guard-user", default=GUARD_USER)
    b.add_argument("--out", type=Path, required=True)
    b.add_argument("--sig-patch", action="store_true",
                   help="also turn off FS's NCA header signature check while the loader is in (games installed for HOME)")
    r = sub.add_parser("retitle")
    r.add_argument("--image", type=Path, required=True)
    r.add_argument("--slot", required=True)
    r.add_argument("--to", required=True)
    r.add_argument("--out", type=Path, required=True)
    g = sub.add_parser("guard")
    g.add_argument("--image", type=Path, required=True)
    g.add_argument("--user", required=True)
    g.add_argument("--out", type=Path, required=True)
    sub.add_parser("check")
    a = ap.parse_args(argv)
    if a.cmd == "build":
        hosts = [h.lower() for h in a.host] or [SEEDSOW]
        if not 0 <= a.spares <= 15:
            ap.error("--spares 0..15")
        print("slots:", build(hosts, a.spares, a.guard_user.lower(), a.out, sig_patch=a.sig_patch))
    elif a.cmd == "retitle":
        retitle(a.image, a.slot.lower(), a.to.lower(), a.out)
        print("wrote", a.out)
    elif a.cmd == "guard":
        set_guard(a.image, a.user, a.out)
        print("wrote", a.out)
    else:
        check()


if __name__ == "__main__":
    sys.exit(main())
