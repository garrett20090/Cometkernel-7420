#!/bin/bash
#
# CometKernel Build Script V1.1 (cronos.sh style)
# For Exynos7420 - SM-N9208 / SM-N920C (Galaxy Note 5)
# Target: One UI 7 / Android 15 port
#
# Build flow (same as cronos.sh):
#   BUILD_CLEAN -> BUILD_ZIMAGE -> BUILD_DTB -> PACK_BOOT_IMG -> BUILD_OUT
# In-tree build, dtbTool packs dt.img, A.I.K repacks the boot.img.
#
# Run from the kernel source root. Path must NOT contain spaces.
#
# Non-interactive:  DEVICE=1 CLEAN=n ./comet.sh   (1 = N9208, 2 = N920C)
# Optional overrides: JOBS=2  AIK_TOOLS=...  BASE_IMG_DIR=...

# Main Dir
CR_DIR=$(pwd)
case "$CR_DIR" in
    *[[:space:]]*) echo "ERROR: source path contains spaces: '$CR_DIR'"; exit 1 ;;
esac

# --- New generation difference #1: toolchain --------------------------------
# Cronos used linaro 4.9 (Android 8). The Android 15 port is built with
# clang-12 when available, otherwise the distro aarch64-linux-gnu-gcc.
# CC must be passed on the make command line (3.10 Makefile overrides env CC).
CR_TC=aarch64-linux-gnu-
CR_ARCH=arm64
CR_DTS=arch/arm64/boot/dts
CR_FSTAB_DTSI=exynos7420-zeroflte_android_fstab.dtsi
# Boot.img out dirs
CR_OUT=$CR_DIR/Comet/out
CR_PRODUCT=$CR_DIR/Comet/Product
# Persistent A.I.K location
CR_AIK=${AIK_TOOLS:-$CR_DIR/Comet/A.I.K}
# --- New generation difference #2: ramdisk ----------------------------------
# Cronos shipped its own ramdisk. Here the unpacked STOCK boot.img of the
# One UI 7 port is used (split_img/ + ramdisk/), so cmdline/offsets/ramdisk
# stay untouched and only zImage + dtb are replaced.
CR_RAMDISK=${BASE_IMG_DIR:-$CR_DIR/Comet/Vanilla}
# Compiled image and dtb
CR_KERNEL=$CR_DIR/arch/arm64/boot/Image
CR_DTB=$CR_DIR/boot.img-dtb
CR_LOG=$CR_DIR/build.log
# Kernel Name and Version
CR_VERSION=V1.1
CR_NAME=CometKernel
CR_DATE=$(date +%Y%m%d)
# BOOT partition (sda5) is 28 MiB
BOOT_MAX=$((28 * 1024 * 1024))

# --- New generation difference #3: job count --------------------------------
# ~1.5 GB RAM per job, keep one core free
CR_CORES=$(nproc --all)
CR_MEM_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
CR_JOBS_MEM=$(( CR_MEM_MB / 1500 ))
CR_JOBS_CPU=$(( CR_CORES > 1 ? CR_CORES - 1 : 1 ))
CR_JOBS=$(( CR_JOBS_MEM < CR_JOBS_CPU ? CR_JOBS_MEM : CR_JOBS_CPU ))
[ "$CR_JOBS" -lt 1 ] && CR_JOBS=1
[ -n "$JOBS" ] && CR_JOBS=$JOBS

# Init build
export ARCH=$CR_ARCH
export CROSS_COMPILE=$CR_TC
export CLANG_TRIPLE=aarch64-linux-gnu-
# Cronos exported ANDROID_MAJOR_VERSION / PLATFORM_VERSION. The original
# comet.sh did not set them, so they stay off; enable only if your tree needs it.
#export ANDROID_MAJOR_VERSION=v
#export PLATFORM_VERSION=15.0.0

MK_CC=()
if command -v clang-12 >/dev/null 2>&1; then
    MK_CC=(CC=clang-12 HOSTCC=clang-12)
    echo "Compiler: clang-12"
else
    echo "Compiler: ${CR_TC}gcc (clang-12 not found)"
fi
LOWPRI=(nice -n 19)
command -v ionice >/dev/null 2>&1 && LOWPRI+=(ionice -c3)

kmake() { "${LOWPRI[@]}" make ARCH=$CR_ARCH CROSS_COMPILE="$CR_TC" "${MK_CC[@]}" "$@"; }

##########################################
# Device specific Variables
CR_CONFIG_N9208=exynos7420-noblelte_defconfig
CR_DTSFILES_N9208="exynos7420-noblelte_sea_xtc_06.dtb exynos7420-noblelte_sea_xtc_08.dtb exynos7420-noblelte_sea_xtc_09.dtb"
CR_VARIANT_N9208=N9208
CR_CONFIG_N920C=exynos7420-noblelte_defconfig
CR_DTSFILES_N920C="exynos7420-noblelte_uni_open_09.dtb"
CR_VARIANT_N920C=N920C
#####################################################

# Script functions
if [ -z "$CLEAN" ]; then
    read -p "Clean source (y/n) > " CLEAN
fi
if [ "$CLEAN" = "Y" -o "$CLEAN" = "y" ]; then
     echo "Clean Build"
     CR_CLEAN="1"
else
     echo "Dirty Build"
     CR_CLEAN="0"
fi

BUILD_CHECK()
{
    [ -f "$CR_DIR/arch/$CR_ARCH/configs/$CR_CONFIG" ] || { echo "ERROR: defconfig not found: $CR_CONFIG"; exit 1; }
    [ -f "$CR_DIR/$CR_DTS/$CR_FSTAB_DTSI" ]           || { echo "ERROR: missing $CR_FSTAB_DTSI (is this the One UI 7 port source?)"; exit 1; }
    [ -f "$CR_AIK/repackimg.sh" ]                      || { echo "ERROR: repackimg.sh not found in $CR_AIK"; exit 1; }
    [ -d "$CR_RAMDISK/split_img" ]                     || { echo "ERROR: split_img/ not found in $CR_RAMDISK"; exit 1; }
    [ -d "$CR_RAMDISK/ramdisk" ]                       || { echo "ERROR: ramdisk/ not found in $CR_RAMDISK"; exit 1; }
}

# --- New generation difference #4: toolchain / DT hacks ----------------------
BUILD_HACKS()
{
    echo "----------------------------------------------"
    echo " "
    echo " Applying HACKS for $CR_VARIANT"
    # Newer binutils reject "#alloc, #execinstr"; "ax" is the modern spelling
    local f="$CR_DIR/arch/arm64/mm/proc.S"
    if [ -f "$f" ] && grep -q '#alloc, #execinstr' "$f"; then
        echo " Patching arch/arm64/mm/proc.S for newer binutils"
        sed -i 's/\.section \("[^"]*"\), #alloc, #execinstr/.section \1, "ax"/' "$f"
    fi
    # In-tree builds do not add -I$(srctree)/$(src) (O= builds do), so
    # #include <foo.h> for a header next to the .c file fails to resolve.
    # Convert those to "foo.h", only when the header really is in the same dir.
    local c d h
    while IFS= read -r c; do
        d=$(dirname "$c")
        for h in $(grep -oP '#\s*include\s*<\K[^>/]+(?=>)' "$c"); do
            if [ -f "$d/$h" ]; then
                echo " Fixing include <$h> in ${c#$CR_DIR/}"
                sed -i "s|#\(\s*\)include\s*<$h>|#\1include \"$h\"|" "$c"
            fi
        done
    done < <(grep -rlE '#\s*include\s*<[^/>]+>' "$CR_DIR/drivers/gud" --include='*.c' 2>/dev/null)
    # Android 15 first-stage mount reads SYSTEM/VENDOR/METADATA/USERDATA from DT
    local dtb dts
    for dtb in $CR_DTSFILES; do
        dts="$CR_DIR/$CR_DTS/${dtb%.dtb}.dts"
        [ -f "$dts" ] || { echo "ERROR: dts not found: $dts"; exit 1; }
        if ! grep -q "$CR_FSTAB_DTSI" "$dts"; then
            echo " Adding fstab include to ${dtb%.dtb}.dts"
            printf '\n#include "%s"\n' "$CR_FSTAB_DTSI" >> "$dts"
        fi
    done
    echo " "
    echo "----------------------------------------------"
}

BUILD_CLEAN()
{
if [ $CR_CLEAN = 1 ]; then
     echo " "
     echo " Cleaning build dir"
     make ARCH=$CR_ARCH clean && make ARCH=$CR_ARCH mrproper
     rm -r -f $CR_DTB
     rm -rf $CR_DTS/.*.tmp
     rm -rf $CR_DTS/.*.cmd
     rm -rf $CR_DTS/*.dtb
     rm -rf $CR_DIR/.config
fi
if [ $CR_CLEAN = 0 ]; then
     echo " "
     echo " Skip Full cleaning"
     rm -r -f $CR_DTB
     rm -rf $CR_DTS/.*.tmp
     rm -rf $CR_DTS/.*.cmd
     rm -rf $CR_DTS/*.dtb
     rm -rf $CR_DIR/.config
fi
mkdir -p $CR_OUT $CR_PRODUCT
}

BUILD_IMAGE_NAME()
{
    CR_IMAGE_NAME=$CR_NAME-$CR_VERSION-$CR_VARIANT-$CR_DATE
}

BUILD_ZIMAGE()
{
    echo "----------------------------------------------"
    echo " "
    echo "Building zImage for $CR_VARIANT (jobs: $CR_JOBS, RAM: ${CR_MEM_MB} MB)"
    [ "$CR_MEM_MB" -lt 3000 ] && echo "WARNING: less than 3 GB free RAM - add swap or lower JOBS."
    BUILD_IMAGE_NAME
    export LOCALVERSION=-$CR_IMAGE_NAME
    echo "Make $CR_CONFIG (log: $CR_LOG)"
    : > "$CR_LOG"
    kmake $CR_CONFIG >>"$CR_LOG" 2>&1 || { tail -n 20 "$CR_LOG"; echo "defconfig failed"; exit 1; }
    # Android 15 network stack needs the BPF backport
    for opt in CONFIG_BPF_SYSCALL CONFIG_CGROUP_BPF; do
        grep -q "^$opt=y" "$CR_DIR/.config" || echo "WARNING: $opt is not enabled in .config"
    done
    kmake -j$CR_JOBS >>"$CR_LOG" 2>&1
    if [ ! -e $CR_KERNEL ]; then
        echo "---- last lines of the log ----"
        tail -n 25 "$CR_LOG"
        grep -m5 -E "error:|Error [0-9]" "$CR_LOG"
        echo "Image Failed to Compile"
        echo " Abort "
        exit 1
    fi
    du -k "$CR_KERNEL" | cut -f1 >sizT
    sizT=$(head -n 1 sizT)
    rm -rf sizT
    echo " "
    echo "----------------------------------------------"
}

BUILD_DTB()
{
    echo "----------------------------------------------"
    echo " "
    echo "Building DTB for $CR_VARIANT"
    # Image build does not compile dtbs; wipe strays so only the selected ones get packed
    rm -rf $CR_DTS/*.dtb
    kmake $CR_DTSFILES >>"$CR_LOG" 2>&1 || { tail -n 20 "$CR_LOG"; echo "DTB build failed"; exit 1; }
    # dtbTool: known location first, then search, then build from source
    local DTBTOOL=""
    if [ -x ./scripts/dtbTool/dtbTool ]; then DTBTOOL=./scripts/dtbTool/dtbTool
    else DTBTOOL=$(find "$CR_DIR/scripts" -type f -name dtbTool -perm -u+x 2>/dev/null | head -n 1); fi
    if [ -z "$DTBTOOL" ]; then
        src=$(find "$CR_DIR/scripts" -type f -iname 'dtbtool.c' 2>/dev/null | head -n 1)
        [ -n "$src" ] || { echo "dtbTool not found"; exit 1; }
        gcc "$src" -o "$CR_DIR/dtbTool.bin" && DTBTOOL="$CR_DIR/dtbTool.bin" || { echo "dtbTool compile failed"; exit 1; }
    fi
    # Some dtbTool builds need explicit platform/subtype IDs (values from the port author)
    local extra=()
    if "$DTBTOOL" --help 2>&1 | grep -q -- '--platform'; then
        extra=(--platform 0x50a6 --subtype 0x217584da)
    fi
    "$DTBTOOL" "${extra[@]}" -o $CR_DTB -d $CR_DTS/ -s 2048
    if [ ! -s $CR_DTB ]; then
        echo "DTB Failed to Compile"
        echo " Abort "
        exit 1
    fi
    rm -rf $CR_DTS/.*.tmp
    rm -rf $CR_DTS/.*.cmd
    rm -rf $CR_DTS/*.dtb
    du -k "$CR_DTB" | cut -f1 >sizdT
    sizdT=$(head -n 1 sizdT)
    rm -rf sizdT
    echo " "
    echo "----------------------------------------------"
}

PACK_BOOT_IMG()
{
    echo "----------------------------------------------"
    echo " "
    echo "Building Boot.img for $CR_VARIANT"
    # Copy stock (unpacked) ramdisk + split_img into A.I.K
    cp -rf $CR_RAMDISK/* $CR_AIK
    # Move compiled kernel and dtb to A.I.K folder
    mv $CR_KERNEL $CR_AIK/split_img/boot.img-zImage
    mv $CR_DTB $CR_AIK/split_img/boot.img-dtb
    # Create boot.img
    chmod +x $CR_AIK/*.sh
    ( cd $CR_AIK && ./repackimg.sh ) || { echo "repackimg.sh failed"; exit 1; }
    [ -f $CR_AIK/image-new.img ] || { echo "image-new.img was not produced"; exit 1; }
    # Remove red warning at boot (newer A.I.K appends it already, so check first)
    if ! tail -c 16 $CR_AIK/image-new.img | grep -aq SEANDROIDENFORCE; then
        echo -n "SEANDROIDENFORCE" >> $CR_AIK/image-new.img
    fi
    # Copy boot.img to Product folder
    cp $CR_AIK/image-new.img $CR_PRODUCT/$CR_IMAGE_NAME.img
    # Move boot.img to out dir
    mv $CR_AIK/image-new.img $CR_OUT/$CR_IMAGE_NAME.img
    du -k "$CR_OUT/$CR_IMAGE_NAME.img" | cut -f1 >sizkT
    sizkT=$(head -n 1 sizkT)
    rm -rf sizkT
    [ "$(stat -c %s $CR_OUT/$CR_IMAGE_NAME.img)" -gt "$BOOT_MAX" ] && \
        echo "WARNING: boot image is larger than the 28 MiB BOOT partition!"
    echo " "
    [ -f $CR_AIK/cleanup.sh ] && ( cd $CR_AIK && ./cleanup.sh )
    # Respect CLEAN build rules
    BUILD_CLEAN
}

BUILD_OUT()
{
    echo " "
    echo "----------------------------------------------"
    echo "$CR_VARIANT kernel build finished."
    echo "Compiled DTB Size = $sizdT Kb"
    echo "Kernel Image Size = $sizT Kb"
    echo "Boot Image   Size = $sizkT Kb (limit 28672 Kb)"
    echo "sha256 = $(sha256sum $CR_OUT/$CR_IMAGE_NAME.img | cut -d' ' -f1)"
    echo "$CR_PRODUCT/$CR_IMAGE_NAME.img Ready"
    echo "----------------------------------------------"
}

RUN_BUILD()
{
    BUILD_CHECK
    BUILD_HACKS
    BUILD_CLEAN
    BUILD_ZIMAGE
    BUILD_DTB
    BUILD_IMAGE_NAME
    PACK_BOOT_IMG
    BUILD_OUT
}

# Main Menu
if [ -z "$DEVICE" ]; then
    clear
    echo "----------------------------------------------"
    echo "$CR_NAME $CR_VERSION Build Script"
    echo "----------------------------------------------"
    PS3='Please select your option (1-3): '
    menuvar=("SM-N9208" "SM-N920C" "Exit")
    select opt in "${menuvar[@]}"
    do
        case $opt in
            "SM-N9208") DEVICE=1; break ;;
            "SM-N920C") DEVICE=2; break ;;
            "Exit")     exit 0 ;;
            *) echo Invalid option. ;;
        esac
    done
fi

case "$DEVICE" in
    1)
        echo "Starting $CR_VARIANT_N9208 kernel build..."
        CR_CONFIG=$CR_CONFIG_N9208
        CR_DTSFILES=$CR_DTSFILES_N9208
        CR_VARIANT=$CR_VARIANT_N9208
        RUN_BUILD
        ;;
    2)
        echo "Starting $CR_VARIANT_N920C kernel build..."
        CR_CONFIG=$CR_CONFIG_N920C
        CR_DTSFILES=$CR_DTSFILES_N920C
        CR_VARIANT=$CR_VARIANT_N920C
        RUN_BUILD
        ;;
    *) exit 0 ;;
esac
