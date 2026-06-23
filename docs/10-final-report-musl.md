# 10 · Final report — musl image

The final state of the musl/LLVM image. Verified state is captured in `artifacts/final/`. Related
detail: [02-configuration.md](02-configuration.md), [04-selinux.md](04-selinux.md),
[07-exceptions.md](07-exceptions.md), [08-findings.md](08-findings.md).

Result: a bootable, reproducible Gentoo musl/LLVM image that meets every required option. The desktop
limits are recorded as findings.

1. **Stage3:** `stage3-amd64-musl-llvm-openrc-20260614T170130Z.tar.xz` (sha256 `b8a97df7…def84bd`,
   recorded in `artifacts/commands.log`).
2. **Profile:** `default/linux/amd64/23.0/musl/llvm`, kept; no musl/llvm/hardened/selinux composite
   exists, so hardening and SELinux are layered (E2).
3. **USE:** `clang lto pie selinux hardened btrfs -elogind dbus nls opengl qml wayland pipewire alsa
   libinput policykit networkmanager screencast vaapi vulkan -X -pulseaudio -systemd -gnome -kde`
   (with `~amd64`; `-elogind` because elogind is unbuildable on musl, E14). Full make.conf in
   `config/make.conf`.
4. **FEATURES:** `test fail-clean buildpkg preserve-libs parallel-install` with `PORTAGE_LOGDIR`.
   Global `test` kept; only narrow per-package and command-scoped `-test` exceptions (E5–E8, E11–E13).
5. **Compiler and linker:** clang 22.1.8, `ld.lld` 22, `AR=llvm-ar`, `NM=llvm-nm` (set by the profile).
6. **libc:** musl (`ldd → musl libc`; `sys-libs/glibc` not installed). `sys-devel/gcc-16` is installed,
   pulled as a build dependency by nodejs/rust during the Firefox attempt, but `CC`/`CXX` stay
   clang/clang++; the default toolchain was not switched to GCC.
7. **Init:** OpenRC (sysvinit + openrc); no systemd (`systemctl` absent).
8. **SELinux:** enforcing, `targeted` policy, filesystem labeled, services confined
   (`init_t`/`sshd_t`/`system_dbusd_t`/`seatd_t`). Root login is mapped to
   `sysadm_u:sysadm_r:sysadm_t`, a confined admin domain rather than the `unconfined_t` that stock
   targeted policies leave root in. `__default__` maps to `unconfined_u`. No AVC denials at boot. Custom
   module `qa_local` (sshd login transition and service denials, via audit2allow). See
   [04-selinux.md](04-selinux.md).
9. **Audio:** PipeWire with wireplumber; no PulseAudio (`media-sound/pulseaudio` absent).
10. **Display:** Wayland only, no `x11-base/xorg-server`. Only X client libraries are present (libX11
    and libXcursor, pulled by Hyprland's cursor dependency, E18); XWayland off (`-X`). Compositors use
    seatd.
11. **LTO, PIE, hardening:** full `-flto`, `-O3`, `-fstack-protector-strong`, `-D_FORTIFY_SOURCE=3`,
    `-fstack-clash-protection`, `-fcf-protection=full` (CET), `-ftrivial-auto-var-init=zero`,
    `-fzero-call-used-regs=used-gpr`; LDFLAGS with RELRO/BIND_NOW/noexecstack/separate-code; PIE, CET,
    and seccomp from the 23.0 profile. Kernel: clang-built with KCFI (`CONFIG_CFI`), `LTO_CLANG`,
    KASLR, hardened-usercopy, init-on-alloc/free, and slab hardening; boot command line
    `lockdown=confidentiality`, full CPU side-channel mitigations (`mitigations=auto,nosmt` plus
    explicit spectre/ssb/l1tf/mds/tsx/mmio/retbleed/gds), and KSPP parameters (slab_nomerge,
    randomize_kstack, pti=on, vsyscall=none, debugfs=off).
12. **Exceptions:** E1–E22 in `artifacts/constraint-exceptions.md` (curated in
    [07-exceptions.md](07-exceptions.md)). Main items: libselinux musl `stat64` patch (E9), `selinux`
    USE unmask (E10), `FEATURES=test` cascades (E4–E8, E11–E13), grub `-device-mapper` (E4), net-tools
    ROSE off (E17), global `-elogind` (E14).
13. **Browser, blockers, and fixes (recorded as findings):**
    - Firefox (E20/F10): builds and runs. `firefox-152.0` built (EXIT_RC=0) and renders headless. The
      static-`rust-bin` `dlopen` failure is avoided by building with `LLVM_SLOT=22` so Firefox uses the
      installed dynamic source `dev-lang/rust-1.95.0`. Under enforcing, SELinux denies its content
      sandbox's `user_namespace create` (degradation, not a failure).
    - GNOME (E19) and KDE Plasma (E22): blocked by the logind requirement (elogind unbuildable on musl,
      systemd prohibited). Options in [08-findings.md](08-findings.md).
    - systemd-tmpfiles-setup: non-fatal boot warning under enforcing; services unaffected.
    - net-tools (E17) and elogind (E14): fixed and substituted (seatd), respectively.
14. **Reproduce:** `scripts/install.sh`, [09-reproduce.md](09-reproduce.md), and `config/` (make.conf,
    kernel fragments, `etc-portage/` overrides including patches), with `artifacts/commands.log`.
15. **Boots after reboot:** yes, verified across reboots (live to disk, full-LTO, hardened kernel, KCFI
    kernel, enforcing). UEFI (OVMF) → GRUB → `vmlinuz-7.1.1-gentoo` → OpenRC.
16. **SSH after reboot:** yes, sshd auto-starts under OpenRC, reachable on `127.0.0.1:2224`, and works
    under SELinux enforcing with root confined to sysadm_t.
17. **Changes from the target, with cause:** `-flto=auto` → `-flto`/`thin` (clang spelling, E1);
    hardening and SELinux layered instead of a composite profile (none exists, E2); `~amd64`
    (experimental profile, E3); global `-elogind` (unbuildable on musl, E14); narrow per-package and
    command-scoped `-test` (`FEATURES=test` causes unresolvable cascades, E5–E13); X client libraries
    allowed where a dependency forces them (E18); ThinLTO-to-full-LTO staging (E1). No required option
    was silently weakened.

## Stages

The work proceeded through these snapshots, each taken before the next stage:
`base-musl-llvm-selinux-wayland` → `base-full-lto` → `base-full-lto-hardened` → `hyprland` →
`wayland-desktop` → `hardened-kernel-kcfi` → `enforcing` (root mapped to `sysadm_t`).

## Verified running

Boot, OpenRC, SSH, networking; the clang/lld toolchain; SELinux enforcing with root confined; Hyprland
0.55.4 and sway 1.12 (wlroots 0.20.1) both built and launched on virtio-gpu DRM (swrast, no virgl);
PipeWire, wireplumber, seatd; xdg-desktop-portal and -wlr; Firefox 152.0 (built and renders headless).
Additional packages built and run: mpv 0.41, GStreamer 1.26, Lua 5.4, LuaJIT 2.1, yt-dlp, zig 0.16,
nim 2.2. The KCFI hardened kernel boots and enforces.

## Summary

On musl with OpenRC and no systemd, wlroots compositors via seatd are a working Wayland desktop;
GNOME and KDE are not, because they require logind and elogind does not build on musl. Global
`FEATURES=test` is the largest single source of friction. The rest of the stack (musl, clang, full
LTO, the KCFI hardened kernel, and enforcing SELinux) works and is reproducible.
