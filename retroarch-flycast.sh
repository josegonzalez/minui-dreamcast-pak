#!/bin/sh

#overclock.elf userspace 2 1344 384 1080 0

echo $0 $*
RA_DIR=/mnt/SDCARD/Tools/$PLATFORM/RetroArch.pak
EMU_DIR=/mnt/SDCARD/Emus/$PLATFORM/DC.pak

cd "$RA_DIR"
HOME=$RA_DIR/ $RA_DIR/ra64.trimui -v -L $RA_DIR/.retroarch/cores/flycast_libretro.so "$*"
