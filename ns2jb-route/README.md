# SeedSwap with ns2jb and SmileBASIC 4 (no Seedsow)

One command on the computer each time the console starts sets up SeedSwap's loader and kaiHEN.
Nothing is written to a save, and nothing stays in memory after a restart.

> **Warning:** SeedSwap can brick your console. It's rare, but it can happen. Use it at your own
> risk.

## You need

- A Switch 2 on firmware 23.0.1.
- SmileBASIC 4 (or its demo) with ns2jb's one-time setup done, on a spare user. Don't play on that
  user: SeedSwap never lets it play, because a game's save would replace SmileBASIC's save there.
- A computer with macOS or Linux, or Windows with WSL, and Node.js 22 or newer.
- [ns2jb](https://gitlab.com/kurumuz/ns2jb) at commit `ae33da1`: download
  [its zip](https://gitlab.com/kurumuz/ns2jb/-/archive/ae33da13542c616874ec23c56b7b6a660745c5e3/ns2jb-ae33da13542c616874ec23c56b7b6a660745c5e3.zip),
  unzip it and rename the folder you get to `ns2jb`. If you have ns2jb from git:
  `git -C ns2jb fetch` and then `git -C ns2jb checkout ae33da1`.
- kaiHEN 20261123: download
  [kaiHEN-20261123.zip](https://github.com/ouncebrew/kaihen/releases/download/20261123/kaiHEN-20261123.zip)
  and unzip it into a folder named `kaiHEN-20261123`.
- SeedSwap's files: the release folder this one is in, or a copy of the repository after
  `build.py` (its `out` folder is found by itself).

## Each time the console starts

1. On the spare user, open SmileBASIC 4 and enter Direct mode.
2. On the computer:

       node seedswap-boot.cjs --ns2jb ~/ns2jb --kaihen ~/kaiHEN-20261123

   Use your own folders. If the computer has more than one network address, add the one the
   console can reach at the end.
3. Enter the lines it shows in SmileBASIC (`LOAD`, `RUN`, `REMOVE`, then `V=START(...)`).
   If a try fails, restart the console, open SmileBASIC 4 again and enter the lines again. The
   command keeps waiting. It can take a few tries.
4. When it says **Done**, close SmileBASIC 4. Don't restart the console.

The first time, SeedSwap's and kaiHEN's files are copied to the SD card, and SeedSwap's loader
starts from the next time. To open the Homebrew Menu, hold R while starting a game.

## In SeedSwap

- Saves → Y: pick the user you play on (not the SmileBASIC user). Then restart and run the command
  again.
- Any installed Switch 1 game can be the host, SmileBASIC 4 too (Library → -).
- When SeedSwap says "run seedswap-boot on the computer", restart the console and do the steps above.
