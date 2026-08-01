No applicable `*.patch` files yet — see
[../../CAMERA.md](../../CAMERA.md) and [../../CAMERA_BRINGUP.md](../../CAMERA_BRINGUP.md).

`reference/` holds real out-of-tree driver source relevant to this board's
cameras but not written for it (see `reference/README.md` for exactly what
transfers and what doesn't) — it's reading material, not something to
`git am`.

`install.sh --kernel` already looks for `*.patch` files directly in this
directory (not `reference/`) and applies them via `git am` alongside the
other patchsets, so once real camera devicetree/driver patches exist for
this Qualcomm board (format them with `git format-patch`, same as the other
`kernel-patches/*/` directories), drop them here and they'll be picked up
automatically — no other changes to `install.sh` needed.
