# Installing SeedSwap

There are four parts:
1. Build the files on a PC.
2. Copy the SD card files.
3. Put the Seedsow save on the console, with ns2jb or with JKSV.
4. First run.

It takes about half an hour the first time.

## What you need

- A Switch 2 on **firmware 23.0.1**, with **[kaiHEN](https://github.com/ouncebrew/kaihen)** set up on its SD
  card as kaiHEN's own instructions say.
- **Seedsow Lullaby** installed on the Switch 2.
  - It's tested with the full game (`0100ee5021c9e000`).
  - The demo (`010042d022aea000`) is untested.
  - Before the exploit writes anything, it checks that the game's code is the build it knows. On any
    other build it stops and changes nothing.
- **A spare user** on the Switch 2 to hold the exploit save (System Settings → Users → Add User). Call
  it something like "Seedsow".
  - SeedSwap never plays games on this user, so don't use the one you play on.
- A PC with **Python 3.8 or newer**.

## 1. Build the files (on the PC)

1. Download this repository: **Code → Download ZIP**, then unzip it. Or use `git clone`.
2. From the [latest release](../../releases/latest), download `seedswap.nro` into the repository
   folder (next to `build.py`).
3. Open a terminal in the repository folder and run:

       python3 build.py --nro seedswap.nro

   On Windows, use `py` in place of `python3` if `python3` isn't found.

It downloads a few parts from their authors and checks every file. When it's done, you have:

| Folder or file | What it is |
|---|---|
| `out/sd/` | the SD card files |
| `out/save/` | the Seedsow save, as loose files (for ns2jb) |
| `out/seedsow-seedswap-save.zip` | the same save as one zip (for JKSV) |

If it stops with "429 Too Many Requests", a download site is limiting you. Wait ten minutes and run it
again.

## 2. Copy the SD card files

Copy **everything inside `out/sd/`** to the root of the Switch 2's SD card, and keep its folders. Use a
card reader, or FTP if you already have it running. Afterwards the card has:

    SD:/kaihen/s2_ml.lua
    SD:/kaihen/ml/...
    SD:/switch/seedswap.nro

Don't delete or replace kaiHEN's own files. This only adds files to `kaihen/`.

## 3. Put the Seedsow save on the console

**First, on the Switch 2:** switch to the spare user and start Seedsow Lullaby. Wait for the title
screen, then close it fully (HOME → X → Close). The game has to create its save before anything can
write into it.

Then pick **one** of these methods.

### Method A: ns2jb + ns2-savekit (Switch 2 only, needs a PC on the same network)

1. Get **[ns2jb](https://gitlab.com/kurumuz/ns2jb)** and
   **[ns2-savekit](https://github.com/dougchansan/ns2-savekit)**. You also need Node.js 20 or newer.
2. **Allow ns2-savekit to write Seedsow's save.** In ns2-savekit's folder, create
   `config/titles.local.json` with:

   ```json
   { "write": [ { "id": "0100ee5021c9e000", "name": "Seedsow Lullaby" } ] }
   ```

   For the demo, use `010042d022aea000` in place of `0100ee5021c9e000`.
3. **Start ns2jb** as its README explains, and leave it running. It prints a run folder like
   `runs/switch2-XXXXXX`.
4. **Open the kit:** in ns2-savekit's folder, run:

       node tools/kit.cjs

   Then:
   - Pick **Seedsow Lullaby** from the list. It has a ✔ now.
   - When it asks which user owns the save, pick the **spare user**.
5. Choose **2) Save: back this save up**. Keep this backup: it's your way back.
6. In the same menu, choose **3) Replace: write files from a directory**.
   - When it asks for the directory, give the full path to this repository's **`out/save`** folder.
   - It lists the files and asks before writing: 33 files.
7. If step 6 fails, restart the console, then start ns2jb and the kit again.
   - Take a new backup (2), then write again (3).
   - Only one save operation per console boot is always safe.
8. Optional: after the next restart, choose **7) Verify** to check the save against what was written.

### Method B: JKSV on a Switch 1, then save transfer

This needs a Switch 1 with Atmosphere and JKSV, and Seedsow Lullaby on it.

1. On the Switch 1, open JKSV and back up Seedsow Lullaby's save once. That makes its folder in
   `SD:/JKSV/`.
2. Copy `out/seedsow-seedswap-save.zip` into that folder.
3. In JKSV, restore that zip to the Seedsow save.
4. Move the save to the Switch 2 with Nintendo's save data transfer: System Settings → Data Management
   → Transfer Your Save Data, on both consoles. Send it to the **spare user** on the Switch 2.

### Already have the seedsow-semi-untethered save?

Use Method A or B anyway. Method A replaces the old files and adds the new ones. Method B replaces the
whole save.

## 4. First run

1. **Restart the Switch 2.**
2. On the spare user, start Seedsow Lullaby. The launcher menu appears. Press **A**.
3. Wait until it says **READY**. This takes about one to two minutes.
   - It may take a few attempts; that's normal.
   - If it says to power off, hold POWER for about 12 seconds, choose Power off, turn the console on
     again, and go back to step 2.
4. Close Seedsow. Open the Homebrew Menu: hold **R** while you start an installed game other than
   Seedsow. Then open **SeedSwap**.
   - It finds the spare user by its save and never uses that user.
5. **Choose who plays:** go to the **Saves** tab, press **Y**, and pick the user you play on. Then
   restart the console and run the launcher again (Seedsow → A).
6. **Add games:** in the **Library**, press **-** and pick a host. That's Seedsow, or any installed
   Switch 1 game. Then pick a game and switch to it.

Every time you turn the console on, run the launcher (Seedsow → A) on the spare user before playing.

## Launcher buttons

| Button | What it does |
|---|---|
| **A** | Starts kaiHEN with SeedSwap's loader. Use this one. |
| **B** | Same as A, with the newest seedsow-semi-untethered stages. It also copies SeedSwap from the save to `SD:/switch`, unless the SD copy is the same or newer. |
| **Y** | alula's HTTP server (port 8080). |
| Hold **-**, then A or B | The previous A or B, as a fallback. |

## Updating

- **New SeedSwap only:** download the new `seedswap.nro` from the releases and copy it to
  `SD:/switch/seedswap.nro`.
- **New SD files or a new save:** download the new repository version and build again (step 1).
  - Copy `out/sd/` again (step 2).
  - If the save changed, write `out/save` again with Method A (back up, then replace).

## If something goes wrong

| Problem | What to do |
|---|---|
| ns2-savekit doesn't show a ✔ next to Seedsow | Check `config/titles.local.json` (Method A, step 2). |
| ns2-savekit says the save doesn't exist (`0x7d402`) | Start Seedsow once on that user and close it fully, then try again. |
| The launcher menu doesn't appear | The save isn't on this user. Check that you started Seedsow on the spare user. |
| "not the expected Seedsow build" | Your Seedsow version isn't supported. Nothing was changed. |
| A says to power off | Hold POWER about 12 seconds → Power off, turn it on, and try again. |
| You want the old save back | With Method A, take a new backup (2), then choose 3 and point it at the backup folder from step 5. Its files go back; files this install added stay, but the old launcher doesn't use them. |
