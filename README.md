# ESP32-S31 Linux BSP

> **⚠️ Espressif Fork**: This repository is Espressif's Linux BSP with support for ESP32S31.  
> **⚠️ Developer Preview**: This branch (`integration/v1.0-esp32s31`) is currently in developer preview and is **not yet recommended for production use**. 
> For branch strategy and maintenance policy, see the [Branch Strategy](#branch-strategy) section below.

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

---

## Branch Strategy

### `integration/v1.0-esp32s31` - Developer Preview

This branch is currently in **developer preview** and is **not yet recommended for production use**.

#### Purpose
- Quick access to ESP32-S31 BSP support
- Technical validation and feedback collection
- Evaluation and testing purposes only

#### What to Expect
- **Limited chip support**: ESP32-S31 only
- **Irregular updates**: No scheduled release cadence
- **Breaking changes**: May occur without notice
- **Limited feature acceptance**: New feature requests may not be accepted during the Developer Preview
- **Bug fixes**: Bug fixes may be addressed on a best-effort basis during the Developer Preview

#### Maintenance Policy
- Bug reports are welcome but may be deferred
- Pull requests reviewed on a case-by-case basis
- No API/ABI compatibility guarantees
- Best-effort support only

#### Recommended For
- Early adopters wanting immediate ESP32-S31 access
- Hardware evaluation and prototyping
- Testing and providing feedback to Espressif

#### Not Recommended For
- Production deployments
- Long-term projects requiring stability
- Critical systems
