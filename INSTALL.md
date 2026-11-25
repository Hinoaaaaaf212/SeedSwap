# Installing SeedSwap

> [!WARNING]
> **SeedSwap can brick your console.** It's rare, but it can happen. SeedSwap runs on the same base
> as seedsow-semi-untethered and uses the same Seedsow file system code (Seedsow FS), so anything that
> can go wrong there can go wrong here too. Use it at your own risk.

About half an hour the first time.

## You need

- A Switch 2 on **firmware 23.0.1**, with **[kaiHEN](https://github.com/ouncebrew/kaihen) 20261123**
  on the SD card (20261117.1 also works). Copy **all** of kaiHEN's zip to the root of the SD card,
  not only its `sdcard/` folder: Seedsow needs `bootstrap.bin` and `ro/` too. The first run moves
  the files to `kaihen/bin`.
- **Seedsow Lullaby** installed: the full game or the demo.
- **A spare user** for the exploit save (System Settings → Users → Add User). Don't play on it.
- A PC: Windows for `build.exe`, or any PC with Python 3.8 or newer.

> **Use only your own games and keys:** dumps of games you own, and the `prod.keys` from your own
> console.

## 1. Make the files

Use `build.exe`, or Python if you prefer. Both make the same files: they download a few parts from
their authors and check every file.

**With `build.exe` (Windows):**

1. From the [latest release](../../releases/latest), download **`build.exe`** and **`seedswap.nro`**
   into one folder.
2. Double-click **`build.exe`**. If Windows warns about an unknown app, click **More info → Run
   anyway**.

**With Python (any PC, Python 3.8 or newer):**

1. From the [latest release](../../releases/latest), download **`seedswap.nro`** and **Source code
   (zip)**.
2. Unzip the source code, and put `seedswap.nro` in that folder.
3. Open a terminal there and run `python3 build.py --nro seedswap.nro`. On Windows, use `py` in place
   of `python3`.

Either way, you get an `out` folder:

| Folder | What |
|---|---|
| `out/sd/` | for the SD card |
| `out/save/` | the Seedsow save |

If it stops with "429", wait ten minutes and run it again.

## 2. Copy to the SD card

Copy everything inside `out/sd/` to the root of the SD card. Leave kaiHEN's own files as they are.

## 3. Write the Seedsow save

1. On the Switch 2, switch to the spare user and start Seedsow. Wait for the title screen, then close
   it (HOME → X → Close).
2. Get **[ns2jb](https://gitlab.com/kurumuz/ns2jb)** and
   **[ns2-savekit](https://github.com/dougchansan/ns2-savekit)**. ns2-savekit needs Node.js 20 or newer.
3. In ns2-savekit's folder, create `config/titles.local.json` with:

   ```json
   { "write": [ { "id": "0100ee5021c9e000", "name": "Seedsow Lullaby" } ] }
   ```

   **Using the Seedsow Lullaby demo?** Use this instead:

   ```json
   { "write": [ { "id": "010042d022aea000", "name": "Seedsow Lullaby Demo" } ] }
   ```

4. Start ns2jb as its README says, and leave it running.
5. In ns2-savekit's folder, run `node tools/kit.cjs`. Pick **Seedsow Lullaby**, then the **spare
   user**.
6. Choose **2) Save: back this save up**. Keep this backup.
7. Choose **3) Replace: write files from a directory** and give the full path to `out/save`.

If step 7 fails, restart the console, start ns2jb again, and do steps 5 to 7 again.

### Already have seedsow-semi-untethered?

You can update its save over the network instead of using ns2jb. This way needs Python.

1. Run kaiHEN as usual (Seedsow → A). Copy `out/sd/` to the SD card over FTP.
2. Start Seedsow again and press **Y**. Note the IP address it shows.
3. Download `upload_save.py` from this repository and run:
   `python3 upload_save.py SWITCH-IP --dir out/save`
4. Close Seedsow and start it again. The menu should now say **A : Run kaiHEN + modloader (hardened)**.

If it stops partway, press Y again and run it again.

## 4. First run

1. Restart the Switch 2.
2. On the spare user, start Seedsow and press **A**. Wait for **READY**. This takes one to two
   minutes, and can take a few tries.
3. Close Seedsow. Hold **R** while you start any other game: the Homebrew Menu opens. Open
   **SeedSwap**.
4. Go to **Saves**, press **Y**, and pick the user you play on.
5. Restart, then run the launcher again (Seedsow → A).

Run the launcher (Seedsow → A) every time you turn the console on.

## 5. Add games

1. Copy your `prod.keys` to `SD:/switch/prod.keys`.
2. Copy your dumps to `SD:/seedswap/nsp/`, with their updates and DLC. SeedSwap reads `.nsp`, `.nsz`,
   `.xci` and `.xcz`.
3. In SeedSwap, open **Convert** and press **Y**. Pick the game and press **A**. Its update goes in too.
   - To add a DLC, pick it and press **A**. A game can have up to 16. Press A again to remove one.
4. In **Library**, press **-** and pick a host: Seedsow or any installed Switch 1 game.
   - If it says **start it once first**, start that game from HOME once, then open SeedSwap again.
5. Pick a game and press **A**. Then start the host from HOME, on the user who plays.

Each game keeps its own save.

## Updating

- **New SeedSwap:** copy the new `seedswap.nro` to `SD:/switch/seedswap.nro`.
- **New SD files or save:** do step 1 again with the new release, then repeat steps 2 and 3.
- **New kaiHEN:** copy all of its zip to the root of the SD card. The next run of A moves it into
  place, if this save supports that kaiHEN.

Don't install system updates: kaiHEN needs firmware 23.0.1.

## Launcher buttons

| Button | What it does |
|---|---|
| **A** | Starts kaiHEN with SeedSwap's loader. Use this one. |
| **B** | Same as A, with newer exploit stages. Also copies SeedSwap from the save to the SD card if the save's copy is newer. |
| **Y** | HTTP server (port 8080). |
| Hold **-** | Runs the previous A or B. |

## Problems

| Problem | Fix |
|---|---|
| ns2-savekit shows no ✔ next to Seedsow | Check `config/titles.local.json` (step 3). |
| ns2-savekit says the save doesn't exist (`0x7d402`) | Start Seedsow once on that user, close it, and try again. |
| No launcher menu | Start Seedsow on the spare user. |
| "not the expected Seedsow build" | Your Seedsow version isn't supported. Nothing was changed. |
| "kaiHEN build this save doesn't support" or "required SD files missing" | Copy all of the kaiHEN 20261123 zip (`bootstrap.bin`, `ro` and `sdcard`) to the root of the SD card, and run A again. |
| A says to power off | Hold POWER for 12 seconds → Power off. Turn it on and try again. |
| A game finds no save | Start the host on the user who plays. Just picked that user? Restart and run A first. |
| "The loader is set up for a different user" | Restart and run A. Still there? Saves → Y. |
| "permissions aren't known yet" | Start that host from HOME once, then open SeedSwap again. |
| A dump doesn't convert | SeedSwap says why. The **Log** tab has details. |
| You want your old save back | In ns2-savekit, back up, then **3) Replace** with the folder of your first backup. |
