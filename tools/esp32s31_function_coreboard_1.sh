#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 pokersfang
# SPDX-License-Identifier: Apache-2.0

# Build and flash ESP32-S31-Function-CoreBoard-1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BSP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BOARD_DIR="$BSP_DIR/boards/esp32s31-function-coreboard-1"
# shellcheck disable=SC1091
source "$BOARD_DIR/versions.env"

COMMAND="${1:-help}"
if [ "$#" -gt 0 ]; then
    shift
fi

BUILDROOT_DIR="${BUILDROOT_DIR:-$BSP_DIR/../buildroot-2025.02}"
EXTERNAL_DIR="${EXTERNAL_DIR:-$BSP_DIR/../esp-buildroot-external}"
OUTPUT_DIR="${OUTPUT_DIR:-$BSP_DIR/output-esp32s31-function-coreboard-1}"
ESPTOOL="${ESP_ESPTOOL:-}"
SERIAL_PORT="${SERIAL_PORT:-/dev/ttyUSB0}"
FLASH_BAUD="${FLASH_BAUD:-921600}"
JOBS="${JOBS:-$(nproc)}"
DOWNLOAD_DIR="${BR2_DL_DIR:-}"
ERASE_FIRST=0

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  configure     Create the board's Buildroot configuration
  build         Apply the board configuration and build a complete image
  all           Configure and build from the validated component set
  flash         Flash the generated image; add --erase for a full-chip erase
  erase-flash   Erase the complete 16 MB flash device

Options:
  --buildroot PATH   Buildroot 2025.02 checkout
  --external PATH    esp-buildroot-external checkout
  --output PATH      Buildroot output directory
  --esptool PATH     ESP32-S31-capable esptool executable
  --port DEVICE      Serial port (default: /dev/ttyUSB0)
  --baud RATE        Flash baud rate (default: 921600)
  --jobs COUNT       Parallel build jobs
  --erase            Erase the chip before the flash command

The matching environment variables are BUILDROOT_DIR, EXTERNAL_DIR,
OUTPUT_DIR, BR2_DL_DIR, ESP_ESPTOOL, SERIAL_PORT, FLASH_BAUD, and JOBS.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --buildroot)
            BUILDROOT_DIR="${2:?missing path after --buildroot}"
            shift 2
            ;;
        --external)
            EXTERNAL_DIR="${2:?missing path after --external}"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="${2:?missing path after --output}"
            shift 2
            ;;
        --esptool)
            ESPTOOL="${2:?missing path after --esptool}"
            shift 2
            ;;
        --port)
            SERIAL_PORT="${2:?missing device after --port}"
            shift 2
            ;;
        --baud)
            FLASH_BAUD="${2:?missing rate after --baud}"
            shift 2
            ;;
        --jobs)
            JOBS="${2:?missing count after --jobs}"
            shift 2
            ;;
        --erase)
            ERASE_FIRST=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "✗ Error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

BUILDROOT_DIR="$(readlink -m "$BUILDROOT_DIR")"
EXTERNAL_DIR="$(readlink -m "$EXTERNAL_DIR")"
OUTPUT_DIR="$(readlink -m "$OUTPUT_DIR")"
DOWNLOAD_DIR="$(readlink -m "${DOWNLOAD_DIR:-$BUILDROOT_DIR/dl}")"

check_source_trees() {
    [ -f "$BUILDROOT_DIR/Makefile" ] || {
        echo "✗ Error: Buildroot checkout not found: $BUILDROOT_DIR" >&2
        exit 1
    }
    [ -f "$EXTERNAL_DIR/configs/espressif_esp32s31_function_core_board_nor_defconfig" ] || {
        echo "✗ Error: ESP32-S31 external tree not found: $EXTERNAL_DIR" >&2
        exit 1
    }
    [ -x "$BUILDROOT_DIR/utils/config" ] || {
        echo "✗ Error: Buildroot config helper not found" >&2
        exit 1
    }

    if [ -d "$BUILDROOT_DIR/.git" ]; then
        actual="$(git -C "$BUILDROOT_DIR" rev-parse HEAD)"
        if [ "$actual" != "$BUILDROOT_COMMIT" ]; then
            echo "! Warning: Buildroot HEAD $actual differs from validated $BUILDROOT_COMMIT"
        fi
    fi
    if [ -d "$EXTERNAL_DIR/.git" ]; then
        actual="$(git -C "$EXTERNAL_DIR" rev-parse HEAD)"
        if [ "$actual" != "$ESP_BUILDROOT_EXTERNAL_COMMIT" ]; then
            echo "! Warning: external-tree HEAD $actual differs from validated $ESP_BUILDROOT_EXTERNAL_COMMIT"
        fi
    fi
}

validate_component_ref() {
    local name="$1"
    local package="$2"
    local url="$3"
    local branch="$4"
    local expected="$5"
    local cache="$DOWNLOAD_DIR/$package/git"
    local actual=""

    # Prefer the remote branch so an upstream moving-head change is detected.
    # If the network is unavailable, an already populated Buildroot cache is
    # acceptable only when its branch still resolves to the validated commit.
    actual="$(timeout 30 git ls-remote "$url" "refs/heads/$branch" 2>/dev/null | \
        awk 'NR == 1 { print $1 }')" || true
    if [ -z "$actual" ] && [ -d "$cache/.git" ]; then
        actual="$(git -C "$cache" rev-parse -q --verify \
            "refs/remotes/origin/$branch^{commit}" 2>/dev/null)" || true
        if [ -z "$actual" ]; then
            actual="$(git -C "$cache" rev-parse -q --verify \
                "refs/heads/$branch^{commit}" 2>/dev/null)" || true
        fi
        [ -n "$actual" ] && echo "! Warning: validated $name from local download cache (remote unavailable)"
    fi

    [ -n "$actual" ] || {
        echo "✗ Error: cannot resolve $name branch $branch" >&2
        exit 1
    }
    if [ "$actual" != "$expected" ]; then
        echo "✗ Error: $name branch moved since hardware validation" >&2
        echo "  branch  : $branch" >&2
        echo "  expected: $expected" >&2
        echo "  actual  : $actual" >&2
        echo "Update the board patch/version manifest only after hardware revalidation." >&2
        exit 1
    fi
    echo "  $name: $branch @ $actual"
}

validate_component_set() {
    echo "Validated component branches:"
    validate_component_ref U-Boot uboot "$UBOOT_REPO_URL" \
        "$UBOOT_BRANCH" "$UBOOT_COMMIT"
    validate_component_ref OpenSBI opensbi "$OPENSBI_REPO_URL" \
        "$OPENSBI_BRANCH" "$OPENSBI_COMMIT"
    validate_component_ref Linux linux "$LINUX_REPO_URL" \
        "$LINUX_BRANCH" "$LINUX_COMMIT"
}

apply_board_config() {
    local config_file="$OUTPUT_DIR/.config"
    local config_tool="$BUILDROOT_DIR/utils/config"

    [ -f "$config_file" ] || {
        echo "✗ Error: Buildroot is not configured: $config_file" >&2
        exit 1
    }

    "$config_tool" --file "$config_file" \
        --set-str TARGET_UBOOT_CUSTOM_REPO_VERSION "$UBOOT_BRANCH" \
        --set-str TARGET_UBOOT_PATCH "$BOARD_DIR/patches/uboot" \
        --set-str TARGET_OPENSBI_CUSTOM_REPO_VERSION "$OPENSBI_BRANCH" \
        --set-str LINUX_KERNEL_CUSTOM_REPO_VERSION "$LINUX_BRANCH" \
        --set-str BR2_ROOTFS_POST_IMAGE_SCRIPT "$BOARD_DIR/post-image.sh" \
        --set-str BR2_ROOTFS_POST_IMAGE_SCRIPT_ARGS ""

    make -C "$BUILDROOT_DIR" \
        BR2_EXTERNAL="$EXTERNAL_DIR" \
        O="$OUTPUT_DIR" olddefconfig

    echo "Board configuration applied:"
    echo "  U-Boot : $UBOOT_BRANCH"
    echo "  OpenSBI: $OPENSBI_BRANCH"
    echo "  Linux  : $LINUX_BRANCH"
    echo "  patches: $BOARD_DIR/patches/uboot"
    echo "  image  : $BOARD_DIR/post-image.sh"
}

configure_board() {
    check_source_trees
    validate_component_set
    make -C "$BUILDROOT_DIR" \
        BR2_EXTERNAL="$EXTERNAL_DIR" \
        O="$OUTPUT_DIR" \
        espressif_esp32s31_function_core_board_nor_defconfig
    apply_board_config
}

resolve_esptool() {
    local candidate

    if [ -n "$ESPTOOL" ]; then
        candidate="$ESPTOOL"
    elif command -v esptool >/dev/null 2>&1; then
        candidate="$(command -v esptool)"
    elif command -v esptool.py >/dev/null 2>&1; then
        candidate="$(command -v esptool.py)"
    else
        echo "✗ Error: esptool not found; use --esptool or ESP_ESPTOOL" >&2
        exit 1
    fi

    if ! "$candidate" version >/dev/null 2>&1; then
        echo "✗ Error: esptool cannot run: $candidate" >&2
        exit 1
    fi
    ESPTOOL="$candidate"
}

build_board() {
    check_source_trees
    if [ ! -f "$OUTPUT_DIR/.config" ]; then
        configure_board
    else
        validate_component_set
        apply_board_config
    fi
    build_configured_board
}

build_configured_board() {
    resolve_esptool

    # Re-extract U-Boot so local patch updates are applied.
    make -C "$BUILDROOT_DIR" O="$OUTPUT_DIR" uboot-dirclean
    ESP_ESPTOOL="$ESPTOOL" \
        make -C "$BUILDROOT_DIR" O="$OUTPUT_DIR" -j"$JOBS"

    image="$OUTPUT_DIR/images/s31_full_flash.bin"
    [ -f "$image" ] || {
        echo "✗ Error: expected image not generated: $image" >&2
        exit 1
    }
    echo "Image ready: $image"
    sha256sum "$image"
}

check_serial_port() {
    [ -c "$SERIAL_PORT" ] || {
        echo "✗ Error: serial device not found: $SERIAL_PORT" >&2
        exit 1
    }
    if command -v fuser >/dev/null 2>&1 &&
       fuser "$SERIAL_PORT" >/dev/null 2>&1; then
        echo "✗ Error: serial device is busy: $SERIAL_PORT" >&2
        fuser -v "$SERIAL_PORT" >&2 || true
        exit 1
    fi
}

erase_flash() {
    resolve_esptool
    check_serial_port
    "$ESPTOOL" --chip esp32s31 --port "$SERIAL_PORT" \
        --baud "$FLASH_BAUD" erase-flash
}

flash_board() {
    local image="$OUTPUT_DIR/images/s31_full_flash.bin"

    resolve_esptool
    check_serial_port
    [ -f "$image" ] || {
        echo "✗ Error: image not found: $image" >&2
        exit 1
    }
    if [ "$ERASE_FIRST" = 1 ]; then
        "$ESPTOOL" --chip esp32s31 --port "$SERIAL_PORT" \
            --baud "$FLASH_BAUD" erase-flash
    fi
    "$ESPTOOL" --chip esp32s31 --port "$SERIAL_PORT" \
        --baud "$FLASH_BAUD" write-flash \
        --flash-mode dio --flash-freq 80m --flash-size 16MB \
        0x0 "$image"
    echo "Flash verified. Open $SERIAL_PORT at 115200 8N1."
}

case "$COMMAND" in
    configure)
        configure_board
        ;;
    build)
        build_board
        ;;
    all)
        configure_board
        build_configured_board
        ;;
    flash)
        flash_board
        ;;
    erase-flash)
        erase_flash
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        echo "✗ Error: unknown command: $COMMAND" >&2
        usage >&2
        exit 1
        ;;
esac
