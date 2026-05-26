#!/bin/bash
set -euo pipefail

# BPI-R4 Pro 8X - SD rescue builder
# Produces: openwrt-mediatek-filogic-bananapi_bpi-r4-pro-sdcard.img.gz
# Run on Ubuntu VM, commit result to rescue/ directory.

rm -rf openwrt
rm -rf mtk-openwrt-feeds

git clone --branch openwrt-25.12 https://git.openwrt.org/openwrt/openwrt.git openwrt
cd openwrt; git checkout 99211b26fb3b9ed71d065a1fa35ce54a0d883944; cd -;

tar xzf /home/ipsec/mtk-feeds-cache.tar.gz

cd openwrt
bash ../mtk-openwrt-feeds/autobuild/unified/autobuild.sh filogic prepare

scripts/feeds uninstall crypto-eip pce tops-tool

# Standard BPI-R4 patches
\cp -r ../my_files/450-w-nand-mmc-add-bpi-r4.patch package/boot/uboot-mediatek/patches/450-add-bpi-r4.patch
\cp -r ../my_files/451-w-add-bpi-r4-nvme.patch package/boot/uboot-mediatek/patches/451-add-bpi-r4-nvme.patch
\cp ../my_files/452-w-add-bpi-r4-nvme-rfb.patch package/boot/uboot-mediatek/patches/452-add-bpi-r4-nvme-rfb.patch
\cp -r ../my_files/453-w-add-bpi-r4-nvme-dtso.patch target/linux/mediatek/patches-6.12/
\cp -r ../my_files/455-w-add-bpi-r4-pro-nvme-dtso.patch target/linux/mediatek/patches-6.12/
\cp ../my_files/454-w-add-bpi-r4-nvme-env.patch package/boot/uboot-mediatek/patches/454-add-bpi-r4-nvme-env.patch

# BPI-R4 Pro patches
\cp -r ../my_files/bpi-r4-pro/patches-kernel/*.patch target/linux/mediatek/patches-6.12/
\cp ../my_files/bpi-r4-pro/patches-uboot/471-add-bpi-r4-pro-8x.patch package/boot/uboot-mediatek/patches/
\cp ../my_files/bpi-r4-pro/uboot-mediatek-Makefile package/boot/uboot-mediatek/Makefile

\cp -r ../my_files/w-filogic-bpi-r4-universal.pro.mk target/linux/mediatek/image/filogic.mk
\cp ../my_files/arm-trusted-firmware-mediatek-Makefile package/boot/arm-trusted-firmware-mediatek/Makefile
mv target/linux/mediatek/image/filogic-extra.mk target/linux/mediatek/image/filogic-extra.mk.disabled

echo "CONFIG_BLK_DEV_NVME=y" >> target/linux/mediatek/filogic/config-6.12

\cp -r ../my_files/999-fitblk-02-w-add-bpi-r4-nvme-fitblk.patch target/linux/mediatek/patches-6.12

rm -f target/linux/mediatek/patches-6.12/732-net-phy-mxl-gpy-don-t-use-SGMII-AN-if-using-phylink.patch

# SD rescue carries the NAND rescue image + install scripts
mkdir -p files/root/bpi-r4-install
\cp ../my_files/bpi-r4-install/snand-img.bin files/root/bpi-r4-install/.snand-img-pro.bin
\cp ../my_files/bpi-r4-install/install-nand.sh files/root/bpi-r4-install/
chmod +x files/root/bpi-r4-install/install-nand.sh
\cp ../my_files/bpi-r4-install/install-nvme.sh files/root/bpi-r4-install/
chmod +x files/root/bpi-r4-install/install-nvme.sh

mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-hostname << 'EOF'
uci set system.@system[0].hostname='BPI-R4-Pro-rescue-SD'
uci commit system
EOF

\cp -r ../configs/rescue-pro.defconfig .config
make defconfig

echo "CONFIG_PACKAGE_trusted-firmware-a-mt7988-emmc-comb-4bg=y" >> .config
echo "CONFIG_PACKAGE_trusted-firmware-a-mt7988-sdmmc-comb-4bg=y" >> .config
echo "CONFIG_PACKAGE_trusted-firmware-a-mt7988-spim-nand-ubi-comb-4bg=y" >> .config

bash ../mtk-openwrt-feeds/autobuild/unified/autobuild.sh filogic build
