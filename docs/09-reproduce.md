# 09 · Reproduce from scratch

How to rebuild this on another machine. This is a checklist; it pairs with `scripts/install.sh` and
the reasoning in [03-install-walkthrough.md](03-install-walkthrough.md).

## Inputs

- A Linux host with QEMU/KVM, `qemu-img`, `sshpass`, `socat`, `jq`, and `bsdtar`.
- A Gentoo minimal install ISO and a `stage3-amd64-musl-llvm-openrc` tarball.
- This repository (`config/` and `scripts/` are the parts that matter).

## 1. Create the guest

```sh
qemu-img create -f qcow2 gentoo-musl-llvm.qcow2 60G
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd OVMF_VARS.fd       # writable UEFI vars
bsdtar xf <iso> boot/gentoo boot/gentoo.igz               # live kernel + initrd for direct boot
scripts/launch-vm.sh        # boots the live ISO; serial on a unix socket, 9p share, SSH host:2224->guest:22
```

Direct-kernel command line: `root=live:CDLABEL=Gentoo-amd64-<date> ... cdroot console=ttyS0,115200`.

## 2. Bootstrap the live environment (over serial, via `vmctl.py`)

Set a root password and start sshd (`/etc/init.d/sshd start`, `PermitRootLogin yes`). After that, use
`scripts/gssh 'cmd'`.

## 3. Run the install

`scripts/install.sh` is the ordered procedure. It expects the stage3 and this repository reachable at
`/mnt/hostshare` (the 9p share). It will: partition `/dev/vda`, unpack the stage3, chroot, install
`config/make.conf` and the `config/etc-portage/` overrides (including the libselinux patch), run
`emerge-webrsync`, build the clang kernel from `config/kernel-base.fragment`, install grub, write fstab
and services, set up SELinux (permissive at this stage), install Wayland/PipeWire, then switch to full
LTO.

Read [03-install-walkthrough.md](03-install-walkthrough.md) alongside it for the reason behind each
step, in particular: mount `/boot` before grub; the `FEATURES=test` exceptions (E4–E13); unmasking
`selinux` (E10); and seatd instead of elogind (E14/E15).

## 4. Boot the installed system

```sh
scripts/launch-disk.sh      # OVMF -> /boot/EFI/BOOT/BOOTX64.EFI -> GRUB -> disk
```

## 5. Verify

```sh
scripts/gssh 'uname -a; ldd --version; clang --version; gcc --version || echo no-gcc; \
  cat /proc/1/comm; sestatus; id -Z; rc-status; \
  qlist -ICv x11-base/xorg-server || echo no-xorg; \
  qlist -ICv media-sound/pulseaudio || echo no-pulse'
```

Expected: musl, clang/lld, no gcc, `init` as PID 1, SELinux enabled and enforcing, OpenRC services up,
no xorg-server, no pulseaudio.

## 6. Snapshot

Snapshotting between stages makes a failed stage recoverable. With the guest powered off:

```sh
qemu-img snapshot -c base-musl-llvm-selinux-wayland gentoo-musl-llvm.qcow2
qemu-img snapshot -c base-full-lto gentoo-musl-llvm.qcow2     # after a verified full-LTO base
```

## Credentials and ports (this instance)

SSH `root@127.0.0.1:2224`, password `gentooqa`. Change both for any non-disposable use.
