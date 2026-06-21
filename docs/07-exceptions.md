# 07 · Exceptions (E1–E15) — every deviation, with cause

> **Context:** The complete list of deviations from the literal target. Format per entry:
> **what → cause → fix → why it's not a weakening**. Each is minimal and reportable. The raw,
> append-only original lives in `artifacts/constraint-exceptions.md`; this is the curated view.
> Readable standalone, though [04-selinux.md](04-selinux.md) gives narrative for E5–E15.

### Spelling / profile
- **E1 — `-flto=auto` → `-flto`(full) / `-flto=thin`(bring-up).** *Cause:* `=auto` is a GCC-ism;
  clang rejects it. *Fix:* valid clang spelling. *Why ok:* LTO is **not** disabled; only the spelling
  changed (and ThinLTO→full is a documented escalation). See [06-full-lto.md](06-full-lto.md).
- **E2 — Stay on `musl/llvm` profile; layer hardened+SELinux via flags/USE.** *Cause:* no
  `musl/llvm/hardened` or `musl/llvm/selinux` composite profile exists; hardened/selinux leaf
  profiles are GCC-based. *Fix:* keep `musl/llvm`, add hardening flags + `selinux`/`hardened` USE.
  *Why ok:* LLVM is the hard constraint; nothing hardening-related is dropped, just not profile-driven.
- **E3 — `ACCEPT_KEYWORDS="~amd64"`.** *Cause:* the musl/llvm profile is experimental; many deps are
  ~amd64-only. *Why ok:* explicitly permitted for this QA target.

### FEATURES=test fallout (kept global; narrow exceptions only)
- **E4 — `sys-boot/grub -device-mapper`.** *Cause:* `FEATURES=test` auto-forces `lvm2[test]`, whose
  `REQUIRED_USE="test?(lvm)"` then demands `lvm`; lvm2 was only pulled by `grub[device-mapper]`.
  *Fix:* drop device-mapper (VM has no LVM). *Why ok:* LVM isn't a constraint; tests stay on.
- **E5 — `FEATURES=-test` for `expect`, `dejagnu`.** *Cause:* test USE creates a circular build dep
  expect↔dejagnu (Portage itself suggests `-test`). *Why ok:* per-package, on test-framework pkgs.
- **E6 — `FEATURES=-test` for `efivar`.** *Cause:* `efivar[test]`→grub→efibootmgr→efivar cycle.
- **E7 — `FEATURES=-test` for the SELinux userland cluster** (selinux-python, setools,
  policycoreutils, selinux-base). *Cause:* test-deps pull `pyqt6[testlib]` + a python tree ending in
  `pillow` `REQUIRED_USE="test?(jpeg jpeg2k lcms tiff truetype)"` (unsatisfiable). *Why ok:* SELinux
  userland is otherwise uninstallable; tests for the C/C++ targets remain on.
- **E8 — `FEATURES=-test` for `dev-python/*`.** *Cause:* pervasive python test-dep cascades
  (pillow/setuptools slot conflicts/pyqt6). *Why ok:* C-extensions are still **compiled** with our
  flags; only `pytest` runs are skipped. Bounded to one ecosystem; not global.
- **E9 — `audit` `FEATURES=-test`** (test-phase failure on musl) — bundled with the libselinux patch.

### Source patch
- **E9 — libselinux musl patch** (`patches/sys-libs/libselinux/0001-musl-no-stat64.patch`).
  *Cause:* `selinux_restorecon.c` uses glibc-only `struct stat64`/`lstat64()` (Makefile `USE_LFS=y`);
  musl has no `*64` API. *Fix:* 2-line `stat64`→`stat`, `lstat64`→`lstat`. *Why ok:* minimal, musl
  portability fix; reportable upstream. Full diff in `config/etc-portage/patches/...` and
  [08-findings.md](08-findings.md).

### Profile mask override
- **E10 — unmask `selinux` USE** (`profile/use.mask = -selinux`). *Cause:* `profiles/base/use.mask`
  masks `selinux`; only SELinux profiles unmask it, so on `musl/llvm` nothing integrates. *Why ok:*
  required to satisfy the SELinux target on a non-selinux profile; nothing weakened.

### no-X11 protection
- **E11 — do not run `@world` under `FEATURES=test`; use command-scoped `-test` for bulk rebuilds.**
  *Cause:* test-deps pull `xorg-server`/`mesa[X]` (via `glib`→`dconf[test]`) + unsatisfiable
  `iptables`/`xorg-server[xvfb]`. *Why ok:* protects the **no-X11** constraint; global `test` stays
  for normal builds.
- **E12 — command-scoped `FEATURES=-test` for the SELinux base-integration rebuild.** Same rationale.

### sandbox & elogind
- **E13 — `sandbox.d` allows `/proc/*/attr/`.** *Cause:* SELinux-aware `cp -a` writes
  `/proc/*/attr/fscreate`; the sandbox denies it → all emerge installs fail once SELinux is active.
  *Fix:* `SANDBOX_WRITE=/proc/self/attr/:/proc/thread-self/attr/`. *Why ok:* a fix, not a weakening.
- **E14 — elogind is a documented BUILD BLOCKER on musl** (`journal-file.h` incomplete `struct stat`).
  *Disposition:* `elogind` kept in global USE (intent preserved) but `-elogind` per-package where it
  would be pulled into a build.
- **E15 — standalone `seatd` for seat/session instead of elogind.** *Cause:* E14. *Fix:* `seatd[server]`,
  `-elogind` on pipewire/wireplumber/seatd/polkit/dbus. *Why ok:* musl-idiomatic; Wayland/PipeWire
  direction intact.

### Full-LTO escalation & extra hardening
- **E1-UPDATE — full `-flto`.** ThinLTO bring-up → full LTO applied via `emerge -e @world` (CFLAG,
  not USE; needs emptytree). 436/441 built; toolchain (clang/llvm 22) rebuilt under full LTO and the
  system boots. See [06-full-lto.md](06-full-lto.md), [08-findings.md](08-findings.md).
- **E16 — extra hardening/optimization flags** (user request, "more painful"): `-O2`→`-O3`, plus
  `-fstack-clash-protection`, `-fcf-protection=full` (CET; endbr64 verified in shipped binaries),
  `-ftrivial-auto-var-init=zero`, `-fzero-call-used-regs=used-gpr`; LDFLAGS `+= -Wl,-z,noexecstack
  -Wl,-z,separate-code -Wl,--icf=safe`. Applied via a second `emerge -e @world`; **435/440 built,
  zero NEW failures** (only the pre-existing net-tools/elogind/obsolete-llvm-21), system boots.
  *(Note: an invalid `FEATURES=stricter` token was briefly added then removed — it is not a real
  Portage FEATURE.)*
- **E17 — net-tools ROSE disabled.** `net-tools-2.10` `#include <linux/rose.h>` (guarded by
  `#if HAVE_AFROSE`, default y) fails because kernel-7.1 UAPI omits `linux/rose.h`. Fix:
  `/etc/portage/bashrc` `post_src_prepare` sets `HAVE_AFROSE/HAVE_HWROSE=n` in config.in →
  rose.c compiles as a stub → net-tools builds (hardening flags applied). ROSE is ham-radio AX.25;
  no loss (iproute2 used). Reportable: ebuild has no toggle for ROSE on kernels lacking the header.

## Never done (prohibited)
musl→glibc · OpenRC→systemd · clang→gcc default · global `-X`/`-pulseaudio`/`-systemd` · global LTO/PIE
off · global `FEATURES=-test` · switch to an easier profile · undocumented masks.
