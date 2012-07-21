#!/bin/sh -e

# Directory containing this script.
TOPDIR=`cd \`dirname $0\`; pwd`
# Useful values
MB=$((1000 * 1000))
GB=$((1000 * $MB))

#
# Get the config values:
#
echo "Loading configuration values"
. $TOPDIR/beaglebsd-config.sh

if [ -f $TOPDIR/beaglebsd-config-local.sh ]; then
    echo "Loading local configuration overrides"
    . $TOPDIR/beaglebsd-config-local.sh
fi

# Round down to sector multiple.
SD_SIZE=$(( (SD_SIZE / 512) * 512 ))

mkdir -p ${BUILDOBJ}
# Why does this have no effect?
MAKEOBJDIRPREFIX=${BUILDOBJ}/_freebsd_build
# Clean out old log files before we start.
rm -f ${BUILDOBJ}/*.log

#
# Check various prerequisites
#

# We need TIs modified U-Boot sources
if [ ! -f "$UBOOT_SRC/board/ti/am335x/Makefile" ]; then
    # Use TIs U-Boot sources that know about am33x processors
    # XXX TODO: Test with the master U-Boot sources from
    # denx.de; they claim to have merged the TI AM335X support.
    echo "Expected to see U-Boot sources in $UBOOT_SRC"
    echo "Use the following command to get the U-Boot sources"
    echo
    echo "git clone git://arago-project.org/git/projects/u-boot-am33x.git $UBOOT_SRC"
    echo
    echo "Edit \$UBOOT_SRC in beaglebsd-config.sh if you want the sources in a different directory."
    echo "Run this script again after you have the U-Boot sources installed."
    exit 1
fi
echo "Found U-Boot sources in $UBOOT_SRC"

# We need the cross-tools for arm, if they're not already built.
# This should work with arm.arm or arm.armv6 equally well.
if [ -z `which armv6-freebsd-cc` ]; then
    echo "Can't find FreeBSD xdev tools for ARM."
    echo "If you have FreeBSD-CURRENT sources in /usr/src, you can build these with the following command:"
    echo
    echo "cd /usr/src && sudo make xdev XDEV=arm XDEV_ARCH=arm"
    echo
    echo "Run this script again after you have the xdev tools installed."
    exit 1
fi
echo "Found FreeBSD xdev tools for ARM"

# We need the FreeBSD-armv6 tree (we can tell it's the right
# one by the presence of the BEAGLEBONE configuration file).
# Someday, this will all be merged and we can just rely on FreeBSD-CURRENT.
if [ \! -f "$FREEBSD_SRC/sys/arm/conf/BEAGLEBONE" ]; then
    echo "Need FreeBSD-armv6 tree."
    echo "You can obtain this with the folowing command:"
    echo
    echo "mkdir -p $FREEBSD_SRC && svn co http://svn.freebsd.org/base/projects/armv6 $FREEBSD_SRC"
    echo
    echo "Edit \$FREEBSD_SRC in beaglebsd-config.sh if you want the sources in a different directory."
    echo "Run this script again after you have the sources installed."
    exit 1
fi
echo "Found FreeBSD-armv6 source tree in $FREEBSD_SRC"

#
# Build and configure U-Boot
#
if [ ! -f ${BUILDOBJ}/_.uboot.patched ]; then
    cd "$UBOOT_SRC"
    echo "Patching U-Boot. (Logging to ${BUILDOBJ}/_.uboot.patch.log)"
    # Works around a FreeBSD bug (freestanding builds require libc).
    patch -N -p1 < ../files/uboot_patch1_add_libc_to_link_on_FreeBSD.patch > ${BUILDOBJ}/_.uboot.patch.log 2>&1
    # Turn on some additional U-Boot features not ordinarily present in TIs build.
    patch -N -p1 < ../files/uboot_patch2_add_options_to_am335x_config.patch >> ${BUILDOBJ}/_.uboot.patch.log 2>&1
    # Fix a U-Boot bug that has been fixed in the master sources but not yet in TIs sources.
    patch -N -p1 < ../files/uboot_patch3_fix_api_disk_enumeration.patch >> ${BUILDOBJ}/_.uboot.patch.log 2>&1
    # Turn off some features that bloat the MLO so it can't link
    patch -N -p1 < ../files/uboot_patch4_shrink_spl.patch >> ${BUILDOBJ}/_.uboot.patch.log 2>&1

    touch ${BUILDOBJ}/_.uboot.patched
    rm -f ${BUILDOBJ}/_.uboot.configured
fi

if [ ! -f ${BUILDOBJ}/_.uboot.configured ]; then
    cd "$UBOOT_SRC"
    echo "Configuring U-Boot. (Logging to ${BUILDOBJ}/_.uboot.configure.log)"
    gmake CROSS_COMPILE=armv6-freebsd- am335x_evm_config > ${BUILDOBJ}/_.uboot.configure.log 2>&1
    touch ${BUILDOBJ}/_.uboot.configured
    rm -f ${BUILDOBJ}/_.uboot.built
fi

if [ ! -f ${BUILDOBJ}/_.uboot.built ]; then
    cd "$UBOOT_SRC"
    echo "Building U-Boot. (Logging to ${BUILDOBJ}/_.uboot.build.log)"
    gmake CROSS_COMPILE=armv6-freebsd- > ${BUILDOBJ}/_.uboot.build.log 2>&1
    touch ${BUILDOBJ}/_.uboot.built
else
    echo "Using U-Boot from previous build."
fi

cd $TOPDIR

#
# Build FreeBSD for BeagleBone
#
if [ ! -f ${BUILDOBJ}/_.built-world ]; then
    echo "Building FreeBSD-armv6 world at "`date`" (Logging to ${BUILDOBJ}/_.buildworld.log)"
    cd $FREEBSD_SRC
    make TARGET_ARCH=armv6 DEBUG_FLAGS=-g buildworld > ${BUILDOBJ}/_.buildworld.log 2>&1
    cd $TOPDIR
    touch ${BUILDOBJ}/_.built-world
else
    echo "Using FreeBSD world from previous build"
fi

if [ ! -f ${BUILDOBJ}/_.built-kernel ]; then
    echo "Building FreeBSD-armv6 kernel at "`date`" (Logging to ${BUILDOBJ}/_.buildkernel.log)"
    cd $FREEBSD_SRC
    make TARGET_ARCH=armv6 KERNCONF=$KERNCONF buildkernel > ${BUILDOBJ}/_.buildkernel.log 2>&1
    cd $TOPDIR
    touch ${BUILDOBJ}/_.built-kernel
else
    echo "Using FreeBSD kernel from previous build"
fi

#
# Build FreeBSD's ubldr
#
if [ ! -f ${BUILDOBJ}/ubldr/ubldr ]; then
    echo "Building FreeBSD arm:arm ubldr"
    rm -rf ${BUILDOBJ}/ubldr
    mkdir -p ${BUILDOBJ}/ubldr
    # Assumes commits have been merged!
    cd ${FREEBSD_SRC}
    #cd /usr/src
    ubldr_makefiles=`pwd`/share/mk
    buildenv=`make TARGET_ARCH=armv6 buildenvvars`
    cd sys/boot
    eval $buildenv make -m $ubldr_makefiles obj > ${BUILDOBJ}/_.ubldr.build.log
    eval $buildenv make -m $ubldr_makefiles depend >> ${BUILDOBJ}/_.ubldr.build.log
    eval $buildenv make UBLDR_LOADADDR=0x88000000 -m $ubldr_makefiles all >> ${BUILDOBJ}/_.ubldr.build.log
    cd arm/uboot
    eval $buildenv make DESTDIR=${BUILDOBJ}/ubldr/ BINDIR= NO_MAN=true -m $ubldr_makefiles install >> ${BUILDOBJ}/_.ubldr.build.log
else
    echo "Using FreeBSD arm:arm ubldr from previous build"
fi

#
# Create and partition the disk image
#
# TODO: Figure out how to include a swap partition here.
# Swapping to SD is painful, but not as bad as panicing
# the kernel when you run out of memory.
# TODO: Fix the kernel panics on out-of-memroy.
#
echo "Creating the raw disk image in ${IMG}"
[ -f ${IMG} ] && rm -f ${IMG}
dd if=/dev/zero of=${IMG} bs=1 seek=${SD_SIZE} count=0 >/dev/null 2>&1
MD=`mdconfig -a -t vnode -f ${IMG}`

echo "Partitioning the raw disk image at "`date`
# TI AM335x ROM code requires we use MBR partitioning.
gpart create -s MBR -f x ${MD}
gpart add -a 63 -b 63 -s2m -t '!12' -f x ${MD}
gpart set -a active -i 1 -f x ${MD}
# XXX Would like "-a 4m" here, but gpart doesn't honor it?
gpart add -t freebsd -f x ${MD}
gpart commit ${MD}

echo "Formatting the FAT partition at "`date`
# Note: Select FAT12, FAT16, or FAT32 depending on the size of the partition.
newfs_msdos -L "boot" -F 12 ${MD}s1 >/dev/null

echo "Formatting the UFS partition at "`date`
newfs ${MD}s2 >/dev/null
# Turn on Softupdates
tunefs -n enable /dev/${MD}s2
# Turn on SUJ
# This makes reboots tolerable if you just pull power on the BB
tunefs -j enable /dev/${MD}s2
# Turn on NFSv4 ACLs
tunefs -N enable /dev/${MD}s2
# SUJ journal to 4M (minimum size)
# A slow SDHC reads about 1MB/s, so the default 30M journal
# can introduce a 30s delay into the boot.
# XXX This doesn't seem to actually work.  After
# a bad reboot, fsck still claims to be
# reading a 30MB journal. XXX
tunefs -S 4194304 /dev/${MD}s2

echo "Mounting the virtual disk partitions"
if [ -d ${BUILDOBJ}/_.mounted_fat ]; then
    rmdir ${BUILDOBJ}/_.mounted_fat
fi
mkdir ${BUILDOBJ}/_.mounted_fat
mount_msdosfs /dev/${MD}s1 ${BUILDOBJ}/_.mounted_fat
if [ -d ${BUILDOBJ}/_.mounted_ufs ]; then
    rmdir ${BUILDOBJ}/_.mounted_ufs
fi
mkdir ${BUILDOBJ}/_.mounted_ufs
mount /dev/${MD}s2 ${BUILDOBJ}/_.mounted_ufs

#
# Install U-Boot onto FAT partition.
#
echo "Installing U-Boot onto the FAT partition at "`date`
cp ${UBOOT_SRC}/MLO ${BUILDOBJ}/_.mounted_fat/
cp ${UBOOT_SRC}/u-boot.img ${BUILDOBJ}/_.mounted_fat/
cp ${TOPDIR}/files/uEnv.txt ${BUILDOBJ}/_.mounted_fat/

#
# Install ubldr onto FAT partition.
#
echo "Installing ubldr onto the FAT partition at "`date`
cp ${BUILDOBJ}/ubldr/ubldr ${BUILDOBJ}/_.mounted_fat/
cp ${BUILDOBJ}/ubldr/loader.help ${BUILDOBJ}/_.mounted_fat/

#
# Install FreeBSD kernel and world onto UFS partition.
#
cd $FREEBSD_SRC
echo "Installing FreeBSD kernel onto the UFS partition at "`date`
make TARGET_ARCH=armv6 DESTDIR=${BUILDOBJ}/_.mounted_ufs KERNCONF=${KERNCONF} installkernel > ${BUILDOBJ}/_.installkernel.log 2>&1

if [ -z "$NO_WORLD" ]; then
    echo "Installing FreeBSD world onto the UFS partition at "`date`
    make TARGET_ARCH=armv6 DEBUG_FLAGS=-g DESTDIR=${BUILDOBJ}/_.mounted_ufs installworld > ${BUILDOBJ}/_.installworld.log 2>&1
    make TARGET_ARCH=armv6 DESTDIR=${BUILDOBJ}/_.mounted_ufs distrib-dirs > ${BUILDOBJ}/_.distrib-dirs.log 2>&1
    make TARGET_ARCH=armv6 DESTDIR=${BUILDOBJ}/_.mounted_ufs distribution > ${BUILDOBJ}/_.distribution.log 2>&1
fi

# Copy configuration files
#
echo "Configuring FreeBSD at "`date`
cd ${TOPDIR}/files/overlay
find . | cpio -p ${BUILDOBJ}/_.mounted_ufs

# If requested, copy source onto card as well.
if [ -n "$INSTALL_USR_SRC" ]; then
    echo "Copying source to /usr/src on disk image at "`date`
    mkdir -p ${BUILDOBJ}/_.mounted_ufs/usr/src
    cd ${BUILDOBJ}/_.mounted_ufs/usr/src
    # Note: Includes the .svn directory.
    (cd $FREEBSD_SRC ; tar cf - .) | tar xpf -
fi

# If requested, install a ports tree.
if [ -n "$INSTALL_USR_PORTS" ]; then
    mkdir -p ${BUILDOBJ}/_.mounted_ufs/usr/ports
    echo "Updating ports snapshot at "`date`
    portsnap fetch > ${BUILDOBJ}/_.portsnap.fetch.log
    echo "Installing ports tree at "`date`
    portsnap -p ${BUILDOBJ}/_.mounted_ufs/usr/ports extract > ${BUILDOBJ}/_.portsnap.extract.log
fi

#
# Unmount and clean up.
#
echo "Unmounting the disk image at "`date`
cd $TOPDIR
umount ${BUILDOBJ}/_.mounted_fat
umount ${BUILDOBJ}/_.mounted_ufs
mdconfig -d -u ${MD}

#
# We have a finished image; explain what to do with it.
#
echo "DONE."
echo "Completed disk image is in: ${IMG}"
echo
echo "Copy to a MicroSDHC card using a command such as:"
echo "dd if=${IMG} of=/dev/da0"
echo "(Replace /dev/da0 with the appropriate path for your SDHC card reader.)"
echo
date
