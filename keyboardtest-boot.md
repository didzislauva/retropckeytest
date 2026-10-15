# DOS-free keyboard test floppy

Build the image with:

```sh
./build-keyboardtest-boot.sh
```

The result is `keyboardtest-boot.img`, a raw 1.44 MB floppy image. Write the
whole image to a 3.5-inch 1.44 MB disk, or select it as drive A: in PCem.
This image has no FAT filesystem and contains no DOS installation.

The build script assembles the `BOOT_SECTOR` variant of `keyboardtest.asm` into
sector 0 (LBA 0).
BIOS loads that 512-byte sector at `0000:7C00`. The loader reads the next six
sectors (currently LBA 1-6, BIOS track 0/head 0/sectors 2-7) into `0000:8000`
and transfers control there. Those sectors contain the `BOOT_STAGE` variant of
the same source file. The script calculates the sector count each time; stage 2
must stay within the rest of the first track (at most 17 sectors).

The tester requires an IBM PC/AT compatible 286 or newer with a color text
display. Release Esc to finish. The test restores the BIOS keyboard interrupt
handler and waits on a finished screen; press Ctrl+Alt+Del to reboot.

The older `keyboardtest-floppy.img` remains the FreeDOS-based version.
