# 03 · Install walkthrough

The install in order, each step with its reason. The executable form is `scripts/install.sh`. The
harder subsystems have their own pages ([04-selinux.md](04-selinux.md),
[05-wayland-pipewire.md](05-wayland-pipewire.md), [06-full-lto.md](06-full-lto.md)); this page is the
outline.

1. **Partition `/dev/vda`.** GPT: ESP 512M (vfat), swap 8G, root 51.5G (ext4). ext4 is the simplest
   reliable root. The 8G swap covers full-LTO links, which use a lot of RAM, on a 16 GiB guest.

2. **Unpack `stage3-amd64-musl-llvm-openrc`** to `/mnt/gentoo`. This stage3 ships musl, clang/lld, and
   OpenRC and selects the `musl/llvm` profile, so the toolchain is correct without overrides.

3. **Prepare the chroot.** Bind `/proc /sys /dev /run`, copy `resolv.conf`, and mount the ESP at
   `/mnt/gentoo/boot`. `/boot` must be mounted now because grub and grub-themes use
   `mount-boot.eclass`, which refuses to install when `/boot` is not mounted. Skipping this drops grub
   from the merge without an error.

4. **Write `make.conf`** (see [02-configuration.md](02-configuration.md)) and run `emerge-webrsync`;
   the stage3 has no ebuild tree.

5. **Boot tooling and kernel.** `emerge gentoo-sources installkernel grub efibootmgr dosfstools git`,
   then build the kernel with `make LLVM=1` using `defconfig` plus `kernel-base.fragment` and
   `kernel-hardened.fragment` (KCFI, LTO_CLANG, lockdown, KSPP). The kernel is built with clang because
   the LLVM toolchain is the target and the kernel supports `LLVM=1`. No
   initramfs is used because virtio and ext4 are built in, so the root mounts directly. Expect a few
   `FEATURES=test` bootstrap problems here (E4–E6 in [07-exceptions.md](07-exceptions.md)).

6. **Bootloader.** `grub-install --removable` writes `BOOTX64.EFI`, which OVMF boots without an NVRAM
   entry; a named `Gentoo` entry is added as well. `grub-mkconfig` generates the config. The GRUB
   command line includes `console=tty0 console=ttyS0,115200 lsm=...,selinux,...`.

7. **fstab, hostname, root password, services.** fstab by UUID; `root:gentooqa`; sshd permits root
   login; a `ttyS0` agetty in `/etc/inittab`; `rc-update add sshd dhcpcd`.

8. **First boot from disk** (`scripts/launch-disk.sh`). Verified: boots, OpenRC starts, SSH is up in
   about 9 s, musl and clang/lld present, no gcc, networking works.

9. **SELinux (permissive at this stage).** Full account in [04-selinux.md](04-selinux.md). In short:
   unmask the `selinux` USE flag (E10), patch libselinux for musl (E9), handle the `FEATURES=test`
   cascades (E5–E8, E11–E13), rebuild the base with `selinux`, label the filesystem, reboot; SELinux is
   then active at boot.

10. **Wayland and PipeWire.** See [05-wayland-pipewire.md](05-wayland-pipewire.md). Install
    pipewire, wireplumber, wayland, seatd, and mesa with no X11 and no elogind (seatd instead;
    E14/E15).

11. **Full LTO.** See [06-full-lto.md](06-full-lto.md). Switch to `-flto` and run `emerge -e @world`.

12. **Snapshot** the verified state (`base-musl-llvm-selinux-wayland`, then `base-full-lto`).
