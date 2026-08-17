#!/bin/bash
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
#
# SPDX-License-Identifier: Apache-2.0

# Buildroot post-image entry point for ESP32-S31 NOR images.

set -euo pipefail

BOARD="${1:-}"
STORAGE="${2:-}"
IMAGES_DIR="${3:-${BINARIES_DIR:-}}"

if [ "$BOARD" != "esp32s31" ] || [ "$STORAGE" != "nor" ] ||
   [ -z "$IMAGES_DIR" ]; then
    echo "Usage: $0 esp32s31 nor <images_dir>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export BUILD_DIR="${BUILD_DIR:-$IMAGES_DIR/../build}"

exec "$SCRIPT_DIR/gen_esp_flash_image.sh" \
    "$SCRIPT_DIR/../configs/esp32s31-layout.cfg" "$IMAGES_DIR"
