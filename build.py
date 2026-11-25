#!/usr/bin/env python3
"""Build SeedSwap's Seedsow save and SD card files (Switch 2, firmware 23.0.1).

  python3 build.py [--nro PATH] [--out DIR] [--cache DIR]
  build.exe [--nro PATH] [--out DIR] [--cache DIR]

--nro is SeedSwap built from seedswap/ (default seedswap/seedswap.nro; see seedswap/README.md), or
the seedswap.nro of a GitHub Actions run.

build.exe (in each release, Windows) is this script with the repository's save/, sd/ and
SHA256SUMS.txt inside, so it needs neither Python nor the repository. It takes seedswap.nro from
its own folder and writes out/ and cache/ there; double-clicked, it keeps its window open at the end.
Use the build.exe and seedswap.nro of the same release: SHA256SUMS.txt names that NRO.

Downloads the parts this repository doesn't include, at fixed commits, and checks each by SHA-256:
  alula/switch-artemis-launcher ae02495 (GitHub)     the launcher save: core.lua, http.lua,
                                                     inject.lua, inject.iet, proggy.ttf, *.dat
  rushinz/seedsow-semi-untethered 6201c35 (GitLab)   the exploit chain modules, in the form its
                                                     uploader puts them in the save
  kurumuz/ns2jb 81d5bb1 (GitLab)                     the RO helper the loader stage starts first
Writes:
  <out>/save/                       the Seedsow save, every file flat (for ns2-savekit)
  <out>/seedsow-seedswap-save.zip   the same files as one zip
  <out>/sd/                         copy to the root of the SD card
Every file is checked against SHA256SUMS.txt. Needs Python 3.8+ and nothing else.
"""
import argparse
import hashlib
import io
import re
import sys
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

FROZEN = getattr(sys, "frozen", False)  # build.exe (PyInstaller): the repository's files are inside it
HERE = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))  # save/, sd/, SHA256SUMS.txt
HOME = Path(sys.executable).resolve().parent if FROZEN else HERE        # seedswap.nro, out/, cache/
ALULA = ("https://raw.githubusercontent.com/alula/switch-artemis-launcher/"
         "ae0249547c1e05df46a63a5c05818914b3ae0706/")
SEMI = ("https://gitlab.com/rushinz/seedsow-semi-untethered/-/raw/"
        "6201c358201fb43e504dd7bbcb8191706b820f27/")
NS2JB = "https://gitlab.com/kurumuz/ns2jb/-/raw/81d5bb114c856109dadaf1077d927a9f297fe58d/"

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
RO_HELPER = ("engine/switch2/ro/payload/main", "kaihen/ml/helper_ro_main",
             "d590cbfc5d9152c24d5a36f083f8470a2f3164be6b78130129d44132b939701a")
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
    req = urllib.request.Request(url, headers={"User-Agent": "seedswap-build"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read()
    except (urllib.error.URLError, OSError) as e:
        raise SystemExit("couldn't download %s: %s\nCheck the internet connection and run it again "
                         "(after a 429, wait ten minutes)." % (url, getattr(e, "reason", e)))
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


def write_tree(root: Path, files: dict):
    root.mkdir(parents=True, exist_ok=True)
    for old in sorted(root.rglob("*"), reverse=True):
        rel = old.relative_to(root).as_posix()
        if old.is_file() and rel not in files:
            old.unlink()
    for rel, data in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_bytes(data)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--nro", type=Path, default=HOME / "seedswap.nro" if FROZEN else HERE / "seedswap" / "seedswap.nro")
    ap.add_argument("--out", type=Path, default=HOME / "out")
    ap.add_argument("--cache", type=Path, default=HOME / "cache")
    a = ap.parse_args(argv)
    if not a.nro.is_file():
        if FROZEN:
            raise SystemExit("no seedswap.nro in %s: download it from the same release as build.exe and put it "
                             "next to build.exe" % HOME)
        raise SystemExit("no %s: build SeedSwap first (seedswap/README.md) or pass --nro" % a.nro)
    nro = a.nro.read_bytes()
    if nro[0x10:0x14] != b"NRO0":
        raise SystemExit("%s is not an NRO" % a.nro)

    save = {}
    for name, (path, want) in ALULA_FILES.items():
        save[name] = checked(name, fetch(ALULA + path, a.cache), want, "alula/switch-artemis-launcher")
    semi = {}
    for name, want in SEMI_FILES.items():
        semi[name] = checked(name, wire(fetch(SEMI + "lua/" + name, a.cache), name), want,
                             "rushinz/seedsow-semi-untethered")
    save.update(semi)
    save.update({n: semi[src] for n, src in SEMI_COPIES.items()})
    path, rel, want = RO_HELPER
    helper = checked(rel, fetch(NS2JB + path, a.cache), want, "kurumuz/ns2jb")
    print("downloaded and checked: %d alula files, %d seedsow-semi-untethered modules, ns2jb's RO helper"
          % (len(ALULA_FILES), len(SEMI_FILES)))

    ours = sorted(p for p in (HERE / "save").iterdir() if p.is_file())
    for p in ours:
        save[p.name] = p.read_bytes()
    save["seedswap.nro"] = nro
    sd = {p.relative_to(HERE / "sd").as_posix(): p.read_bytes()
          for p in sorted((HERE / "sd").rglob("*")) if p.is_file()}
    sd[rel] = helper
    sd["switch/seedswap.nro"] = nro

    want = {}
    for line in (HERE / "SHA256SUMS.txt").read_text().splitlines():
        digest, name = line.split(None, 1)
        want[name.strip()] = digest
    z = zip_bytes(save)
    got = {"save/" + n: sha(d) for n, d in save.items()}
    got[ZIP_NAME] = sha(z)
    got.update({"sd/" + r: sha(d) for r, d in sd.items()})
    if got != want:
        bad = sorted(n for n in set(got) | set(want) if got.get(n) != want.get(n))
        raise SystemExit("doesn't match SHA256SUMS.txt: " + ", ".join(bad))

    write_tree(a.out / "save", save)
    (a.out / ZIP_NAME).write_bytes(z)
    write_tree(a.out / "sd", sd)
    print("wrote %s/save (%d files), %s, %s/sd (%d files); all match SHA256SUMS.txt"
          % (a.out, len(save), ZIP_NAME, a.out, len(sd)))
    return 0


def double_clicked() -> bool:
    """build.exe got a window of its own (Explorer): only its two processes use the console."""
    if not FROZEN or sys.platform != "win32":
        return False
    import ctypes
    ids = (ctypes.c_uint32 * 16)()
    return 0 < ctypes.windll.kernel32.GetConsoleProcessList(ids, 16) <= 2


def run() -> int:
    try:
        return main()
    except SystemExit as e:
        if isinstance(e.code, str):
            print(e.code, file=sys.stderr)
            return 1
        return e.code or 0


if __name__ == "__main__":
    pause = double_clicked()
    code = run()
    if pause:
        try:
            input("\n%s. Press Enter to close this window." % ("Done" if code == 0 else "It stopped"))
        except EOFError:
            pass
    sys.exit(code)
