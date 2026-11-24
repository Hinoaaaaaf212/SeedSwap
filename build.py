#!/usr/bin/env python3
"""Build the Seedsow Lullaby save with SeedSwap's launcher, for Switch 2 on firmware 23.0.1.

  python3 build.py [--out DIR] [--cache DIR]

Downloads the parts this repository doesn't include, at fixed commits, and checks each by SHA-256:
  alula/switch-artemis-launcher ae02495 (GitHub)     the launcher save: core.lua, http.lua,
                                                     inject.lua, inject.iet, proggy.ttf, *.dat
  rushinz/seedsow-semi-untethered 6201c35 (GitLab)   the exploit chain modules (GPL-2.0), in the
                                                     form its uploader puts them in the save
Then adds files/ from this repository and writes:
  <out>/save/                       every file of the save, flat (for ns2-savekit)
  <out>/seedsow-seedswap-save.zip   the same files (for JKSV)
Both are checked against SHA256SUMS.txt. Needs Python 3.8+ and nothing else.
"""
import argparse
import hashlib
import io
import re
import sys
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ALULA = ("https://raw.githubusercontent.com/alula/switch-artemis-launcher/"
         "ae0249547c1e05df46a63a5c05818914b3ae0706/")
SEMI = ("https://gitlab.com/rushinz/seedsow-semi-untethered/-/raw/"
        "6201c358201fb43e504dd7bbcb8191706b820f27/")

# save name -> (source path, sha256 of the file as it goes into the save)
ALULA_FILES = {
    "core.lua": ("seedsow_save/core.lua", "e2684edde07e117009cfb101cb335abf88c131c720a0a6a6714d31d97b0b83d3"),
    "http.lua": ("common/http.lua", "2bf16c8f7822a23926e04c637e34d653bf9a4a06d48c3fc6e66ccdca560a5c9b"),
    "inject.lua": ("common/inject.lua", "57b50ec448475eab82ac3aa950e8a76308885f4b71b71b42f84876ea2f84dcc2"),
    "inject.iet": ("common/inject.iet", "bf79a739584de93d1569523a8a87e7ef8ce65edcf073b5d2ba37453c4085ada4"),
    "proggy.ttf": ("common/proggy.ttf", "527d2a443ce051f93f7e77b855609722b8cb220a9f104b4aa037be5c90b71324"),
    "save9999.dat": ("common/save9999.dat", "c6e7f275d20dba5156d871b7648542ffce2b1fd91f3c68532f80277557a09acd"),
    "saveg.dat": ("common/saveg.dat", "3f32df9a51cce5d9f74fade92fc64423b19a6e5e6eb0286639ff92f4f7db1730"),
    "system.dat": ("common/system.dat", "41b636bee141926298e77abdc9e9377fdf13325a4bc98faa6d0f443f2ac94c9e"),
}
SEMI_FILES = {
    "s2_rt.lua": "a945473b48f2ad15f83c634da7accd610036ad149fb3f14db52e944547ebde90",
    "s2_prim.lua": "d5e5f38157b094d2b7690a9a5fd7dc918ed27c8830f274046a85dd8bb72276ae",
    "s2_fshlp.lua": "69dcf6f1beea81ec1bbf63c5d92bce378f0113c73c1a10bfcc66bfbf81329cdc",
    "s2_fs.lua": "cef0a029a61e90b85623e361dc9c8620cb0e82f767ff5a7007adebf1c54f1b1c",
    "s2_wave.lua": "53c3037b69796136db0451de74e9db4b6a7bdab9127d4d398facc8e1ce490beb",
    "s2_race.lua": "15bc64c55188bfa97fc3fc603f25dac3fbcf4447335982bbceb0acaefa4b2c37",
    "s2_scan.lua": "29188451c2bad547fa55551e02884b245489ec21bfb14f1812011395c520c903",
    "s2_promote.lua": "cfa0e23879f7aa24217c6f8b50503216168e337e50a69d719257aec4fef54a81",
    "s2_kh_ro.lua": "cba5d9c638461153f708ecb9e3e60ca7b4ba60589cece101d0923e44b0126827",
    "s2_kaihen.lua": "ec46b1efcac639b5a9fd2dcf926ad9c2629cdf95d29ce35f5cfd50538cf1e88e",
    "s2_main.lua": "0ae5ab77bfa18c21e3ff9bb52845d3830135c258065b58fc6b688b9f29016d1e",
    "exploita2.lua": "f1c5ef76feae14a6257319144977a658768806fb11fd80893c89b8f34c6c18f7",
    "inject2.lua": "253b498ddecb2d4dd1e6b8a89c144c49ee87965e3450f4aa9d7e4ce6afed4ca9",
}
# copies the uploader also writes, so older launchers and Lua Editor saves find button A
SEMI_COPIES = {"exploita.lua": "exploita2.lua", "exploit1.lua": "exploita2.lua",
               "ax_exploita2.lua": "exploita2.lua", "ax_inject2.lua": "inject2.lua"}
UPLOAD_CAP, WIRE_CAP = 32000, 28600
ZIP_NAME = "seedsow-seedswap-save.zip"
ZIP_TIME = (2026, 11, 24, 0, 0, 0)


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def wire(raw: bytes, name: str) -> bytes:
    """What seedsow-semi-untethered's uploader sends: LF line ends; over 28,600 bytes, comment lines
    emptied, then indentation dropped."""
    text = raw.decode("utf-8").replace("\r\n", "\n")
    data = text.encode("utf-8")
    if len(data) > UPLOAD_CAP:
        raise SystemExit("%s: %d bytes, over %d" % (name, len(data), UPLOAD_CAP))
    if len(data) <= WIRE_CAP:
        return data
    text = "\n".join("" if re.match(r"^\s*--", line) else line for line in text.split("\n"))
    if len(text.encode()) > WIRE_CAP:
        text = "\n".join(re.sub(r"^\s+", "", line) for line in text.split("\n"))
    return text.encode("utf-8")


def fetch(url: str, cache: Path) -> bytes:
    local = cache / re.sub(r"[^A-Za-z0-9_.-]+", "_", url.split("://", 1)[1])
    if local.is_file():
        return local.read_bytes()
    req = urllib.request.Request(url, headers={"User-Agent": "seedsow-save-build"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read()
    cache.mkdir(parents=True, exist_ok=True)
    local.write_bytes(data)
    return data


def checked(name, data, want, where):
    if sha(data) != want:
        raise SystemExit("%s from %s has SHA-256 %s, expected %s" % (name, where, sha(data), want))
    return data


def zip_bytes(files) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:  # stored: same bytes on every machine
        for n in sorted(files):
            info = zipfile.ZipInfo(n, date_time=ZIP_TIME)
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = 0o644 << 16
            info.create_system = 3                 # Unix, whatever machine builds it
            z.writestr(info, files[n])
    return buf.getvalue()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=HERE / "out")
    ap.add_argument("--cache", type=Path, default=HERE / "cache")
    a = ap.parse_args(argv)

    files = {}
    for name, (path, want) in ALULA_FILES.items():
        files[name] = checked(name, fetch(ALULA + path, a.cache), want, "alula/switch-artemis-launcher")
    semi = {}
    for name, want in SEMI_FILES.items():
        semi[name] = checked(name, wire(fetch(SEMI + "lua/" + name, a.cache), name), want,
                             "rushinz/seedsow-semi-untethered")
    files.update(semi)
    files.update({n: semi[src] for n, src in SEMI_COPIES.items()})
    print("downloaded and checked: %d alula files, %d seedsow-semi-untethered modules"
          % (len(ALULA_FILES), len(SEMI_FILES)))

    ours = sorted(p for p in (HERE / "files").iterdir() if p.is_file() and not p.name.startswith("."))
    for p in ours:
        files[p.name] = p.read_bytes()
    print("added from files/: %d (%s)" % (len(ours), ", ".join(p.name for p in ours)))

    want = {}
    for line in (HERE / "SHA256SUMS.txt").read_text().splitlines():
        digest, name = line.split(None, 1)
        want[name.strip()] = digest
    got = {"save/" + n: sha(d) for n, d in files.items()}
    z = zip_bytes(files)
    got[ZIP_NAME] = sha(z)
    if got != want:
        bad = sorted(n for n in set(got) | set(want) if got.get(n) != want.get(n))
        raise SystemExit("doesn't match SHA256SUMS.txt: " + ", ".join(bad))

    save = a.out / "save"
    save.mkdir(parents=True, exist_ok=True)
    for old in save.iterdir():
        if old.name not in files:
            old.unlink()
    for n, d in files.items():
        (save / n).write_bytes(d)
    (a.out / ZIP_NAME).write_bytes(z)
    print("wrote %s (%d files) and %s; all match SHA256SUMS.txt" % (save, len(files), a.out / ZIP_NAME))
    return 0


if __name__ == "__main__":
    sys.exit(main())
