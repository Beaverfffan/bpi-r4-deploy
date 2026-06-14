#!/bin/sh
# BPI-R4 Pro 8X - Install rescue system to NAND
# Run from SD card: sh /root/bpi-r4-install/install-nand-pro8x.sh

set -e

GH_USER="woziwrt"
GH_REPO="bpi-r4-deploy"
GH_TAG="release-pro-8x-standard"
SNAND_FILENAME="bpi-r4-pro-snand-img.bin"
SNAND_URL="https://github.com/${GH_USER}/${GH_REPO}/releases/download/${GH_TAG}/${SNAND_FILENAME}"
NAND_IMG="/root/install-dir/${SNAND_FILENAME}"

echo ""
echo "=================================================="
echo "  BPI-R4 Pro 8X - Install rescue system to NAND"
echo "=================================================="
echo ""

# Verify we are running from SD card
if ! grep -q "fitrw" /proc/mounts 2>/dev/null; then
    echo "ERROR: This script must be run from the SD card!"
    echo "       Make sure the DIP switch is set to SD boot."
    exit 1
fi

echo "OK: System is running from SD card."
echo ""

# Download image from GitHub if not present locally
if [ ! -f "${NAND_IMG}" ]; then
    echo "Image not found locally. Downloading from GitHub..."
    echo "  ${SNAND_URL}"
    echo ""
    mkdir -p "$(dirname ${NAND_IMG})"
    wget -O "${NAND_IMG}" "${SNAND_URL}"
    if [ $? -ne 0 ] || [ ! -s "${NAND_IMG}" ]; then
        echo ""
        echo "ERROR: Download failed!"
        rm -f "${NAND_IMG}"
        exit 1
    fi
    echo ""
fi

echo "OK: NAND image ready ($(du -h ${NAND_IMG} | cut -f1))."
echo ""

# Verify NAND device is available
if ! grep -q '"nand"' /proc/mtd 2>/dev/null; then
    echo "ERROR: NAND device not found in /proc/mtd!"
    exit 1
fi

echo "OK: NAND device found."
echo ""

# Final warning before flashing
echo "WARNING: The entire NAND flash will be overwritten!"
echo "         Press ENTER to continue or CTRL+C to cancel."
read _

echo ""
echo "Flashing rescue system to NAND..."
mtd -e nand write "${NAND_IMG}" nand

echo ""
echo "=================================================="
echo "  DONE! Rescue system installed to NAND."
echo "=================================================="
echo ""
echo "Next steps:"
echo "  1. Power off the device"
echo "  2. Switch DIP to NAND boot"
echo "  3. Power on the device"
echo "  4. Login via SSH and run:"
echo "     sh /root/bpi-r4-install/install-nvme.sh"
echo ""
