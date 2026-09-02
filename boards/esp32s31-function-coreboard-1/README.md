# ESP32-S31-Function-CoreBoard-1

Initial BSP profile for the ESP32-S31-Function-CoreBoard-1.

## Hardware

- ESP32-S31 revision v0.0
- 16 MB NOR flash
- 16 MB Octal PSRAM at `0x50000000`
- UART0 console at 115200 8N1

The U-Boot patch places SPL above OpenSBI and relocates U-Boot into PSRAM.
`post-image.sh` checks these memory constraints before creating the flash image.

## Build

Use Buildroot 2025.02 and the Espressif integration branches listed in
`versions.env`. The default paths expect all three repositories to be siblings:

```sh
git clone --branch 2025.02 --depth 1 \
  https://gitlab.com/buildroot.org/buildroot.git buildroot-2025.02
git clone --branch buildroot/v2025.02-esp32s31 \
  https://github.com/espressif/esp-buildroot-external.git
git clone --branch integration/v1.0-esp32s31 \
  https://github.com/espressif/esp-linux-bsp.git

cd esp-linux-bsp
./tools/esp32s31_function_coreboard_1.sh all \
  --esptool /path/to/esptool
```

Override checkout or output paths with `--buildroot`, `--external`, and
`--output`. The generated image is
`output-esp32s31-function-coreboard-1/images/s31_full_flash.bin`.

## Flash

```sh
./tools/esp32s31_function_coreboard_1.sh flash \
  --erase \
  --esptool /path/to/esptool \
  --port /dev/ttyUSB0
```

Monitor `/dev/ttyUSB0` at 115200 8N1. A complete boot reaches the Linux shell.

## Files

- `layout.cfg`: memory and NOR image layout
- `post-image.sh`: board checks and image generation
- `patches/uboot/`: U-Boot board changes
- `versions.env`: validated component revisions
