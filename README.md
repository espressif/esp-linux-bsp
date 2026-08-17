# ESP32-S31 Linux BSP

This repository contains the image layout and packaging tools used by the
ESP32-S31 Buildroot integration.

## Buildroot packaging

Buildroot installs `tools/` and `configs/` as a host package. Its post-image
hook invokes:

```sh
tools/buildroot_post_image.sh esp32s31 nor <images_dir>
```

The packager wraps the U-Boot SPL in the Espressif image format and merges the
SPL, U-Boot FIT, Linux device tree, XIP kernel, and cramfs root filesystem into
`s31_full_flash.bin`.

Set `ESP_ESPTOOL` when `esptool` is not available in `PATH`.

## Component verification helpers

- `tools/gen_spl_img_esp32s31.sh` wraps a standalone U-Boot SPL binary.
- `tools/gen_fit_boot0_esp32s31.sh` creates a diagnostic U-Boot FIT.

The normal Buildroot flow uses the U-Boot binman-generated `u-boot.itb`; the
FIT helper is intended only for component-level testing.
