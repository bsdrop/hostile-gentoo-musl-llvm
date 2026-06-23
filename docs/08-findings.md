# 08 · Findings

Concrete, reproducible breakage in the Gentoo ecosystem under the musl/LLVM/SELinux/Wayland/test
combination. Logs referenced here are under `artifacts/checkpoints/` and, in the guest,
`/var/log/portage/`. A human must reproduce any of these independently before any upstream use; see
the README.

## F1 — libselinux does not build on musl (`USE_LFS=y` uses the glibc-only `stat64`)

- Package: `sys-libs/libselinux-3.10-r1`. Phase: compile.
- Error: `selinux_restorecon.c:446: variable has incomplete type 'struct stat64'` and
  `:460: call to undeclared function 'lstat64'`.
- Cause: the Makefile passes `USE_LFS=y`, and the source uses `struct stat64` and `lstat64()`, which
  musl does not provide; its `stat` and `lstat` are already 64-bit. clang treats the implicit
  declaration as an error.
- This is specific to musl, not the toolchain: it would also fail under GCC.
- Fix: use `stat`/`lstat` on musl, or guard the `*64` names with `__GLIBC__`. Patch in
  `config/etc-portage/patches/sys-libs/libselinux/0001-musl-no-stat64.patch`.
- Impact: blocks the entire SELinux userland on musl until patched. This is the most significant
  finding.

## F2 — `FEATURES=test` reintroduces X11 on a no-X11 target

- Symptom: `emerge -uDN @world` and even targeted base rebuilds pull `x11-base/xorg-server`,
  `media-libs/mesa[X]`, and `libepoxy[X]`, then fail on `xorg-server[xvfb]`.
- Chain: `dev-libs/glib[dbus]` → `gdbus-codegen` → `gnome-base/dconf[test]` → X stack. Also
  `net-firewall/iptables[test]` with `REQUIRED_USE="test? ( conntrack nftables )"`.
- Cause: global `FEATURES=test` enables the `test` USE flag on GUI and D-Bus libraries, whose test
  dependencies require X. `FEATURES=test` is therefore incompatible with a Wayland-only, no-X11
  musl/llvm desktop target. Mitigated by command-scoped `FEATURES=-test` on bulk rebuilds.

## F3 — enabling SELinux-aware coreutils breaks the build sandbox

- Symptom: after `coreutils[selinux]`, every package install fails; the log shows
  `F: open_wr / S: deny / P: /proc/thread-self/attr/fscreate` during `cp -a`.
- Cause: SELinux-aware `cp -a` writes the fscreate context to `/proc/*/attr/fscreate`, which Gentoo's
  build sandbox denies.
- Fix: `sys-apps/sandbox` should allow `/proc/*/attr/` when SELinux is active; here `SANDBOX_WRITE` is
  added manually. Impact: all emerges fail once SELinux is active until this is set.

## F4 — elogind does not build on musl

- Package: `sys-auth/elogind-257.16`. Error: `sd-journal/journal-file.h:80: field has incomplete type
  'struct stat'` (no `<sys/stat.h>` visibility on musl). A later blocker is `<gshadow.h>`, whose API
  musl does not provide at all (see E14).
- Workaround: none applied; standalone `seatd` is used instead.

## F5 — `FEATURES=test` REQUIRED_USE and cycle cluster

A group of test-induced resolution failures, each small on its own but together the dominant friction:

- `lvm2[test]` `REQUIRED_USE="test? ( lvm )"` (pulled by `grub[device-mapper]`).
- `expect` ↔ `dejagnu` circular build dependency; `efivar` → `grub` → `efibootmgr` cycle.
- `setools` and `selinux-python` test dependencies → `pyqt6[testlib]` and a Python tree →
  `pillow` `REQUIRED_USE="test? ( jpeg jpeg2k lcms tiff truetype )"` (unsatisfiable); `setuptools` slot
  conflict.
- `app-misc/pax-utils[test]` `REQUIRED_USE="test? ( python )"` (in `@system`, blocks `@world`).
- On a fresh musl/llvm base, `FEATURES=test` cannot resolve `@system` or `@world` without many
  per-package test exceptions; several REQUIRED_USE constraints make `test` a hard blocker rather than
  a soft one.

## F6 — profile gap: no musl+llvm+hardened+selinux profile; `selinux` USE masked off-profile

There is no composite profile for the target, and `selinux` is masked by `profiles/base/use.mask`
unless on a SELinux profile, so a musl/llvm SELinux target needs a manual `use.mask` override.

## F7 — full LTO plus aggressive hardening rebuild: clean

Two full `emerge -e @world` passes (about 440 packages each) under (1) full `-flto`, then (2) full LTO
plus `-O3`, CET (`-fcf-protection=full`), `-fstack-clash-protection`, `-ftrivial-auto-var-init=zero`,
and `-fzero-call-used-regs=used-gpr`. Both boot. The toolchain itself (clang/llvm 22) rebuilds under
full LTO. The only failures were the three already-known ones below; the aggressive flags introduced
no new breakage.

- `llvm-core/llvm-21.1.8`: obsolete, superseded by 22.1.8, which built. The `-e` attempt to rebuild the
  old 21 source fails on a libc++-22 `static_assert` (`make_transparent`/`std::less<void>` in
  `HexagonRDFOpt.cpp`), a version skew, not LTO or OOM. 22 is installed and consistent.
- `sys-apps/net-tools-2.10`: `linux/rose.h` (see F8, E17), now fixed.
- `sys-auth/elogind-257.16`: musl build blocker (F4, E14), replaced by seatd.

## F8 — net-tools needs linux/rose.h, which the kernel 7.1 UAPI omits (fixed via E17)

`net-tools-2.10` `lib/rose.c` includes `<linux/rose.h>` under `#if HAVE_AFROSE` (config default on),
but kernel 7.1 ships no `linux/rose.h` (only `ax25.h`). Not a musl issue. Fixed by disabling ROSE in
`config.in` (`/etc/portage/bashrc` hook). net-tools has no USE flag or toggle for ROSE.

## F9 — desktops blocked on musl by the logind requirement (GNOME and KDE)

Modern full desktops require a logind provider (elogind or systemd). On musl, elogind is unbuildable
(F4, E14: gshadow.h) and systemd is prohibited, so:

- GNOME (E19): `mutter[wayland]` requires `^^ ( elogind systemd )`; the stack also forces X11 and
  PulseAudio.
- KDE Plasma (E22): `plasma-workspace` unconditionally depends on `networkmanager-qt` →
  `networkmanager[elogind]`, and `accountsservice` requires `^^ ( elogind systemd )`. The build
  resolves 277 packages otherwise (qt6 + X stack), but the logind dependency cannot be removed with USE
  flags. With `FEATURES=-test`, KDE needs only X client libraries and XWayland, not a full xorg-server
  (the xorg-server pull was a `libglvnd[test,X]` → xvfb test artifact). wlroots compositors (Hyprland,
  sway) avoid this because they use seatd, not logind.

### If GNOME or KDE is required

The blocker is the logind requirement (`org.freedesktop.login1`). seatd provides seats, not the
login1 D-Bus API, so it does not satisfy GNOME or KDE. Options, least disruptive first:

1. Use glibc instead of musl (keep OpenRC, clang/LTO, hardened, SELinux, Wayland, PipeWire). On glibc,
   `sys-auth/elogind` builds, so GNOME and KDE work with OpenRC and elogind. musl is the actual
   blocker, not OpenRC. This is the most effective option if GNOME or KDE is required, and is the basis
   for the second image.
2. Use systemd instead of OpenRC, which provides systemd-logind. But systemd also does not build on
   musl, so this means glibc as well, which makes it strictly worse than option 1 for this stack.
3. Keep musl and OpenRC and change the desktop. There is no drop-in logind that GNOME or KDE accept on
   musl, so use a wlroots compositor (Hyprland, sway, labwc, wayfire, niri); all use seatd and run on
   musl/OpenRC. Hyprland and sway are confirmed here.

Do not force elogind to compile by stubbing `gshadow`: that produces an elogind that links but whose
account and session lookups misbehave. On musl without systemd, the correct answers are option 1 or
option 3.

## F10 — Firefox on musl: static rust-bin cannot dlopen libclang; fixed with dynamic rust

Initial symptom: Firefox's `mach build` fails with bindgen reporting `Unable to find libclang ...
Dynamic loading not supported`. The toolchain's `rust-bin` is statically linked (musl), and static
musl binaries cannot `dlopen()`, which bindgen needs to load libclang.

Resolution: Firefox builds and runs on musl with a dynamically-linked source rust whose `LLVM_SLOT`
matches the one Firefox uses. firefox-152 defaults to `LLVM_SLOT=21`, but it also supports
`LLVM_SLOT=22`; setting `www-client/firefox LLVM_SLOT: -21 22` lets it use the already-installed
`dev-lang/rust-1.95.0` (slot 22, source, dynamic). That collapses the build to one package (no rust
rebuild), and the dynamic rustc can `dlopen` libclang. Result: `firefox-152.0` built (EXIT_RC=0),
`firefox --version` works, and `firefox --headless --screenshot` renders a PNG; `ldd` confirms the
binary is musl-linked.

Note (hardening interaction): under SELinux enforcing with root mapped to the confined `sysadm_t`
domain, Firefox logs `Sandbox: CanCreateUserNamespace() clone() failure: EACCES`. The kernel allows
user namespaces (`CONFIG_USER_NS=y`, `user.max_user_namespaces` non-zero); the denial is SELinux
refusing `user_namespace { create }` to the confined domain (dontaudit'd, so no AVC is logged). The
warning is absent in permissive. Firefox still runs; only the namespace layer of its content sandbox
is degraded. A local policy rule granting `user_namespace create` would restore it. See E20.

## F11 — `-Wl,--icf=safe` (lld-only) breaks the GCC bootstrap

The E16 hardening LDFLAGS added `--icf=safe`. GCC's libgcc links with GNU ld, not lld, and GNU ld
rejects the flag, so gcc-16 fails and the dependents cascade. lld-only flags in global LDFLAGS break
any GNU-ld build. Removed.

## F12 — full-LTO KCFI hardened kernel: builds and boots

A clang-built kernel with KCFI (`CONFIG_CFI`, renamed from `CONFIG_CFI_CLANG` in kernel 7.1),
`LTO_CLANG`, `lockdown=confidentiality`, and all CPU side-channel mitigations boots and runs (dmesg:
`CFI: Using rehashed retpoline kCFI`). The gcc-plugin STACKLEAK and RANDSTRUCT features are not
available under clang; KCFI and LTO are used instead.

## F13 — hardening is not a complete security story: mitigation is not patch management

This project optimizes one axis of security: exploit mitigation (PIE/SSP/`FORTIFY_SOURCE=3`,
RELRO/BIND_NOW, CET, full LTO, a KCFI+LTO clang kernel, lockdown, KSPP sysctl, SELinux enforcing). That
reduces the impact of a bug. It does not address the other axis: how quickly known-vulnerable code gets
patched. A hardened system that is never updated is not more secure than an updated stock system; the
two axes are independent and both are required.

Gentoo has a patch-management mechanism, but it is manual and easy to skip on a hand-built system:

- Advisories: GLSA (Gentoo Linux Security Advisories), the security-advisory feed.
- Which security updates apply: `glsa-check -t all` (from `app-portage/gentoolkit`).
- Apply fixes: `glsa-check -f affected`, or keep `@world` current with `emerge -uDU @world`.

Verified on the VM: `glsa-check` is present, the repo ships 3821 historical GLSAs under
`metadata/glsa/`, and a freshly-synced system reports `glsa-check -t affected` → "not affected by any
of the listed GLSAs." That result is partly an artifact: many Gentoo fixes ship as plain version bumps
with no GLSA, so `glsa-check` under-reports, and "0 affected GLSAs" is not "0 known vulnerabilities."
The real coverage comes from updating `@world`, not from the advisory list.

The corresponding strength: rolling source means upstream fixes arrive without backport lag, if you
sync and rebuild. The cost is that you are the integrator, with no SLA and no security-only update
stream.

Practical posture: run `emerge --sync && glsa-check -t all` on a schedule, apply `emerge -uDUv @world`
on a real cadence, follow the GLSA feed, and track with `gentoolkit` and `eix`. `config/security-sweep.sh`
wraps the sync and GLSA report. Report hardening as mitigation, not as a substitute for patching.

## Status

Both images snapshot before each stage so a failed stage is recoverable.

musl image (complete):

- Full-LTO `@world` and the extra-hardening pass both build and boot (F7).
- Hyprland and sway build and run.
- Wayland, PipeWire, and seatd installed with no X11 and no PulseAudio.
- SELinux is enforcing with `root` mapped to `sysadm_t`.
- The KCFI/LTO clang kernel builds and boots (F12).
- GNOME and KDE are blocked by the logind requirement (F9); not pursued on musl.
- Firefox builds and runs (`firefox-152.0`, headless render verified) using a dynamic source rust at
  a matching LLVM slot (F10); under enforcing its content sandbox loses the user-namespace layer.

glibc image: the same hardened/LLVM/OpenRC/SELinux setup without musl, used to reach the
GNOME desktop and browsers that the musl logind requirement blocks.
