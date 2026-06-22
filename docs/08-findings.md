# 08 · QA findings — the bug-report-worthy stuff

> **Context:** The actual QA payoff: concrete, reproducible breakage in the Gentoo ecosystem under
> the musl/LLVM/SELinux/Wayland/test combination, framed for filing. Standalone. Logs referenced
> here are under `artifacts/checkpoints/` and (in the guest) `/var/log/portage/`.

## F1 — libselinux fails to build on musl (`USE_LFS=y` uses glibc-only `stat64`) ★ strongest
- **Package:** `sys-libs/libselinux-3.10-r1`. **Phase:** compile.
- **Error:** `selinux_restorecon.c:446: variable has incomplete type 'struct stat64'` +
  `:460: call to undeclared function 'lstat64'`.
- **Cause:** the Makefile passes `USE_LFS=y`, and the source uses `struct stat64`/`lstat64()`, which
  **musl does not provide** (its `stat`/`lstat` are already 64-bit). clang makes the implicit decl a
  hard error.
- **musl-specific, not toolchain-specific:** would fail on GCC too (incomplete type is fatal).
- **Fix candidate:** use `stat`/`lstat` on musl, or guard the `*64` names with `__GLIBC__`.
- **Impact:** blocks the *entire* SELinux userland on musl until patched. Patch in
  `config/etc-portage/patches/sys-libs/libselinux/0001-musl-no-stat64.patch`.

## F2 — `FEATURES=test` reintroduces X11 on a no-X11 target ★ structural
- **Symptom:** `emerge -uDN @world` and even targeted base rebuilds pull `x11-base/xorg-server`,
  `media-libs/mesa[X]`, `libepoxy[X]` and then fail on `xorg-server[xvfb]`.
- **Chain:** `dev-libs/glib[dbus]` → `gdbus-codegen` → `gnome-base/dconf[test]` → X stack; also
  `net-firewall/iptables[test]` `REQUIRED_USE="test?(conntrack nftables)"`.
- **Cause:** global `FEATURES=test` auto-enables `test` USE on GUI/D-Bus libs, whose **test-deps**
  require X. **Conclusion:** `FEATURES=test` is effectively incompatible with a Wayland-only/no-X11
  musl/llvm desktop target. (Mitigated by command-scoped `FEATURES=-test` on bulk rebuilds.)

## F3 — enabling SELinux-aware coreutils breaks the build sandbox ★ surprising
- **Symptom:** after `coreutils[selinux]`, every package install fails; log shows repeated
  `F: open_wr / S: deny / P: /proc/thread-self/attr/fscreate` during `cp -a`.
- **Cause:** SELinux-aware `cp -a` writes the fscreate context to `/proc/*/attr/fscreate`; Gentoo's
  build sandbox denies that path.
- **Fix candidate:** `sys-apps/sandbox` should allow `/proc/*/attr/` when SELinux is active (we add
  `SANDBOX_WRITE` manually). High impact: silently bricks all emerges once SELinux is on.

## F4 — elogind fails to build on musl
- **Package:** `sys-auth/elogind-257.16`. **Error:** `sd-journal/journal-file.h:80: field has
  incomplete type 'struct stat'` (missing `<sys/stat.h>` visibility on musl).
- **Workaround:** none applied; substituted standalone `seatd`. Reportable as a musl include bug.

## F5 — `FEATURES=test` REQUIRED_USE / cycle cluster
A family of test-induced resolution failures, each individually a paper-cut but collectively the
dominant friction:
- `lvm2[test]` `REQUIRED_USE="test?(lvm)"` (pulled by `grub[device-mapper]`).
- `expect`↔`dejagnu` circular build dep; `efivar`→`grub`→`efibootmgr` cycle.
- `setools`/`selinux-python` test-deps → `pyqt6[testlib]` + python tree → `pillow`
  `REQUIRED_USE="test?(jpeg jpeg2k lcms tiff truetype)"` (unsatisfiable); `setuptools` slot conflict.
- `app-misc/pax-utils[test]` `REQUIRED_USE="test?(python)"` (in `@system`, blocks `@world`).
- **Theme for a report:** on a fresh musl/llvm base, `FEATURES=test` cannot resolve `@system`/`@world`
  without numerous per-package test exceptions; several REQUIRED_USE constraints make `test` a hard
  blocker rather than a soft one.

## F6 — profile gap: no musl+llvm+hardened+selinux profile; `selinux` USE masked off-profile
- There is no composite profile for the target; and `selinux` is masked by `profiles/base/use.mask`
  unless on a SELinux profile, so a musl/llvm SELinux target needs a manual `use.mask` override.

## F7 — full LTO + aggressive hardening rebuild: clean (the notable non-finding)
Two full `emerge -e @world` passes (≈440 pkgs each) under (1) full `-flto`, then (2) full LTO +
`-O3` + CET (`-fcf-protection=full`) + `-fstack-clash-protection` + `-ftrivial-auto-var-init=zero`
+ `-fzero-call-used-regs=used-gpr` + lld `--icf=safe`/`separate-code`/`noexecstack`. **Both boot.**
The toolchain itself (clang/llvm 22) rebuilds under full LTO. Across both passes the *only* failures
were the three already-known ones below — the aggressive flags introduced **zero new breakage**.
Failures (identical in both passes):
- `llvm-core/llvm-21.1.8` — obsolete; superseded by 22.1.8 which built fine. The `-e` attempt to
  rebuild the old 21 source fails on a libc++-22 `static_assert` (`make_transparent`/`std::less<void>`
  in `HexagonRDFOpt.cpp`) — a version skew, not LTO/OOM. Non-issue (22 is installed & consistent).
- `sys-apps/net-tools-2.10` — `linux/rose.h` (see F8 / E17) — now FIXED.
- `sys-auth/elogind-257.16` — musl build blocker (F4 / E14) — substituted by seatd.

## F8 — net-tools needs linux/rose.h which kernel-7.1 UAPI omits (FIXED via E17)
`net-tools-2.10` `lib/rose.c` does `#include <linux/rose.h>` under `#if HAVE_AFROSE` (config default
y), but kernel-7.1 ships no `linux/rose.h` (only `ax25.h`). Not a musl issue. Fixed by disabling
ROSE in config.in (`/etc/portage/bashrc` hook). Reportable: net-tools has no USE/toggle for ROSE.

## F9 — desktops blocked on musl by the logind wall (GNOME *and* KDE)
Modern full DEs hard-require a logind provider (`elogind` or `systemd`); on musl `elogind` is
unbuildable (F4/E14: gshadow.h) and systemd is prohibited, so:
- **GNOME** (E19): mutter[wayland] `^^(elogind systemd)`; also forces X11 + PulseAudio.
- **KDE Plasma** (E22): `plasma-workspace` *unconditionally* deps `networkmanager-qt` → `networkmanager[elogind]`;
  also `accountsservice` `^^(elogind systemd)`. Resolved 277 pkgs otherwise (qt6+X stack), but the
  logind dep is not USE-removable. *Better than GNOME on one axis:* with `FEATURES=-test` KDE needs only
  X **client** libs + XWayland, **no xorg-server** (the xorg-server pull was a `libglvnd[test,X]→xvfb`
  test artifact). Working wlroots compositors (Hyprland, sway) avoid this because they use **seatd**, not logind.

## F10 — firefox on musl: static rust-bin can't dlopen libclang (bindgen)
firefox builds gcc/nodejs but `mach build` dies: bindgen panics `Unable to find libclang ... Dynamic
loading not supported` — the toolchain's `rust-bin` is statically linked (musl), and static musl can't
`dlopen()`. Fix path: dev-lang/rust from SOURCE (dynamic) MATCHED to firefox's LLVM slot (firefox-152
wants LLVM 21; our source rust was LLVM 22). Deferred (browsers = "later"). (E20.)

## F11 — self-induced: `-Wl,--icf=safe` (lld-only) breaks the GCC bootstrap
The E16 hardening LDFLAGS added `--icf=safe`; GCC's libgcc links via GNU ld (not lld), which rejects
it → gcc-16 fails → cascades. Lesson: lld-only flags in global LDFLAGS break any GNU-ld build. Removed it.

## F12 — full-LTO + KCFI hardened kernel: SUCCESS (the headline positive)
Two full `emerge -e @world` passes (full `-flto`, then +`-O3`/CET/stack-clash/auto-var-init/zero-call-regs)
both boot with ZERO new failures; toolchain (clang/llvm 22) rebuilt under full LTO. A clang-built kernel
with **KCFI** (`CONFIG_CFI`, kernel 7.1 renamed from `CONFIG_CFI_CLANG`) + `LTO_CLANG` + lockdown=confidentiality
+ all CPU side-channel mitigations boots and runs (`dmesg: CFI: Using rehashed retpoline kCFI`).
(gcc-plugin STACKLEAK/RANDSTRUCT are N/A under clang — KCFI/LTO substitute.) Snapshot `hardened-kernel-kcfi`.

## Open / in-progress / roadmap
Done in order; each stage snapshots before the next so failures are recoverable.
Snapshots so far: `base-musl-llvm-selinux-wayland`, `base-full-lto`, `base-full-lto-hardened`.

1. **Full-LTO `@world`:** ✅ done (snapshot `base-full-lto`); extra-hardening pass ✅ done
   (snapshot `base-full-lto-hardened`). See [06-full-lto.md](06-full-lto.md) and F7 above.
2. **Hyprland** (via third-party `hyproverlay`; XWayland off, `-X`) — in progress.
3. **wlroots + sway** — also XWayland off (`-X`).
4. **Wayland session/portal stack** — pipewire / seatd / xdg-desktop-portal-wlr.
5. **SELinux → enforcing** — switch from permissive after reviewing AVC denials.
6. **GNOME** — plus a **comparison experiment**: everything so far is `-X` (no XWayland); also test
   GNOME with `+X`/XWayland enabled to see whether X11/XWayland actually works better than pure Wayland.
7. **Browsers** — ≥1 per family (Firefox: Mullvad/Tor/LibreWolf; Chromium: Trivalent/Cromite/Brave).
2. **Hyprland** (compositor, the "B" goal): heavy C++ Wayland stack — a strong combined test of
   full-LTO + musl + clang. Attempted on the full-LTO base.
3. **GNOME:** stretch goal. Known to fail even on Arch per the user, so this is expected to be a
   high-value *failure* artifact as much as a success target.
4. **Browsers — run at least one from each family** under Wayland:
   - Firefox family: **Mullvad Browser**, **Tor Browser**, **LibreWolf**
   - Chromium family: **Trivalent**, **Cromite**, **Brave**
   These are the real torture test for musl + clang + LTO (giant C++ builds, many of which assume
   glibc); each that builds *and runs* is recorded, each that breaks is filed here with its log.
5. **SELinux → enforcing:** only if the desktop + at least one browser actually run. Move
   `SELINUX=enforcing` after reviewing AVC denials and extending policy for the custom daemons.
   Until then it stays **permissive** (target was "enabled if feasible," already met).
