#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

BOARD_DIR="$(cd "$(dirname "$0")" && pwd)"
BSP_DIR="$(cd "$BOARD_DIR/../.." && pwd)"
IMAGES_DIR="${1:-${BINARIES_DIR:-}}"

[ -n "$IMAGES_DIR" ] || { echo "Usage: $0 <images_dir>" >&2; exit 1; }

# shellcheck disable=SC1091
source "$BOARD_DIR/layout.cfg"

for name in "$FW_DYNAMIC_ELF" "$SPL_DTB_BIN" "$UBOOT_DTB"; do
    [ -f "$IMAGES_DIR/$name" ] || {
        echo "Missing image artifact: $IMAGES_DIR/$name" >&2
        exit 1
    }
done

find_readelf() {
    local tool

    if [ -n "${READELF:-}" ]; then
        printf '%s\n' "$READELF"
        return
    fi
    if [ -n "${HOST_DIR:-}" ]; then
        for tool in "$HOST_DIR"/bin/riscv*-readelf; do
            [ -x "$tool" ] && { printf '%s\n' "$tool"; return; }
        done
    fi
    command -v readelf || true
}

READELF_TOOL="$(find_readelf)"
[ -x "$READELF_TOOL" ] || { echo "readelf not found" >&2; exit 1; }

opensbi_end=0
while read -r _type _offset _vaddr paddr _filesz memsz _rest; do
    segment_end=$((paddr + memsz))
    (( segment_end > opensbi_end )) && opensbi_end=$segment_end
done < <("$READELF_TOOL" -lW "$IMAGES_DIR/$FW_DYNAMIC_ELF" | awk '$1 == "LOAD"')

if (( opensbi_end == 0 || opensbi_end > SPL_SRAM_ADDR )); then
    printf 'Invalid OpenSBI/SPL layout: OpenSBI end 0x%X, SPL start 0x%X\n' \
        "$opensbi_end" "$((SPL_SRAM_ADDR))" >&2
    exit 1
fi

spl_end=$((SPL_SRAM_ADDR + $(stat -c%s "$IMAGES_DIR/$SPL_DTB_BIN")))
if (( spl_end > SPL_BSS_ADDR )); then
    printf 'Invalid SPL layout: image end 0x%X, BSS start 0x%X\n' \
        "$spl_end" "$((SPL_BSS_ADDR))" >&2
    exit 1
fi

if [ -n "${FDTGET:-}" ]; then
    FDTGET_TOOL="$FDTGET"
elif [ -x "${HOST_DIR:-}/bin/fdtget" ]; then
    FDTGET_TOOL="$HOST_DIR/bin/fdtget"
else
    FDTGET_TOOL="$(command -v fdtget || true)"
fi
[ -x "$FDTGET_TOOL" ] || { echo "fdtget not found" >&2; exit 1; }

read -r ram_addr_hex ram_size_hex _rest < <(
    "$FDTGET_TOOL" -t x "$IMAGES_DIR/$UBOOT_DTB" /memory reg
)
ram_addr=$((0x$ram_addr_hex))
ram_size=$((0x$ram_size_hex))
if (( ram_addr != UBOOT_PRIMARY_RAM_ADDR || ram_size != UBOOT_PRIMARY_RAM_SIZE )); then
    printf 'Invalid U-Boot RAM bank 0: 0x%X/0x%X\n' "$ram_addr" "$ram_size" >&2
    exit 1
fi

"$BSP_DIR/tools/gen_esp_flash_image.sh" "$BOARD_DIR/layout.cfg" "$IMAGES_DIR"

image_size=$(stat -c%s "$IMAGES_DIR/$OUT_IMAGE")
if (( image_size > FLASH_SIZE_BYTES )); then
    printf 'Image size 0x%X exceeds flash size 0x%X\n' \
        "$image_size" "$((FLASH_SIZE_BYTES))" >&2
    exit 1
fi

printf 'Board image verified: %s (%d bytes)\n' \
    "$IMAGES_DIR/$OUT_IMAGE" "$image_size"
