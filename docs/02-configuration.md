# 02 · Configuration — make.conf, USE, FEATURES, kernel

The configuration that defines this system, with the reason for each choice. The live files are in
`config/` (`make.conf`, `kernel-base.fragment`, `kernel-hardened.fragment`, `sysctl-hardening.conf`,
`etc-portage/`). Per-package overrides are listed in [07-exceptions.md](07-exceptions.md). The values
below are the final hardened state, not the early bring-up.

## Profile

`default/linux/amd64/23.0/musl/llvm`. This profile ships the target toolchain by default: `CC=clang`,
`CXX=clang++`, `LD=ld.lld`, `AR=llvm-ar`, `NM=llvm-nm`, and sets `pie cet seccomp`.

There is no `musl/llvm/hardened` or `musl/llvm/selinux` composite profile. The hardened and selinux
leaf profiles are GCC-based and would drop LLVM, which is required. Hardening and SELinux are therefore
layered on top through flags and USE; see E2 in [07-exceptions.md](07-exceptions.md).

## make.conf

```sh
COMMON_FLAGS="-march=x86-64-v3 -O3 -pipe -fstack-protector-strong -fno-semantic-interposition \
              -flto -D_FORTIFY_SOURCE=3 -fstack-clash-protection -fcf-protection=full \
              -ftrivial-auto-var-init=zero -fzero-call-used-regs=used-gpr"
LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,separate-code"
ACCEPT_KEYWORDS="~amd64"
FEATURES="test fail-clean buildpkg preserve-libs parallel-install"
PORTAGE_LOGDIR="/var/log/portage"
USE="clang lto pie selinux hardened btrfs elogind dbus nls wayland pipewire alsa libinput \
     policykit networkmanager screencast vaapi vulkan -X -pulseaudio -systemd -gnome -kde -qt5 -qt6"
VIDEO_CARDS="virtio virgl"
INPUT_DEVICES="libinput"
GRUB_PLATFORMS="efi-64"
```

- `-flto` (full): the target is full LTO. `-flto=auto` is a GCC spelling; clang needs `-flto` or
  `-flto=thin`. Bring-up used ThinLTO for build speed and lower RAM, then switched to full LTO; see E1
  and [06-full-lto.md](06-full-lto.md).
- Hardening flags: `-fstack-protector-strong`, `-D_FORTIFY_SOURCE=3`, `-fstack-clash-protection`,
  `-fcf-protection=full` (CET; `endbr64` verified in shipped binaries), `-ftrivial-auto-var-init=zero`,
  and `-fzero-call-used-regs=used-gpr`. `-O3` is used. PIE, CET, and seccomp also come from the 23.0
  profile; RELRO, BIND_NOW, noexecstack, and separate-code come from LDFLAGS. These were applied in two
  passes (full LTO, then the extra flags) via `emerge -e @world`; see E16.
- `ACCEPT_KEYWORDS="~amd64"`: the musl/llvm profile is experimental and many dependencies are only in
  `~amd64`; see E3.
- `FEATURES=test`: kept globally as part of the target. It is the main source of breakage (see
  [08-findings.md](08-findings.md)) and is never disabled globally; only narrow per-package exceptions
  exist.
- `PORTAGE_LOGDIR`: `fail-clean` deletes the build directory on failure. This keeps a copy of every
  `build.log` so compile errors remain available.
- `-X -pulseaudio -systemd`: no X11, no PulseAudio, no systemd, globally.

## Effective toolchain

```
CC=clang  CXX=clang++  LD=ld.lld  AR=llvm-ar  CHOST=x86_64-pc-linux-musl  ELIBC=musl
clang 22.1.8 ; LLD 22.1.8 ; ldd → "musl libc (x86_64)" ; gcc not installed
```

## Kernel

Built with clang (`make LLVM=1`); config is `make defconfig` plus two fragments merged in order:
`config/kernel-base.fragment` (base) and `config/kernel-hardened.fragment` (v2 hardening).

Base fragment (`kernel-base.fragment`):

- virtio built in (`VIRTIO_BLK/PCI/NET/GPU`, `EXT4_FS`, `EFI_STUB`): the root filesystem mounts with no
  initramfs, the simplest reliable boot in QEMU.
- serial (`SERIAL_8250_CONSOLE`): headless console after reboot.
- SELinux (`SECURITY_SELINUX`, `AUDIT`, `CONFIG_LSM=...,selinux`, `EXT4_FS_SECURITY`): required for the
  SELinux target; see [04-selinux.md](04-selinux.md).
- base hardening (`RANDOMIZE_BASE`, `FORTIFY_SOURCE`, `HARDENED_USERCOPY`, `INIT_ON_ALLOC`,
  `SLAB_FREELIST_HARDENED`, `STACKPROTECTOR_STRONG`).

Hardened fragment (`kernel-hardened.fragment`), clang-specific and KSPP:

- KCFI and kernel LTO: `CONFIG_CFI` (forward-edge Control Flow Integrity; this is the kernel 7.1 name,
  renamed from `CONFIG_CFI_CLANG`), `CONFIG_CFI_PERMISSIVE=n`, `LTO_CLANG`, `LTO_CLANG_THIN`. The
  gcc-plugin features STACKLEAK and RANDSTRUCT are not available under clang; KCFI and LTO are used
  instead.
- register and stack hardening: `ZERO_CALL_USED_REGS`, `RANDOMIZE_KSTACK_OFFSET(_DEFAULT)`,
  `SCHED_STACK_END_CHECK`, `VMAP_STACK`.
- lockdown LSM: `SECURITY_LOCKDOWN_LSM(_EARLY)`; mode chosen at boot with `lockdown=`.
- allocator and list hardening (KSPP): `INIT_ON_FREE_DEFAULT_ON`, `SHUFFLE_PAGE_ALLOCATOR`,
  `LIST_HARDENED`, `BUG_ON_DATA_CORRUPTION`, `SLAB_BUCKETS`, `KFENCE`.
- IOMMU strict, `STRICT_KERNEL/MODULE_RWX`, `DEBUG_WX`, `SECURITY_DMESG_RESTRICT`,
  `LEGACY_VSYSCALL_NONE`, `DEVMEM=n`, `PROC_KCORE=n`.

Boot command line (`/etc/default/grub`): serial console and the SELinux LSM, plus the KSPP and CPU
mitigation set: `lockdown=confidentiality`, `mitigations=auto,nosmt`, explicit
spectre/ssb/l1tf/mds/tsx/mmio/retbleed/gds switches, and `slab_nomerge init_on_alloc=1 init_on_free=1
randomize_kstack_offset=on pti=on vsyscall=none debugfs=off`.

## Runtime sysctl (`config/sysctl-hardening.conf`)

Installed as `/etc/sysctl.d/99-hardening.conf` on both images. KSPP-style settings:
`kernel.kptr_restrict=2`, `dmesg_restrict=1`, `kexec_load_disabled=1`, `unprivileged_bpf_disabled=1`,
`yama.ptrace_scope=2`, `kernel.randomize_va_space=2`, the `fs.protected_*` set, and network hardening
(`rp_filter`, no redirects, no source routing). It also sets performance values (`vm.swappiness`, BBR
where available); values needing a kernel feature the VM lacks are skipped with a warning.

## Not changed

musl is not replaced by glibc; OpenRC is not replaced by systemd; clang remains the default compiler;
`-X`, `-pulseaudio`, and `-systemd` stay global; LTO and PIE stay on; `FEATURES=test` stays on; the
profile is not changed to an easier one.
