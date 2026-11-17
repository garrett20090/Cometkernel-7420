#!/bin/bash
#
# CometKernel Build Script V1.2 by garrett20090
# (hardened: fail-fast preflight checks, safe ramdisk copy, clearer error output)

set -Eeo pipefail

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------
CR_DIR=$(pwd)
CR_LOG=$CR_DIR/build.log
LOG_READY=0     # becomes 1 once build.log belongs to this run (avoids printing a stale log)

show_log_tail()
{
    if [ "$LOG_READY" = 1 ] && [ -s "$CR_LOG" ]; then
        echo " ---- last lines of $CR_LOG (dtc warnings filtered) ----" >&2
        grep -v 'Warning (' "$CR_LOG" | tail -n 25 >&2 || true
        grep -m5 -E "error:|Error [0-9]" "$CR_LOG" >&2 || true
    fi
    return 0
}

die()
{
    echo " " >&2
    echo "ERROR: $*" >&2
    show_log_tail
    exit 1
}

on_error()
{
    local rc=$? line=$1 cmd=$2
    trap - ERR
    echo " " >&2
    echo "==============================================" >&2
    echo " BUILD FAILED (exit $rc) at line $line" >&2
    echo " Command: $cmd" >&2
    show_log_tail
    echo "==============================================" >&2
    exit "$rc"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR
trap 'echo " Interrupted" >&2; exit 130' INT TERM

case "$CR_DIR" in
    *[[:space:]]*) die "source path contains spaces: '$CR_DIR'" ;;
esac

if [ ! -f "$CR_DIR/Makefile" ] || [ ! -d "$CR_DIR/arch" ]; then
    die "run this script from the kernel source root (current dir: $CR_DIR)"
fi

# ---------------------------------------------------------------------------
# Paths / globals
# ---------------------------------------------------------------------------
CR_TC=aarch64-linux-gnu-
CR_ARCH=arm64
CR_DTS=arch/arm64/boot/dts
CR_DTS_DIR=$CR_DIR/$CR_DTS
CR_FSTAB_DTSI=exynos7420-zeroflte_android_fstab.dtsi
CR_OUT=$CR_DIR/Comet/out
CR_PRODUCT=$CR_DIR/Comet/Product
CR_AIK=${AIK_TOOLS:-$CR_DIR/Comet/A.I.K}
CR_KERNEL=$CR_DIR/arch/arm64/boot/Image
CR_DTB=$CR_DIR/boot.img-dtb
CR_VERSION=V1.2
CR_NAME=CometKernel
CR_DATE=$(date +%Y%m%d)
BOOT_MAX=${BOOT_MAX:-$((28 * 1024 * 1024))}
ME_USER=$(id -un)
ME_GROUP=$(id -gn)

# --- Job count ---------------------------------------------------------------
CR_CORES=$(nproc --all)
CR_MEM_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
CR_JOBS_MEM=$(( CR_MEM_MB / 1500 ))
CR_JOBS_CPU=$(( CR_CORES > 1 ? CR_CORES - 1 : 1 ))
CR_JOBS=$(( CR_JOBS_MEM < CR_JOBS_CPU ? CR_JOBS_MEM : CR_JOBS_CPU ))
if [ "$CR_JOBS" -lt 1 ]; then CR_JOBS=1; fi
if [ -n "$JOBS" ]; then CR_JOBS=$JOBS; fi

export ARCH=$CR_ARCH
export CROSS_COMPILE=$CR_TC
export CLANG_TRIPLE=aarch64-linux-gnu-

# ---------------------------------------------------------------------------
# Tool checks
# ---------------------------------------------------------------------------
for t in make awk sed grep find nproc stat sha256sum cpio df id "${CR_TC}gcc"; do
    command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"
done
for t in bc flex bison; do
    command -v "$t" >/dev/null 2>&1 || echo "WARNING: '$t' not found (kernel build may fail)"
done

MK_CC=()
if command -v clang-12 >/dev/null 2>&1; then
    MK_CC=(CC=clang-12 HOSTCC=clang-12)
    echo "Compiler: clang-12"
else
    echo "Compiler: ${CR_TC}gcc (clang-12 not found)"
fi
LOWPRI=(nice -n 19)
if command -v ionice >/dev/null 2>&1; then LOWPRI+=(ionice -c3); fi

kmake() { "${LOWPRI[@]}" make ARCH=$CR_ARCH CROSS_COMPILE="$CR_TC" "${MK_CC[@]}" "$@"; }

# ---------------------------------------------------------------------------
# Device table
# ---------------------------------------------------------------------------
set_device()
{
    case "$1" in
        N9208)
            CR_GROUP="Note5"
            CR_VARIANT=N9208
            CR_CONFIG=exynos7420-noblelte_defconfig
            CR_DTSFILES="exynos7420-noblelte_sea_xtc_06.dtb exynos7420-noblelte_sea_xtc_08.dtb exynos7420-noblelte_sea_xtc_09.dtb"
            ;;
        N920C)
            CR_GROUP="Note5"
            CR_VARIANT=N920C
            CR_CONFIG=exynos7420-noblelte_defconfig
            CR_DTSFILES="exynos7420-noblelte_uni_open_09.dtb"
            ;;
        G92X)
            CR_GROUP="S6/S6E"
            CR_VARIANT=G92X
            CR_CONFIG=exynos7420-zeroflte_defconfig
            CR_DTSFILES="G92X_universal.dtb"
            ;;
        G92X_P)
            CR_GROUP="S6/S6E"
            CR_VARIANT=G92X_00P
            CR_CONFIG=G9250_defconfig
            CR_DTSFILES="G92X_00P.dtb"
            ;;
        G928X)
            CR_GROUP="S6 Edge+"
            CR_VARIANT=G928X
            CR_CONFIG=exynos7420-zenlte_defconfig
            CR_DTSFILES="exynos7420-zenlte_eur_open_05.dtb exynos7420-zenlte_eur_open_06.dtb exynos7420-zenlte_eur_open_07.dtb"
            ;;
        A810F)
            CR_GROUP="A8 2016"
            CR_VARIANT=A810F
            CR_CONFIG=exynos7420-a8xelte_defconfig
            CR_DTSFILES="exynos7420-a8xelte_mea_jt_00.dtb exynos7420-a8xelte_mea_jt_01.dtb exynos7420-a8xelte_mea_jt_02.dtb exynos7420-a8xelte_mea_jt_03.dtb"
            ;;
        *)
            die "unknown device: '$1' (use N9208, N920C, G92X, G92X_P, G928X, A810F)"
            ;;
    esac

    if [ -n "$BASE_IMG_DIR" ]; then
        CR_RAMDISK=$BASE_IMG_DIR
    elif [ -d "$CR_DIR/Comet/Vanilla_$CR_VARIANT" ]; then
        CR_RAMDISK=$CR_DIR/Comet/Vanilla_$CR_VARIANT
    else
        CR_RAMDISK=$CR_DIR/Comet/Vanilla
    fi
}

# ---------------------------------------------------------------------------
# Menu (two levels)
# ---------------------------------------------------------------------------
select_sub()
{
    local prompt=$1; shift
    local labels=() keys=() l
    while [ $# -gt 1 ]; do
        labels+=("$1"); keys+=("$2"); shift 2
    done
    labels+=("Back")
    PS3="$prompt > "
    select l in "${labels[@]}"; do
        if [ "$l" = "Back" ]; then
            return 1
        elif [ -n "$l" ]; then
            DEVICE=${keys[$((REPLY - 1))]}
            return 0
        fi
        echo "Invalid option."
    done
    return 1
}

MAIN_MENU()
{
    local grp
    [ -t 0 ] || die "no terminal; set DEVICE=N9208|N920C|G92X|G92X_P|G928X|A810F"
    while [ -z "$DEVICE" ]; do
        clear 2>/dev/null || true
        echo "----------------------------------------------"
        echo "$CR_NAME $CR_VERSION Build Script"
        echo "----------------------------------------------"
        PS3='Select device (1-5): '
        select grp in "Note5" "S6/S6E" "S6 Edge+" "A8 2016" "Exit"; do
            case $grp in
                "Note5")
                    select_sub "Note5" "SM-N9208" N9208 "SM-N920C" N920C || true ;;
                "S6/S6E")
                    select_sub "S6/S6E" "SM-G92X" G92X "SM-G92X (00/P Variants)" G92X_P || true ;;
                "S6 Edge+")
                    DEVICE=G928X ;;
                "A8 2016")
                    select_sub "A8 2016" "SM-A810F" A810F || true ;;
                "Exit")
                    exit 0 ;;
                *)
                    echo "Invalid option."; continue ;;
            esac
            break
        done
    done
}

case "${DEVICE^^}" in
    1) DEVICE=N9208 ;;
    2) DEVICE=N920C ;;
    *) DEVICE=${DEVICE^^} ;;
esac
[ -n "$DEVICE" ] || MAIN_MENU

if [ -z "$CLEAN" ]; then
    if [ -t 0 ]; then
        read -r -p "Clean source (y/n) > " CLEAN
    else
        CLEAN=n
    fi
fi
if [ "$CLEAN" = "Y" ] || [ "$CLEAN" = "y" ]; then
    echo "Clean Build"
    CR_CLEAN=1
else
    echo "Dirty Build"
    CR_CLEAN=0
fi

set_device "$DEVICE"

# ---------------------------------------------------------------------------
# Build steps
# ---------------------------------------------------------------------------
BUILD_CHECK()
{
    [ -f "$CR_DIR/arch/$CR_ARCH/configs/$CR_CONFIG" ] || die "defconfig not found: $CR_CONFIG"
    [ -f "$CR_DTS_DIR/$CR_FSTAB_DTSI" ]               || die "missing $CR_FSTAB_DTSI"
    [ -f "$CR_AIK/repackimg.sh" ]                     || die "repackimg.sh not found in $CR_AIK"
    [ -d "$CR_RAMDISK/split_img" ]                    || die "split_img/ not found in $CR_RAMDISK"
    [ -d "$CR_RAMDISK/ramdisk" ]                      || die "ramdisk/ not found in $CR_RAMDISK"
    local dtb
    for dtb in $CR_DTSFILES; do
        if [ ! -f "$CR_DTS_DIR/${dtb%.dtb}.dts" ]; then
            echo "Candidates in $CR_DTS:" >&2
            find "$CR_DTS_DIR" -maxdepth 1 -name 'exynos7420-*.dts' -printf '  %f\n' 2>/dev/null | sort | head -n 60 >&2 || true
            die "dts not found: ${dtb%.dtb}.dts (fix the DTS list of $CR_VARIANT in set_device)"
        fi
    done

    # --- Permission / space preflight: fail now, not after a 30-minute compile ---
    mkdir -p "$CR_OUT" "$CR_PRODUCT" || die "cannot create output dirs under $CR_DIR/Comet"
    [ -w "$CR_DIR" ] || die "source dir not writable: $CR_DIR"
    if [ ! -w "$CR_OUT" ] || [ ! -w "$CR_PRODUCT" ]; then
        die "output dirs not writable. Fix: sudo chown -R $ME_USER:$ME_GROUP '$CR_DIR/Comet'"
    fi

    local bad
    bad=$(find "$CR_AIK" ! -user "$ME_USER" -print -quit 2>/dev/null || true)
    if [ -n "$bad" ]; then
        die "A.I.K has files not owned by $ME_USER (e.g. $bad). Fix: sudo chown -R $ME_USER:$ME_GROUP '$CR_AIK'"
    fi
    bad=$(find "$CR_RAMDISK" ! -readable -print -quit 2>/dev/null || true)
    if [ -n "$bad" ]; then
        die "base ramdisk has unreadable files (e.g. $bad). Fix: sudo chown -R $ME_USER:$ME_GROUP '$CR_RAMDISK'"
    fi

    local free_mb
    free_mb=$(df -Pm "$CR_DIR" | awk 'NR==2 {print $4}')
    if [ -n "$free_mb" ] && [ "$free_mb" -lt 4000 ]; then
        echo "WARNING: only ${free_mb} MB free on this filesystem (kernel build needs several GB)."
    fi
}

BUILD_HACKS()
{
    echo "----------------------------------------------"
    echo " "
    echo " Applying HACKS for $CR_VARIANT"
    local f="$CR_DIR/arch/arm64/mm/proc.S"
    if [ -f "$f" ] && grep -q '#alloc, #execinstr' "$f"; then
        echo " Patching arch/arm64/mm/proc.S for newer binutils"
        sed -i 's/\.section \("[^"]*"\), #alloc, #execinstr/.section \1, "ax"/' "$f"
    fi
    local c d h
    while IFS= read -r c; do
        d=$(dirname "$c")
        for h in $(grep -oP '#\s*include\s*<\K[^>/]+(?=>)' "$c" || true); do
            if [ -f "$d/$h" ]; then
                echo " Fixing include <$h> in ${c#$CR_DIR/}"
                sed -i "s|#\(\s*\)include\s*<$h>|#\1include \"$h\"|" "$c"
            fi
        done
    done < <(grep -rlE '#\s*include\s*<[^/>]+>' "$CR_DIR/drivers/gud" --include='*.c' 2>/dev/null || true)
    local dtb dts
    for dtb in $CR_DTSFILES; do
        dts="$CR_DTS_DIR/${dtb%.dtb}.dts"
        [ -f "$dts" ] || die "dts not found: $dts"
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
    if [ "$CR_CLEAN" = 1 ]; then
        echo " "
        echo " Cleaning build dir"
        make ARCH=$CR_ARCH clean
        make ARCH=$CR_ARCH mrproper
    else
        echo " "
        echo " Skip Full cleaning"
    fi
    rm -rf "$CR_DTB" "$CR_DIR/.config"
    rm -rf "$CR_DTS_DIR"/.*.tmp "$CR_DTS_DIR"/.*.cmd "$CR_DTS_DIR"/*.dtb
    mkdir -p "$CR_OUT" "$CR_PRODUCT"
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
    if [ "$CR_MEM_MB" -lt 3000 ]; then
        echo "WARNING: less than 3 GB free RAM - add swap or lower JOBS."
    fi
    BUILD_IMAGE_NAME
    export LOCALVERSION=-$CR_IMAGE_NAME
    echo "Make $CR_CONFIG (log: $CR_LOG)"
    : > "$CR_LOG"
    LOG_READY=1
    rm -f "$CR_KERNEL"
    kmake "$CR_CONFIG" >>"$CR_LOG" 2>&1 || die "defconfig failed: $CR_CONFIG (see $CR_LOG)"
    local opt
    for opt in CONFIG_BPF_SYSCALL CONFIG_CGROUP_BPF; do
        grep -q "^$opt=y" "$CR_DIR/.config" || echo "WARNING: $opt is not enabled in .config"
    done
    kmake -j"$CR_JOBS" >>"$CR_LOG" 2>&1 || die "kernel compile failed (see $CR_LOG)"
    [ -s "$CR_KERNEL" ] || die "Image was not produced"
    sizT=$(( $(stat -c %s "$CR_KERNEL") / 1024 ))
    echo " "
    echo "----------------------------------------------"
}

BUILD_DTB()
{
    echo "----------------------------------------------"
    echo " "
    echo "Building DTB for $CR_VARIANT"
    rm -rf "$CR_DTS_DIR"/*.dtb
    kmake $CR_DTSFILES >>"$CR_LOG" 2>&1 || die "DTB build failed (see $CR_LOG)"
    local dtb
    for dtb in $CR_DTSFILES; do
        [ -s "$CR_DTS_DIR/$dtb" ] || die "dtb was not produced: $dtb"
    done
    local DTBTOOL="" src
    if [ -x ./scripts/dtbTool/dtbTool ]; then
        DTBTOOL=./scripts/dtbTool/dtbTool
    else
        DTBTOOL=$(find "$CR_DIR/scripts" -type f -name dtbTool -perm -u+x 2>/dev/null | head -n 1 || true)
    fi
    if [ -z "$DTBTOOL" ]; then
        src=$(find "$CR_DIR/scripts" -type f -iname 'dtbtool.c' 2>/dev/null | head -n 1 || true)
        [ -n "$src" ] || die "dtbTool not found"
        gcc "$src" -o "$CR_DIR/dtbTool.bin" || die "dtbTool compile failed"
        DTBTOOL="$CR_DIR/dtbTool.bin"
    fi
    local extra=() help_txt
    help_txt=$("$DTBTOOL" --help 2>&1 || true)
    if grep -q -- '--platform' <<<"$help_txt"; then
        extra=(--platform 0x50a6 --subtype 0x217584da)
    fi
    "$DTBTOOL" "${extra[@]}" -o "$CR_DTB" -d "$CR_DTS"/ -s 2048 >>"$CR_LOG" 2>&1 || die "dtbTool failed (see $CR_LOG)"
    [ -s "$CR_DTB" ] || die "DTB Failed to Compile"
    rm -rf "$CR_DTS_DIR"/.*.tmp "$CR_DTS_DIR"/.*.cmd "$CR_DTS_DIR"/*.dtb
    sizdT=$(( $(stat -c %s "$CR_DTB") / 1024 ))
    echo " "
    echo "----------------------------------------------"
}

PACK_BOOT_IMG()
{
    echo "----------------------------------------------"
    echo " "
    echo "Building Boot.img for $CR_VARIANT"

    # Wipe leftovers of earlier (possibly failed) runs. Read-only dirs inside an
    # unpacked ramdisk (apex, proc, sys...) block rm/cp, so open them up first.
    # Stale files would otherwise be merged into this variant's ramdisk.
    chmod -R u+rwX "$CR_AIK/ramdisk" "$CR_AIK/split_img" 2>/dev/null || true
    rm -rf "$CR_AIK/ramdisk" "$CR_AIK/split_img"

    # Keep modes and symlinks, but NOT owner/timestamps: those fail on non-root
    # users and on VMware/NTFS shares. cpio inside A.I.K re-owns entries anyway.
    cp -RP --preserve=mode,links --no-preserve=ownership,timestamps \
        "$CR_RAMDISK"/. "$CR_AIK"/ || die "copying base ramdisk into A.I.K failed (check ownership of $CR_AIK)"

    mv -f "$CR_KERNEL" "$CR_AIK/split_img/boot.img-zImage"
    mv -f "$CR_DTB" "$CR_AIK/split_img/boot.img-dtb"
    find "$CR_AIK" -maxdepth 1 -name '*.sh' -exec chmod +x {} +
    rm -f "$CR_AIK/image-new.img"
    ( cd "$CR_AIK" && ./repackimg.sh ) >>"$CR_LOG" 2>&1 || die "repackimg.sh failed (see $CR_LOG)"
    [ -s "$CR_AIK/image-new.img" ] || die "image-new.img was not produced"
    if ! tail -c 16 "$CR_AIK/image-new.img" | grep -aq SEANDROIDENFORCE; then
        echo -n "SEANDROIDENFORCE" >> "$CR_AIK/image-new.img"
    fi
    sizkB=$(stat -c %s "$CR_AIK/image-new.img")
    sizkT=$(( sizkB / 1024 ))
    if [ "$sizkB" -gt "$BOOT_MAX" ]; then
        die "boot image ($sizkT Kb) is larger than the BOOT partition limit ($((BOOT_MAX / 1024)) Kb)"
    fi
    cp -f "$CR_AIK/image-new.img" "$CR_PRODUCT/$CR_IMAGE_NAME.img"
    mv -f "$CR_AIK/image-new.img" "$CR_OUT/$CR_IMAGE_NAME.img"
    echo " "
    chmod -R u+rwX "$CR_AIK/ramdisk" "$CR_AIK/split_img" 2>/dev/null || true
    if [ -f "$CR_AIK/cleanup.sh" ]; then
        ( cd "$CR_AIK" && ./cleanup.sh ) >>"$CR_LOG" 2>&1 || echo "WARNING: A.I.K cleanup failed"
    fi
    rm -rf "$CR_AIK/ramdisk" "$CR_AIK/split_img"
    BUILD_CLEAN
}

BUILD_OUT()
{
    echo " "
    echo "----------------------------------------------"
    echo "$CR_VARIANT kernel build finished in $((SECONDS / 60)) min $((SECONDS % 60)) s."
    echo "Compiled DTB Size = $sizdT Kb"
    echo "Kernel Image Size = $sizT Kb"
    echo "Boot Image   Size = $sizkT Kb (limit $((BOOT_MAX / 1024)) Kb)"
    echo "sha256 = $(sha256sum "$CR_OUT/$CR_IMAGE_NAME.img" | cut -d' ' -f1)"
    echo "$CR_PRODUCT/$CR_IMAGE_NAME.img Ready"
    echo "----------------------------------------------"
}

RUN_BUILD()
{
    echo "Starting $CR_GROUP / $CR_VARIANT kernel build..."
    echo "  defconfig : $CR_CONFIG"
    echo "  dtb files : $CR_DTSFILES"
    echo "  ramdisk   : $CR_RAMDISK"
    BUILD_CHECK
    BUILD_HACKS
    BUILD_CLEAN
    BUILD_ZIMAGE
    BUILD_DTB
    BUILD_IMAGE_NAME
    PACK_BOOT_IMG
    BUILD_OUT
}

SECONDS=0
RUN_BUILD
