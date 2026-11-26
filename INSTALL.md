# Installing SeedSwap

> [!CAUTION]
> **This is the experimental branch.** It adds Add to HOME, which installs your games on the HOME
> menu. I haven't had much time to test it yet, so expect bugs. For the stable version, use the
> **[latest release](../../releases/latest)** and the `main` branch.
>
> **Nintendo can ban your console.** Installing games Nintendo didn't sign, and patching the system so
> they start, is the kind of thing Nintendo bans consoles for. Use it at your own risk!!

> [!WARNING]
> **SeedSwap can brick your console.** It's rare, but it can happen. SeedSwap runs on the same base
> as seedsow-semi-untethered and uses the same Seedsow file system code (Seedsow FS), so anything that
> can go wrong there can go wrong here too. Use it at your own risk.

About half an hour the first time.

## You need

- A Switch 2 on **firmware 23.0.1**, with **[kaiHEN 20261117.1](https://github.com/ouncebrew/kaihen/releases/tag/20261117.1)**
  on the SD card. Copy **everything** in kaiHEN's zip to the root of the SD card. The first run moves
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

1. From the [experimental release](../../releases/tag/v1.0.1-experimental), download **`build.exe`** and **`seedswap.nro`**
   into one folder.
2. Double-click **`build.exe`**. If Windows warns about an unknown app, click **More info → Run
   anyway**.

**With Python (any PC, Python 3.8 or newer):**

1. From the [experimental release](../../releases/tag/v1.0.1-experimental), download **`seedswap.nro`** and **Source code
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
   `.xci` and `.xcz`. On a FAT32 card, a dump over 4 GB can be a split folder (`game.nsp/00`, `01`, ...).
3. In SeedSwap, open **Convert** and press **Y**. Pick the game and press **A**. Its update goes in too.
   - To add a DLC, pick it and press **A**. A game can have up to 100. Press A again to remove one.
   - To add all of a game's DLC at once, pick one of its DLC, press **A**, then **X**. Afterwards
     SeedSwap offers to delete the DLC dumps. Keep them if you'll update the game here later.
4. In **Library**, press **-** and pick a host: Seedsow or any installed Switch 1 game.
   - If it says **start it once first**, start that game from HOME once, then open SeedSwap again.
5. Pick a game and press **A**. Then start the host from HOME, on the user who plays.

Each game keeps its own save.

## 6. Put a game on the HOME menu (experimental)

This installs a game on the SD card with its own HOME icon, so you start it from HOME instead of
through a host. Read the ban warning at the top first.

1. Copy the game's dump to `SD:/seedswap/nsp/`, with its update if you have one, and your
   `prod.keys` to `SD:/switch/prod.keys`.
2. In SeedSwap, open **Convert**, pick the game and press **X**. Check the name, version and size,
   then press **A**.
3. Start the game from HOME.

- It starts only while the loader is in: run the launcher (Seedsow → A) after every restart first.
- It has its own save, separate from the copy in SeedSwap's library.
- To take it off HOME, pick the same dump in **Convert**, press **X**, then **X** again. Its save is
  kept.

## Without Seedsow: SmileBASIC 4 and ns2jb

No Seedsow? SeedSwap also runs with ns2jb and SmileBASIC 4. Nothing is written to a save, but you
run one command on a computer every time you turn the console on.

**You need:**

- SmileBASIC 4 or its demo, with [ns2jb](https://gitlab.com/kurumuz/ns2jb)'s one-time setup done, on
  a spare user. Don't play on that user: SeedSwap never lets it play.
- A computer with macOS or Linux, or Windows with WSL, and Node.js 22 or newer.
- ns2jb at commit `ae33da1`: download
  [its zip](https://gitlab.com/kurumuz/ns2jb/-/archive/ae33da13542c616874ec23c56b7b6a660745c5e3/ns2jb-ae33da13542c616874ec23c56b7b6a660745c5e3.zip),
  unzip it and rename the folder you get to `ns2jb`. If you have ns2jb from git:
  `git -C ns2jb fetch`, then `git -C ns2jb checkout ae33da1`.
- kaiHEN 20261117.1: download
  [kaiHEN-20261117.1.zip](https://github.com/ouncebrew/kaihen/releases/download/20261117.1/kaiHEN-20261117.1.zip)
  and unzip it into a folder named `kaiHEN-20261117.1`.

**Steps:**

1. Make the files with Python (step 1). You need the source code folder: the command is in its
   `ns2jb-route` folder.
2. On the spare user, open SmileBASIC 4 and enter Direct mode.
3. In the source code folder, run:

   ```sh
   node ns2jb-route/seedswap-boot.cjs --ns2jb ~/ns2jb --kaihen ~/kaiHEN-20261117.1
   ```

   Use your own folders. If the computer has more than one network address, add the one the console
   can reach at the end.
4. Enter the lines it shows in SmileBASIC. If a try fails, restart the console, open SmileBASIC 4
   again and enter the lines again. The command keeps waiting.
5. When it says **Done**, close SmileBASIC 4. Don't restart.
6. The first time, it copies the files to the SD card. Restart and do steps 2 to 5 again: now
   SeedSwap's loader is on too. Then do steps 3 and 4 of **First run**, and run the command (not the
   launcher) where it says the launcher.

Do steps 2 to 5 every time you turn the console on. Add games as in step 5 above; SmileBASIC 4 can be
the host too.

## Updating

- **New SeedSwap:** copy the new `seedswap.nro` to `SD:/switch/seedswap.nro`.
- **New SD files or save:** do step 1 again with the new release, then repeat steps 2 and 3.
- **Coming from 0.14 or older:** you need the new SD files (HOME games need the new loader image).
  They reset the play user and any hosts you added: after the next launcher run, go to **Saves**,
  press **Y** and pick your user again, restart, and add your hosts again (**Library**, **-**).
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
| "kaiHEN build this save doesn't support" or "required SD files missing" | Copy everything in the kaiHEN 20261117.1 zip to the root of the SD card, and run A again. |
| A says to power off | Hold POWER for 12 seconds → Power off. Turn it on and try again. |
| A game finds no save | Start the host on the user who plays. Just picked that user? Restart and run A first. |
| "The loader is set up for a different user" | Restart and run A. Still there? Saves → Y. |
| "permissions aren't known yet" | Start that host from HOME once, then open SeedSwap again. |
| A dump doesn't convert | SeedSwap says why. The **Log** tab has details. |
| You want your old save back | In ns2-savekit, back up, then **3) Replace** with the folder of your first backup. |
| seedswap-boot: "isn't commit ae33da1" | Get ns2jb at commit `ae33da1` (zip link under **You need** above). |
| seedswap-boot: "This kaiHEN build isn't one SeedSwap knows" | Use [kaiHEN 20261117.1](https://github.com/ouncebrew/kaihen/releases/download/20261117.1/kaiHEN-20261117.1.zip). |
| seedswap-boot: "restart the console" | Restart, open SmileBASIC 4, and run the command again. |
