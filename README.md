# Seedsow save with SeedSwap

A Seedsow Lullaby save for Switch 2 on firmware 23.0.1. It holds:
- alula's launcher (switch-artemis-launcher);
- the seedsow-semi-untethered exploit chain;
- SeedSwap's additions to the launcher.

## Launcher buttons

| Button | What it does |
|---|---|
| A | Runs kaiHEN. If `SD:/kaihen/s2_ml.lua` is on the card, SeedSwap's loader starts first. |
| B | Same as A, with the newest seedsow-semi-untethered scan and wave stages (e5c14e5). Then copies SeedSwap from the save to `SD:/switch/seedswap.nro`. It never replaces a newer SeedSwap. |
| Y | alula's HTTP server (port 8080). |
| Hold - first | Runs the previous A or B. |

## Build

    python3 build.py

This makes two things:
- `out/save/`: every file of the save;
- `out/seedsow-seedswap-save.zip`: the same files as one zip.

The script needs Python 3.8 or newer. It downloads these parts at fixed commits and checks each
file's SHA-256 against this repository:
- alula's launcher files;
- the unchanged seedsow-semi-untethered modules.

They are not stored here. alula's repository has no licence file, so they are fetched from the
source instead.

GitHub Actions runs the same build on every push. It doesn't upload the result.

## Install (firmware 23.0.1)

Choose one way:

- **ns2jb + [ns2-savekit](https://github.com/dougchansan/ns2-savekit):**
  1. Start Seedsow once and close it, so its save exists.
  2. Add its program ID to savekit's `config/titles.local.json` `write` list:
     `0100ee5021c9e000` (full game) or `010042d022aea000` (demo).
  3. Run `node tools/kit.cjs`, choose 3, and point it at `out/save/`. It backs the save up, writes
     the files in one go, and checks each one.
- **JKSV:** on a Switch 1 with Atmosphere, restore the zip to the Seedsow save. Then move the save
  to the Switch 2 with Nintendo's save transfer.

SeedSwap also needs its SD card files (see the SeedSwap release).

## What is in files/

These files change or add to seedsow-semi-untethered 6201c35:
- `s2_kh_ro.lua`: the kaiHEN stage. It runs `SD:/kaihen/s2_ml.lua` (SeedSwap's loader) before
  kaiHEN, if that file is on the card.
- `inject2.lua`: the launcher menu with A, B and Y.
- `exploita2.lua`, `b_s2_main.lua`, `b_s2_kaihen.lua`, `b_s2_promote.lua`: the A run. It adds:
  - a build check before the first write;
  - "power the console fully off" messages when a run fails;
  - a kaiHEN file size check;
  - a promote stage that never reads memory nothing has read before.
- `exploitb2.lua`, `n_s2_scan.lua`, `n_s2_wave.lua`: B. The two `n_` files are seedsow-semi-untethered
  e5c14e5's scan and wave stages, unchanged apart from line endings and stripped comments. Only B
  loads them.
- `exploita.lua`, `exploitb.lua`: the previous A and B (hold -).
- `seedswap.nro`: SeedSwap.

## Licences

- The `.lua` files in `files/` are GPL-2.0 (`LICENSE`), as seedsow-semi-untethered is. Its
  CivSwitchFS part is MIT (`licenses/CivSwitchFS-MIT.txt`).
- `files/seedswap.nro` is SeedSwap's own build. It is not covered by `LICENSE`.
- The downloaded files keep their authors' terms.

## Credits

- alula: switch-artemis-launcher
- rushinz: seedsow-semi-untethered
- ItsNerisma: CivSwitchFS
- ouncebrew: kaiHEN
