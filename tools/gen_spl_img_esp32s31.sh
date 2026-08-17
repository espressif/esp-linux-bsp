#!/bin/bash
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
#
# SPDX-License-Identifier: Apache-2.0

# Wrap the final ESP32-S31 U-Boot SPL binary in the Espressif image format
# consumed by the mask ROM.

set -euo pipefail

SPL_SRAM_ADDR="${SPL_SRAM_ADDR:-0x2F040000}"

usage() {
    echo "Usage: $0 -i <u-boot-spl.bin> -O <spl.img>"
    echo ""
    echo "Options:"
    echo "  -i <u-boot-spl.bin>  Final U-Boot SPL binary"
    echo "  -O <spl.img>         Output Espressif boot image"
    exit "${1:-1}"
}

INPUT=
OUTPUT=

while getopts "i:O:h" opt; do
    case "$opt" in
        i) INPUT="$OPTARG" ;;
        O) OUTPUT="$OPTARG" ;;
        h) usage 0 ;;
        *) usage ;;
    esac
done

[ -n "$INPUT" ] || { echo "Error: SPL input not specified"; usage; }
[ -n "$OUTPUT" ] || { echo "Error: output image not specified"; usage; }
[ -f "$INPUT" ] || { echo "Error: SPL input not found: $INPUT"; exit 1; }

OBJCOPY_BIN=riscv32-buildroot-linux-musl-objcopy
ESPTOOL_BIN=esptool

command -v "$OBJCOPY_BIN" >/dev/null 2>&1 || {
    echo "Error: $OBJCOPY_BIN not found in PATH"
    exit 1
}

command -v "$ESPTOOL_BIN" >/dev/null 2>&1 || {
    echo "Error: $ESPTOOL_BIN not found in PATH"
    exit 1
}

mkdir -p "$(dirname "$OUTPUT")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gen-s31-spl.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

"$OBJCOPY_BIN" -I binary -O elf32-littleriscv -B riscv \
    "$INPUT" "$WORK_DIR/spl1.elf"
"$OBJCOPY_BIN" --change-section-address ".data=$SPL_SRAM_ADDR" \
    --rename-section .data=.text,alloc,load,readonly,code,contents \
    --set-start "$SPL_SRAM_ADDR" \
    "$WORK_DIR/spl1.elf" "$WORK_DIR/spl_wrapped.elf"

"$ESPTOOL_BIN" --chip esp32s31 elf2image \
    --flash-mode dio --flash-freq 80m --flash-size 16MB \
    --output "$OUTPUT" "$WORK_DIR/spl_wrapped.elf"

echo "ESP32-S31 SPL image generated successfully: $OUTPUT"
ls -lh "$OUTPUT"
