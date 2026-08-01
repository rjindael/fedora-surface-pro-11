Empty on purpose — no camera kernel patches exist yet (see
[../../CAMERA.md](../../CAMERA.md) and [../../CAMERA_BRINGUP.md](../../CAMERA_BRINGUP.md)).

`install.sh --kernel` already looks for `*.patch` files in this directory
and applies them via `git am` alongside the other patchsets, so once real
camera devicetree/driver patches exist (format them with `git format-patch`,
same as the other `kernel-patches/*/` directories), drop them here and
they'll be picked up automatically — no other changes to `install.sh` needed.
