# Installing SeedSwap

There are five parts:
1. Build the files on a PC.
2. Copy the SD card files.
3. Put the Seedsow save on the console: with ns2jb, or over the network if you already have
   seedsow-semi-untethered.
4. First run.
5. Add your games.

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

> **Use only your own games and keys.**
> - Only play dumps of games you own, made yourself from your own cartridges or downloads.
> - Only use the `prod.keys` dumped from your own console.
> - Don't download games or keys from anywhere, and don't share yours. This repository has neither.

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
| `out/seedsow-seedswap-save.zip` | the same save as one zip, for other save tools |

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

Then write the save with ns2jb + ns2-savekit. You need a PC on the same network as the Switch 2.

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

### Already have the seedsow-semi-untethered save? Update it over the network instead

If any version of seedsow-semi-untethered already works on your console, you don't need ns2jb. Its
launcher has an HTTP server (button **Y**) that can write files into the save. You also need FTP: any
FTP server you can run after kaiHEN starts. You still need the PC and `build.py` from step 1.

1. **Start kaiHEN the usual way:** Seedsow on the user with the exploit save, then **A**. Wait for
   READY.
2. **Copy the SD card files over FTP:** close Seedsow and start your FTP server. Copy everything
   inside `out/sd/` to the root of the SD card, as in step 2.
3. **Start the HTTP server:** start Seedsow again on the same user and press **Y** in the launcher. It
   shows the console's IP address and port 8080.
4. **Send the save files from the PC.** In the repository folder, run:

       python3 upload_save.py SWITCH-IP

   Use the IP address the launcher shows. The script:
   - sends 24 files, one at a time, and checks each answer;
   - sends the launcher menu, `inject2.lua`, last, so the new menu only appears when everything
     else is in;
   - leaves out the launcher's own protected files (the save already has them) and `seedswap.nro`
     (too big for the server, and step 2 already put it on the SD card).

   Add `--dry-run` to see the list without sending anything.
5. **Check it:** close Seedsow fully (HOME → X → Close) and start it again. The menu should now say
   **A : Run kaiHEN + modloader (hardened)**. Then go on with the first run, step 4 below.

If the script stops partway, start Seedsow again, press Y, and run it again. It sends everything
again. Files left over from your old version stay in the save, but nothing uses them.

**Option B and the SD copy:** B copies SeedSwap from the save to the SD card. A save updated this way
has no `seedswap.nro`, so B just says so and goes on. Update SeedSwap by copying the new
`seedswap.nro` over FTP.

**If anything still behaves like your old version,** use the ns2jb steps above. They write the whole
save, including the files the HTTP server can't change.

### Don't update the console

Don't install system updates, and don't use features that ask for one, such as moving saves between
consoles. kaiHEN needs firmware 23.0.1.

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
   - This also sets the save guard: your games can open only this user's saves, never the spare
     user's exploit save. The restart puts it into effect. The
     [README](README.md#the-save-guard) explains it.
6. Add your games (next section).

Every time you turn the console on, run the launcher (Seedsow → A) on the spare user before playing.

## 5. Add your games

SeedSwap turns your game dumps into games it can run, on the console itself. Use only dumps you made
yourself of games you own, and the `prod.keys` from your own console (see the warning at the top).

1. **Put your keys on the SD card:** copy your `prod.keys` to `SD:/switch/prod.keys`.
2. **Put your dumps on the SD card:** copy them to `SD:/seedswap/nsp/` (make the folder if it isn't
   there), or to the root of the SD card.
   - Formats: `.nsp`, `.nsz`, `.xci` or `.xcz`. Unpack zip, rar or 7z files first.
   - You can add a game's update and its DLC the same way, as their own dumps.
   - Use FTP or a card reader.
   - Converting needs free space for the converted game: about the size of the dump, more for a
     compressed `.nsz` or `.xcz`.
3. **Convert:** open SeedSwap and go to the **Convert** tab (L and R change tabs). Press **Y** to look
   for new dumps, pick one and press **A**.
   - **A game:** it's added to the Library. If its update is on the card too, the update goes in at
     the same time.
   - **An update:** it updates a game that's already in the Library. Keep the base game's dump on the
     card for this. Your save is kept.
   - **DLC:** it's added to its game. Press A again on the DLC to remove it.
4. **Pick a host (once):** in the **Library**, press **-** and pick a host. That's Seedsow, or any
   installed Switch 1 game. Your games run in its place.
   - If the host's row says **start it once first**, SeedSwap doesn't know the host yet. Start
     the host game once from HOME on the user who plays, close it, and open SeedSwap again. If it
     still says so, restart, run the launcher (Seedsow → A) and open SeedSwap again.
   - This goes for Seedsow too, on a fresh setup.
5. **Play:** in the **Library**, pick a game and press **A** (Switch). Then start the host game from
   HOME on the user who plays, as SeedSwap says at the bottom of the screen.
   - On any other user the game finds no save: the save guard keeps it to the user who plays.
   - To change games, open SeedSwap again and switch. Each game keeps its own save.

If a dump doesn't convert, SeedSwap says why: for example, keys that are missing or too old, or a bad
dump. Its **Log** tab has the details.

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
  - If the save changed, write `out/save` again (step 3: back up, then replace).

## If something goes wrong

| Problem | What to do |
|---|---|
| ns2-savekit doesn't show a ✔ next to Seedsow | Check `config/titles.local.json` (step 3, item 2). |
| ns2-savekit says the save doesn't exist (`0x7d402`) | Start Seedsow once on that user and close it fully, then try again. |
| The launcher menu doesn't appear | The save isn't on this user. Check that you started Seedsow on the spare user. |
| "not the expected Seedsow build" | Your Seedsow version isn't supported. Nothing was changed. |
| A says to power off | Hold POWER about 12 seconds → Power off, turn it on, and try again. |
| A game finds no save, or can't save | Start the host on the user who plays. If you just chose that user, restart and run the launcher (A) first. |
| SeedSwap says "The loader is set up for a different user" | Restart and run the launcher (A). If it still says so, open Saves → Y and do what it says. |
| SeedSwap says a host's "permissions aren't known yet" | Start that host game once from HOME, then open SeedSwap again (step 5, item 4). |
| You want the old save back | Take a new backup (2), then choose 3 and point it at the backup folder from step 5. Its files go back; files this install added stay, but the old launcher doesn't use them. |
