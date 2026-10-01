#!/bin/bash
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
#
# SPDX-License-Identifier: Apache-2.0

# ESP32-S31 esptool/XIP flash image packager.
#
# Wraps the U-Boot SPL into an Espressif ESP image (esptool elf2image) and
# merges every raw flash slot into one flashable image. The FIT (OpenSBI +
# U-Boot proper + control dtb) is NOT assembled here -- U-Boot's binman
# already produced the itb.
#
# Usage: gen_esp_flash_image.sh <chip-layout.cfg> <images_dir>
#
# Exports ESP_LAYOUT_BASE (default: configs/esp32s31-layout.cfg) before sourcing <chip-layout.cfg>.
#
# Inputs expected in <images_dir> (produced by Buildroot), named by the
# layout configuration:
#   $SPL_DTB_BIN   (u-boot-spl-dtb.bin) SPL flat binary + appended control dtb
#   $UBOOT_ITB     (u-boot.itb)         FIT: OpenSBI fw_dynamic + U-Boot + dtb
#   <kernel>.dtb   ($BASE_DTB, or BR2_LINUX_KERNEL_INTREE_DTS_NAME if set)
#   $KERNEL_IMAGE  (xipImage)   kernel (fetched by name from $BUILD_DIR if unstaged)
#   $ROOTFS_IMAGE  (rootfs.cramfs) root filesystem (optional; merged if present)
# Output: $OUT_IMAGE (s31_full_flash.bin), via intermediate $SPL_APP_BIN.
#
# Tool resolution (env override -> HOST_DIR -> PATH):
#   ESPTOOL : $ESP_ESPTOOL -> $HOST_DIR/bin/esptool[.py] -> esptool
#   OBJCOPY : $OBJCOPY -> $HOST_DIR/bin/riscv*-objcopy -> riscv32 objcopy on PATH

set -euo pipefail

CFG="${1:?usage: gen_esp_flash_image.sh <chip-layout.cfg> <images_dir>}"
IMAGES_DIR="${2:?usage: gen_esp_flash_image.sh <chip-layout.cfg> <images_dir>}"

[ -f "$CFG" ] || { echo "✗ Error: layout cfg not found: $CFG"; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${ESP_LAYOUT_BASE:=$SCRIPT_DIR/../configs/esp32s31-layout.cfg}"
export ESP_LAYOUT_BASE
echo "gen_esp_flash_image: layout $CFG"
# shellcheck disable=SC1090
source "$CFG"

: "${CHIP:?CHIP not set in $CFG}"
: "${SPL_SRAM_ADDR:?SPL_SRAM_ADDR not set in $CFG}"
: "${ESPTOOL_FLASH:?ESPTOOL_FLASH not set in $CFG}"
: "${BUILD_DIR:=$IMAGES_DIR/../build}"

: "${FLASH_SIZE:?FLASH_SIZE not set in $CFG}"
: "${SLOT_SPL:?SLOT_SPL not set in $CFG}"
: "${SLOT_UBOOT_ITB:?SLOT_UBOOT_ITB not set in $CFG}"
: "${SLOT_DTB:?SLOT_DTB not set in $CFG}"
: "${SLOT_KERNEL:?SLOT_KERNEL not set in $CFG}"
: "${SLOT_ROOTFS:?SLOT_ROOTFS not set in $CFG}"

# Artifact names, overridable per board in the layout cfg.
: "${SPL_DTB_BIN:=u-boot-spl-dtb.bin}"
: "${UBOOT_ITB:=u-boot.itb}"
: "${BASE_DTB:=esp32s31.dtb}"
: "${KERNEL_IMAGE:=xipImage}"
: "${ROOTFS_IMAGE:=rootfs.cramfs}"
: "${SPL_APP_BIN:=spl_app.bin}"
: "${OUT_IMAGE:=s31_full_flash.bin}"

echo "gen_esp_flash_image: layout spl=$SLOT_SPL uboot_itb=$SLOT_UBOOT_ITB" \
     "dtb=$SLOT_DTB kernel=$SLOT_KERNEL rootfs=$SLOT_ROOTFS flash=$FLASH_SIZE"

# --- Resolve esptool -----------------------------------------------------------
if [ -n "${ESP_ESPTOOL:-}" ]; then
    ESPTOOL="$ESP_ESPTOOL"
elif [ -x "${HOST_DIR:-}/bin/esptool" ]; then
    ESPTOOL="${HOST_DIR}/bin/esptool"
elif [ -x "${HOST_DIR:-}/bin/esptool.py" ]; then
    ESPTOOL="${HOST_DIR}/bin/esptool.py"
else
    ESPTOOL="esptool"
fi
command -v "$ESPTOOL" >/dev/null 2>&1 || {
    echo "✗ Error: esptool not found (set ESP_ESPTOOL or add it to PATH)"
    exit 1
}

# --- Resolve objcopy (must understand elf32-littleriscv / -B riscv) ------------
if [ -n "${OBJCOPY:-}" ]; then
    :
else
    for candidate in "${HOST_DIR:-/nonexistent}"/bin/riscv*-objcopy; do
        if [ -x "$candidate" ]; then
            OBJCOPY="$candidate"
            break
        fi
    done
    if [ -z "${OBJCOPY:-}" ] &&
       command -v riscv32-buildroot-linux-musl-objcopy >/dev/null 2>&1; then
        OBJCOPY="riscv32-buildroot-linux-musl-objcopy"
    fi
fi
[ -n "${OBJCOPY:-}" ] || {
    echo "✗ Error: no RISC-V objcopy found (set OBJCOPY or HOST_DIR)"
    exit 1
}

cd "$IMAGES_DIR"

# --- Kernel DTB name -----------------------------------------------------------
if [ -n "${BR2_LINUX_KERNEL_INTREE_DTS_NAME:-}" ]; then
    DTB="$(basename "${BR2_LINUX_KERNEL_INTREE_DTS_NAME%% *}").dtb"
else
    DTB="$BASE_DTB"
fi

# --- Stage the kernel image if Buildroot left it in the kernel build dir -------
if [ ! -f "$KERNEL_IMAGE" ]; then
    KDIR=
    for candidate in "$BUILD_DIR"/linux-*/; do
        if [ -d "$candidate" ]; then
            KDIR="$candidate"
            break
        fi
    done
    [ -n "$KDIR" ] && cp "$KDIR/arch/riscv/boot/$KERNEL_IMAGE" "$KERNEL_IMAGE"
fi

for f in "$SPL_DTB_BIN" "$UBOOT_ITB" "$DTB" "$KERNEL_IMAGE"; do
    [ -f "$f" ] || { echo "✗ Error: required input missing: $IMAGES_DIR/$f"; exit 1; }
done

# --- Wrap the SPL into an ESP image --------------------------------------------
# Repackage the flat SPL (with its appended control dtb) into a single-segment
# ELF at SPL_SRAM_ADDR, then esptool it. elf2image on the native u-boot-spl ELF
# would miss the appended dtb, so we go via the flat binary.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gen-s31-flash.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
echo "gen_esp_flash_image: wrapping SPL -> $SPL_APP_BIN (load $SPL_SRAM_ADDR)"
"$OBJCOPY" -I binary -O elf32-littleriscv -B riscv \
    "$SPL_DTB_BIN" "$WORK_DIR/spl1.elf"
"$OBJCOPY" --change-section-address ".data=$SPL_SRAM_ADDR" \
    --rename-section .data=.text,alloc,load,readonly,code,contents \
    --set-start "$SPL_SRAM_ADDR" \
    "$WORK_DIR/spl1.elf" "$WORK_DIR/spl_wrapped.elf"
# shellcheck disable=SC2086
"$ESPTOOL" --chip "$CHIP" elf2image $ESPTOOL_FLASH \
    --output "$SPL_APP_BIN" "$WORK_DIR/spl_wrapped.elf"

# --- Every artifact must fit its slot ------------------------------------------
SLOTS=(
    "$SLOT_SPL $SPL_APP_BIN spl"
    "$SLOT_UBOOT_ITB $UBOOT_ITB uboot_itb"
    "$SLOT_DTB $DTB dtb"
    "$SLOT_KERNEL $KERNEL_IMAGE kernel"
)
if [ -f "$ROOTFS_IMAGE" ]; then
    SLOTS+=( "$SLOT_ROOTFS $ROOTFS_IMAGE rootfs" )
else
    echo "gen_esp_flash_image: note - $ROOTFS_IMAGE not staged, omitting its slot"
fi
prev_off= prev_file= prev_name=
while read -r off file name; do
    if [ -n "$prev_off" ]; then
        size=$(( $(wc -c <"$prev_file") ))
        if [ $((prev_off + size)) -gt "$off" ]; then
            printf '✗ Error: %s is %d bytes but the %s slot at 0x%X holds %d (next slot %s at 0x%X)\n' \
                "$prev_file" "$size" "$prev_name" "$prev_off" $((off - prev_off)) "$name" "$off"
            exit 1
        fi
    fi
    prev_off=$off prev_file=$file prev_name=$name
done < <(for s in "${SLOTS[@]}"; do
             set -- $s
             printf '%d %s %s\n' "$(( $1 ))" "$2" "$3"
         done | sort -n)
size=$(( $(wc -c <"$prev_file") ))
if [ $((prev_off + size)) -gt $((FLASH_SIZE)) ]; then
    printf '✗ Error: %s is %d bytes but the %s slot at 0x%X holds %d (flash ends at 0x%X)\n' \
        "$prev_file" "$size" "$prev_name" "$prev_off" $((FLASH_SIZE - prev_off)) $((FLASH_SIZE))
    exit 1
fi

# --- Merge every present slot into one flashable image -------------------------
echo "gen_esp_flash_image: merging slots -> $OUT_IMAGE"
MERGE_ARGS=(
    "$SLOT_SPL"       "$SPL_APP_BIN"
    "$SLOT_UBOOT_ITB" "$UBOOT_ITB"
    "$SLOT_DTB"       "$DTB"
    "$SLOT_KERNEL"    "$KERNEL_IMAGE"
)
if [ -f "$ROOTFS_IMAGE" ]; then
    MERGE_ARGS+=( "$SLOT_ROOTFS" "$ROOTFS_IMAGE" )
fi
# No --pad-to-size: the image ends at the last slot for fast flashing.
# shellcheck disable=SC2086
"$ESPTOOL" --chip "$CHIP" merge-bin -o "$OUT_IMAGE" --format raw \
    $ESPTOOL_FLASH "${MERGE_ARGS[@]}"

echo "gen_esp_flash_image: $OUT_IMAGE ($(( $(wc -c <"$OUT_IMAGE") )) bytes) ready in $IMAGES_DIR"
