#!/bin/bash
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
#
# SPDX-License-Identifier: Apache-2.0

# Generate the U-Boot FIT loaded by the ESP32-S31 SPL.
#
# The FIT contains OpenSBI fw_dynamic, U-Boot proper without its appended DTB,
# and the U-Boot control DTB. Its addresses must match the ESP32-S31 U-Boot
# configuration and arch/riscv/dts/esp32s31-u-boot.dtsi.

set -euo pipefail

OPENSBI_LOAD_ADDR=0x2F000000
UBOOT_LOAD_ADDR=0x50400000
FDT_LOAD_ADDR=0x50300000

usage() {
    echo "Usage: $0 -o <fw_dynamic.bin> -u <u-boot-nodtb.bin> -d <u-boot.dtb> -O <u-boot.itb> [-t <tmp_its>]"
    echo ""
    echo "Options:"
    echo "  -o <fw_dynamic.bin>      OpenSBI dynamic firmware"
    echo "  -u <u-boot-nodtb.bin>    U-Boot proper without appended DTB"
    echo "  -d <u-boot.dtb>          U-Boot control device tree"
    echo "  -O <u-boot.itb>          Output FIT image"
    echo "  -t <tmp_its>             Keep the generated ITS at this path"
    exit "${1:-1}"
}

absolute_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *) printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")" ;;
    esac
}

OPENSBI=
UBOOT=
FDT=
OUTPUT=
ITS_FILE=

while getopts "o:u:d:O:t:h" opt; do
    case "$opt" in
        o) OPENSBI="$OPTARG" ;;
        u) UBOOT="$OPTARG" ;;
        d) FDT="$OPTARG" ;;
        O) OUTPUT="$OPTARG" ;;
        t) ITS_FILE="$OPTARG" ;;
        h) usage 0 ;;
        *) usage ;;
    esac
done

[ -n "$OPENSBI" ] || { echo "Error: OpenSBI fw_dynamic binary not specified"; usage; }
[ -n "$UBOOT" ] || { echo "Error: U-Boot nodtb binary not specified"; usage; }
[ -n "$FDT" ] || { echo "Error: U-Boot DTB not specified"; usage; }
[ -n "$OUTPUT" ] || { echo "Error: output ITB not specified"; usage; }

[ -f "$OPENSBI" ] || { echo "Error: OpenSBI file not found: $OPENSBI"; exit 1; }
[ -f "$UBOOT" ] || { echo "Error: U-Boot file not found: $UBOOT"; exit 1; }
[ -f "$FDT" ] || { echo "Error: DTB file not found: $FDT"; exit 1; }

OPENSBI="$(absolute_path "$OPENSBI")"
UBOOT="$(absolute_path "$UBOOT")"
FDT="$(absolute_path "$FDT")"

if [ -n "${MKIMAGE:-}" ]; then
    MKIMAGE_BIN="$MKIMAGE"
elif [ -n "${HOST_DIR:-}" ] && [ -x "${HOST_DIR}/bin/mkimage" ]; then
    MKIMAGE_BIN="${HOST_DIR}/bin/mkimage"
else
    MKIMAGE_BIN=mkimage
fi

command -v "$MKIMAGE_BIN" >/dev/null 2>&1 || {
    echo "Error: mkimage not found (set MKIMAGE or HOST_DIR)"
    exit 1
}

mkdir -p "$(dirname "$OUTPUT")"

CLEANUP_ITS=0
if [ -z "$ITS_FILE" ]; then
    ITS_FILE="${OUTPUT%.itb}.its"
    CLEANUP_ITS=1
fi
mkdir -p "$(dirname "$ITS_FILE")"

cleanup() {
    if [ "$CLEANUP_ITS" -eq 1 ]; then
        rm -f "$ITS_FILE"
    fi
}
trap cleanup EXIT

cat > "$ITS_FILE" <<EOF
/dts-v1/;

/ {
    description = "ESP32-S31 SPL FIT";
    #address-cells = <1>;

    images {
        opensbi {
            description = "OpenSBI";
            data = /incbin/("$OPENSBI");
            type = "firmware";
            os = "opensbi";
            arch = "riscv";
            compression = "none";
            load = <$OPENSBI_LOAD_ADDR>;
            entry = <$OPENSBI_LOAD_ADDR>;
        };

        uboot {
            description = "U-Boot";
            data = /incbin/("$UBOOT");
            type = "standalone";
            os = "u-boot";
            arch = "riscv";
            compression = "none";
            load = <$UBOOT_LOAD_ADDR>;
            entry = <$UBOOT_LOAD_ADDR>;
        };

        fdt-1 {
            description = "U-Boot dtb";
            data = /incbin/("$FDT");
            type = "flat_dt";
            arch = "riscv";
            compression = "none";
            load = <$FDT_LOAD_ADDR>;
        };
    };

    configurations {
        default = "conf-1";

        conf-1 {
            description = "ESP32-S31 boot";
            firmware = "opensbi";
            loadables = "uboot";
            fdt = "fdt-1";
        };
    };
};
EOF

echo "Generating ESP32-S31 U-Boot FIT..."
echo "  OpenSBI: $OPENSBI (load/entry: $OPENSBI_LOAD_ADDR)"
echo "  U-Boot:  $UBOOT (load/entry: $UBOOT_LOAD_ADDR)"
echo "  DTB:     $FDT (load: $FDT_LOAD_ADDR)"
echo "  Output:  $OUTPUT"

"$MKIMAGE_BIN" -f "$ITS_FILE" -E "$OUTPUT"

echo "ESP32-S31 U-Boot FIT generated successfully: $OUTPUT"
ls -lh "$OUTPUT"
