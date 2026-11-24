# The loader's install image

`../sd/kaihen/ml/install/` holds the install image. Its `runtime.bin`, `gateway.bin` and
`context.bin` are built from [SebaaMG/ns2jb-modloader](https://github.com/SebaaMG/ns2jb-modloader)
(GPL-2.0) at `40b22746`, with the changes in `ns2jb-modloader.patch`. Those changes add:
- the lazy RomFS/code views for hosted games;
- the save guard;
- host slots;
- the `lfs_host_file` report.

`../sd/kaihen/ml/tpl.lua` holds the modloader's call templates.

These tools made those files:

| Tool | What it does |
|---|---|
| `tools/build_install_image.cjs` | Builds the runtime, gateway and context from a modloader checkout with the patch applied. |
| `tools/build_host_image.py` | Builds the host-slot image around it. Run `build --guard-user ffffffffffffffffffffffffffffffff` for a release image. It also has a `guard` command and a `check` command. |
| `tools/export_templates.cjs` | Makes `tpl.lua` from the modloader's prebuilt templates. |

They are copies from the tree they were written in, so their default paths assume that layout.

The copies differ from the originals in two ways:
- the default guard user is "nobody";
- there are no built-in protected users. Each console gets those from `SD:/seedswap/config.ini`.

GPL-2.0, like ns2jb-modloader.
