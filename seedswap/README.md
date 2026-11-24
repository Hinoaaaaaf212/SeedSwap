# SeedSwap (the NRO)

GitHub Actions builds it on every push (`.github/workflows/build.yml`). To build it yourself with
Docker, use the same toolchain image, ouncebrew/ounce-devkit at `75cea55`. That image is devkitPro's
`devkitpro/devkita64:20260219` with devkit `20261115b`.

    git clone https://github.com/ouncebrew/ounce-devkit.git
    git -C ounce-devkit checkout 75cea5538b3a57d8f2ecf53354274cf00a365d20
    docker build -t ounce-devkit ounce-devkit
    cd seedswap
    docker run --rm -v "$PWD:/work" -w /work ounce-devkit make

This makes `seedswap.nro`. The same image gives the same bytes as the tested build that
`SHA256SUMS.txt` lists, and `../build.py` refuses any other.

SeedSwap is GPL-2.0-only (`../LICENSE`), apart from the third-party files listed below.

- `source/`: the app. It reads a dump's keys from the user's `SD:/switch/prod.keys`; no keys are in
  this repository.
- `source/compat/`: the patch engine for Nintendo's per-game patches. It runs code from the
  console's own system files; none of those files are copied here.
- `source/vendor/stb_image.h`: third-party code, MIT or public domain.
- `assets/`: the icon, plus the Ubuntu font and the script that made `source/font_data.c` from it.
