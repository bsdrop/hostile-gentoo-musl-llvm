# Constraint Exceptions & Documented Deviations — Gentoo musl/LLVM hostile QA

Each entry: what, why, scope (global value preserved?), bug-report relevance.

## E1. LTO spelling: `-flto=auto` -> `-flto=thin` (and full later)
- The briefing make.conf used `-flto=auto`, which is a GCC-specific spelling. The system
  toolchain is clang/LLVM (musl/llvm profile sets CC=clang, LD=ld.lld). clang does not accept
  `-flto=auto`; valid clang spellings are `-flto=thin` and `-flto` (full).
- ThinLTO chosen for initial base bring-up (faster, lower RAM). User explicitly requested
  full LTO eventually -> will escalate global COMMON_FLAGS to `-flto` and rebuild, capturing breakage.
- LTO is NOT disabled. This is a valid-spelling adaptation, explicitly permitted.

## E2. Profile stays musl/llvm; hardened+SELinux layered, NOT via profile
- No `musl/llvm/hardened` or `musl/llvm/selinux` profile exists. Available:
  musl/llvm (46), musl/hardened (48), musl/hardened/selinux (50). The hardened/selinux
  profiles are GCC-based and would drop the LLVM/Clang toolchain target (a HARD constraint).
- Decision: keep profile 46 (musl/llvm) and layer hardening via flags
  (-fstack-protector-strong, -D_FORTIFY_SOURCE=3, relro/now, profile-default pie/cet/seccomp)
  and USE="hardened selinux", plus SELinux userland + kernel support.
- Nothing weakened: LLVM kept (hard constraint), hardening still applied, SELinux still pursued.
- Bug-report relevance: Gentoo lacks a musl+llvm+hardened+selinux composite profile.

## E3. ACCEPT_KEYWORDS="~amd64"
- The musl/llvm profile is marked experimental (exp); many required packages are ~amd64 only.
- Permitted by briefing for this QA target; documented here.

## (pending) package-specific exceptions will be appended below as encountered.

## E4. grub -device-mapper (avoid lvm2[test] REQUIRED_USE conflict)
- Global FEATURES=test auto-forces USE=test on sys-fs/lvm2; its REQUIRED_USE="test? ( lvm )"
  then demands USE=lvm. lvm2 was only pulled transitively by grub[device-mapper].
- This VM uses a plain ext4 root (no LVM/device-mapper), so device-mapper is unneeded.
- Fix: package.use `sys-boot/grub -device-mapper`. Tests remain globally enabled; no target
  constraint weakened (LVM is not a constraint). Minimal and reportable: arguably lvm2 should
  not hard-require `lvm` USE just because `test` is auto-enabled by FEATURES=test.

## E5. FEATURES=-test for dev-tcltk/expect and dev-util/dejagnu (break test-induced cycle)
- Global FEATURES=test auto-enables the `test` USE flag on these test-framework packages,
  producing a circular build dependency: expect (buildtime) -> dejagnu -> expect.
- Portage's own resolver recommends `Change USE: -test` on one of them.
- Fix: package.env disabling FEATURES=test for ONLY these two packages. Global test stays.
- Minimal, reversible, reportable: a stage3/base bootstrap with FEATURES=test cannot resolve
  expect/dejagnu without a per-package test break (relevant Gentoo bug category: test-dep cycles).

## E6. FEATURES=-test for sys-libs/efivar (break test-induced cycle)
- efivar[test] (test USE auto-enabled by FEATURES=test) build-depends on grub, and
  grub runtime-depends on efibootmgr which build-depends on efivar -> circular.
- Resolver recommends `Change USE: -test` on efivar. package.env disables test for efivar only.
- Same QA pattern as E5: FEATURES=test induces bootstrap dep cycles on musl/llvm base.

## E7. FEATURES=-test for SELinux userland cluster (selinux-python, setools, policycoreutils, selinux-base)
- Global FEATURES=test forces `test` USE on sys-apps/selinux-python and app-admin/setools.
  setools is an RDEPEND of selinux-python; setools[test] pulls dev-python/pyqt6[testlib] and a
  large python test tree (cryptography, werkzeug, pip, poetry-core, docutils...) that terminates
  in dev-python/pillow with REQUIRED_USE="test? ( jpeg jpeg2k lcms tiff truetype )" UNSATISFIED.
- Net effect: the SELinux userland is *uninstallable* on this config without disabling tests on
  this cluster (or globally enabling many pillow image-format USE flags + qt6 testlib + ...).
- Fix: package.env FEATURES=-test for the SELinux userland cluster only; global test stays on.
  Also enabled legit `python` USE on libselinux + audit (required bindings, not a weakening).
- Strong reportable QA pattern: FEATURES=test + SELinux userland + musl/llvm = test-dep explosion
  into Qt6/Pillow with an unsatisfiable REQUIRED_USE.

## E8. FEATURES=-test for dev-python/* (python ecosystem only)
- Global FEATURES=test pulls test-DEPENDs across the whole Python ecosystem, repeatedly
  cascading into dev-python/pillow REQUIRED_USE="test?(jpeg jpeg2k lcms tiff truetype)" and
  dev-python/setuptools<80-vs-79 slot conflicts (via pytest/mock/pygments/cryptography/pip/...).
- Decision: disable TEST SUITES for dev-python/* only (package.env). Rationale: this QA targets
  hostile C/C++ clang/LTO/musl builds; python C-extensions are STILL COMPILED with our flags
  (only `pytest` runs are skipped). Global FEATURES=test remains on for all non-python packages.
- NOT a global test disable (prohibited). Bounded to one ecosystem, documented, reportable:
  "FEATURES=test is effectively unusable across dev-python on musl/llvm due to REQUIRED_USE/slot
  cascades terminating in pillow."

## E9. libselinux musl build fix (package patch) + audit test disable
- BLOCKER FOUND: sys-libs/libselinux-3.10-r1 fails to COMPILE on musl: selinux_restorecon.c
  uses `struct stat64` + `lstat64()` (glibc-only LFS names; Makefile forces USE_LFS=y). musl has
  no `*64` API (plain stat/lstat are already 64-bit). clang errors on the implicit decl/incomplete
  type. This is MUSL-specific (would fail on gcc too), NOT caused by clang/LTO.
- Minimal fix: /etc/portage/patches/sys-libs/libselinux/0001-musl-no-stat64.patch replaces
  `struct stat64`->`struct stat` and `lstat64(`->`lstat(` in selinux_restorecon.c (2 lines).
- sys-process/audit-4.1.4-r3 fails its TEST phase (FEATURES=test) -> added to per-package notest.
- Reportable upstream: libselinux should not use stat64/lstat64 on musl (or guard with __GLIBC__);
  candidate Gentoo bug: sys-libs/libselinux musl build failure with USE_LFS.

## E10. Unmask `selinux` USE (profiles/base/use.mask) on the musl/llvm profile
- `selinux` USE is masked by profiles/base/use.mask and only unmasked by SELinux profiles.
- On musl/llvm (non-selinux profile) the mask stays -> coreutils/openrc/pam/etc. build `-selinux`,
  so the SELinux userland is installed but NOTHING gets USE-level SELinux integration, and
  boot-time policy load (openrc[selinux]) is impossible.
- Override: /etc/portage/profile/use.mask = `-selinux` to unmask. Then base packages can be
  rebuilt with selinux. This is required to satisfy the SELinux target on a non-selinux profile.
- Reportable: there is no musl+llvm+selinux profile, and selinux USE is masked off-profile, so a
  musl/llvm hardened+SELinux target requires a manual mask override (profile gap).

## E11. FEATURES=test threatens no-X11 + blocks @world (iptables/dconf cascades)
- `emerge -uDN @world` under global FEATURES=test is unresolvable AND dangerous:
  * net-firewall/iptables[test] REQUIRED_USE="test?(conntrack nftables)" (hard block), and
  * dev-libs/glib[dbus] -> gdbus-codegen -> gnome-base/dconf[test] -> pulls x11-base/xorg-server
    + media-libs/mesa[X] + libepoxy[X]: i.e. FEATURES=test would DRAG IN X11, violating the
    Wayland-only / no-X11 constraint.
- Decision: do NOT run a full `@world` rebuild under these conditions. Instead rebuild only the
  SELinux-integration packages explicitly (bounded), avoiding the test-dep X11 cascade.
- Strong reportable QA result: global FEATURES=test is effectively incompatible with a no-X11
  musl/llvm desktop target because test-deps reintroduce X11 and unsatisfiable REQUIRED_USE.

## E12. One-shot FEATURES=-test for the SELinux base-integration rebuild (NOT global)
- To rebuild base packages (openrc/coreutils/util-linux/pam/shadow/procps/openssh/sysvinit + the
  dbus/elogind/polkit stack) with `selinux` USE for boot-time SELinux integration, FEATURES=test
  pulls the X11 test cascade (E11). Running this SINGLE rebuild command with FEATURES=-test avoids
  pulling X11 and unsatisfiable xorg-server[xvfb].
- This is COMMAND-SCOPED (env on one emerge invocation), not a make.conf global change. Global
  FEATURES still contains `test`. Documented and reproducible.

## E13. sandbox denies /proc/*/attr/fscreate with SELinux-aware coreutils (FIX)
- After rebuilding coreutils with `selinux` USE and loading a policy (even permissive), `cp -a`
  during pkg install writes the SELinux fscreate context to /proc/thread-self/attr/fscreate.
  Gentoo build sandbox DENIES this path -> dev-python/pyproject-metadata (and any cp -a install)
  fails, cascading to glib/dbus/elogind/polkit drops.
- Fix: /etc/sandbox.d/30selinux-attr adds SANDBOX_WRITE for /proc/self/attr/ + /proc/thread-self/attr/.
- Reportable QA: sys-apps/sandbox is not SELinux-fscreate-aware on this musl/llvm+SELinux setup;
  enabling selinux-coreutils breaks emerge installs until the sandbox allows the attr procfs.

## E14. elogind-257.16 fails to compile on musl/clang (BLOCKER, documented)
- sys-auth/elogind-257.16: src/libelogind/sd-journal/journal-file.h:80: "field has incomplete
  type 'struct stat'" -> missing <sys/stat.h> visibility on musl (glibc pulls it transitively;
  clang errors hard). Cascades to drop dbus[elogind], polkit[elogind], dconf.
- elogind on musl is a known-hard port. For the seat/session role on musl/OpenRC the appropriate
  substitute is sys-auth/seatd (not in original USE direction, but elogind does not build).
- Disposition: keep `elogind` in global USE (target intent preserved) but it is a documented
  BUILD BLOCKER on this config. dbus installed without elogind for now (dbus -elogind per-pkg).
- Reportable: sys-auth/elogind sd-journal missing sys/stat.h include on musl; candidate Gentoo bug.

## E15. seatd (standalone) instead of elogind for seat/session (musl)
- elogind is a build blocker on musl (E14) but is pulled via `elogind` USE by pipewire,
  wireplumber, seatd, polkit. Set `-elogind` on those and enable seatd `server` (standalone
  seat daemon). This is the musl-idiomatic seat-management path and keeps PipeWire/Wayland intact.
- Global `elogind` USE remains (target intent); per-package -elogind only where elogind would be
  pulled into the build. Reportable alongside E14.

## E1-UPDATE. Switched to FULL LTO (-flto) per user request
- COMMON_FLAGS now uses `-flto` (full LTO) instead of `-flto=thin`. Applying it requires
  `emerge -e @world` (emptytree) since LTO is a CFLAG, not USE-tracked.
- Full-LTO @world rebuild run with FEATURES=-test (command-scoped, E11/E12) to avoid the
  test-dep X11 cascade. Breakage captured with --keep-going.

## E16. Hardening/optimization escalation (more painful flags) — user request
- After the full-LTO base, escalated COMMON_FLAGS: -O2->-O3, plus -fstack-clash-protection,
  -fcf-protection=full (CET IBT+shadow stack; verified endbr64 emitted), -ftrivial-auto-var-init=zero,
  -fzero-call-used-regs=used-gpr. LDFLAGS += -Wl,-z,noexecstack -Wl,-z,separate-code -Wl,--icf=safe.
  All validated to compile+run on musl/clang21->22 + LTO before bulk rebuild.
- Applied via `emerge -e @world` (CFLAG change needs emptytree). Command-scoped FEATURES=-test to
  avoid the X11 test cascade (E11); global make.conf FEATURES keeps test. --keep-going.

## E17. net-tools ROSE disabled (kernel-7.1 UAPI lacks linux/rose.h) — FIXED
- sys-apps/net-tools-2.10 lib/rose.c does `#include <linux/rose.h>` inside `#if HAVE_AFROSE`,
  and config.in defaults HAVE_AFROSE/HAVE_HWROSE to 'y'. kernel-7.1 UAPI does NOT ship
  linux/rose.h (only ax25.h) -> compile fails. (musl-independent; a net-tools vs kernel gap.)
- Fix: /etc/portage/bashrc post_src_prepare hook sets HAVE_AFROSE/HAVE_HWROSE to 'n' in config.in
  for sys-apps/net-tools, so rose.c compiles as a stub. net-tools then builds fully (with the
  hardening flags; CET endbr verified in netstat). ROSE is ham-radio AX.25 — no functional loss;
  iproute2 is the actual networking tool.
- Reportable: net-tools-2.10 unconditionally needs linux/rose.h which newer kernels omit; ebuild
  has no USE/toggle to disable ROSE.

## E18. Hyprland: XWayland off (-X); libXcursor X11 client libs unavoidable
- Hyprland from the third-party `hyproverlay` (not in ::gentoo/GURU). Built with global USE `-X`,
  so the `X` USE (XWayland) is OFF -> no x11-base/xwayland, no xorg-server. Pure Wayland.
- Hyprland *unconditionally* RDEPENDs x11-libs/libXcursor (cursor themes), which pulls libX11/
  libXrender/libXfixes (X11 CLIENT libraries only — no X server, no XWayland). This is the briefing's
  allowed "X11 only where a specific dep forces it" case. Documented, not a global X11 enable.
- Built with FEATURES=-test (command-scoped, E11) to avoid the libepoxy/libglvnd[test,X]->xorg-server
  test cascade. ~70 pkgs under -O3+CET+full-LTO+hardening.

## E14-UPDATE. elogind on musl: 2 blockers (struct stat include FIXED; gshadow.h HARD)
- (1) src/libelogind/sd-journal/journal-file.h used `struct stat` without <sys/stat.h> -> fixed by
  /etc/portage/patches/sys-auth/elogind/0001-musl-sys-stat.patch (musl needs the explicit include).
- (2) Next: src/shared/user-record-nss.h includes <gshadow.h> -> musl provides NO gshadow API
  (glibc-only: struct sgrp, getsgnam, etc.). Not a missing-include; the functionality is absent on
  musl. Requires invasive source surgery to #ifdef-out gshadow usage. => elogind remains a HARD
  musl build blocker. Consequence: mutter[wayland] REQUIRED_USE wayland?(exactly-one-of(elogind
  systemd)) cannot be satisfied on musl (systemd prohibited) -> GNOME-on-Wayland is blocked.

## E19 / FINDING: GNOME is BLOCKED on this config (documented failure, not pursued)
- GNOME 49 stack (gnome-shell/gdm/gnome-session/gnome-control-center/settings-daemon) hard-requires:
  (a) **elogind** across the whole session stack (gdm, gnome-session, accountsservice, dbus,
      pambase, networkmanager, udisks, libei...) -> elogind is UNBUILDABLE on musl (E14: gshadow.h).
      systemd is prohibited. So the logind requirement cannot be met. PRIMARY BLOCKER.
  (b) **X11**: gtk4[X], gtk+3[X], mesa[X], cairo[X], libepoxy[X], libxkbcommon[X], vulkan-loader[X]
      -> would violate the no-X11 constraint (and not just XWayland — full X client/server stack).
  (c) **PulseAudio**: media-sound/pulseaudio-daemon + libcanberra[pulseaudio] + alsa-plugins[pulseaudio]
      -> would violate the PipeWire-not-PulseAudio constraint.
  Plus dev-cpp/abseil-cpp slot conflict and media-libs/harfbuzz[icu] keyword mask.
- The user's "-X vs XWayland" comparison is moot: the blocker is logind/PulseAudio, independent of the
  display protocol. Mutter alone can build X-only (xwayland force overridden), but the GNOME session
  cannot exist without elogind.
- Decision: NOT pursued — making GNOME build would require abandoning three hard constraints
  (no-X11, no-PulseAudio, no-systemd/elogind-musl). Recorded as a high-value failure artifact.

## E20 / FINDING: Firefox (Firefox-family browser) — feasible on Wayland, but pulls gcc+nodejs
- www-client/firefox-152.0 resolves cleanly under our constraints: USE="wayland -X -pulseaudio
  hardened (clang) selinux", gtk+3[wayland -X]. No X server, no PulseAudio. Uses LLVM slot 21
  (both clang:21 and clang:22 are installed). Good Firefox-family target.
- BUT its BDEPEND tree pulls sys-devel/gcc-16 (via net-libs/nodejs and/or dev-lang/rust) onto the
  otherwise clang-only system (soft-blocks llvm-runtimes/libgcc). gcc gets INSTALLED but the default
  CC/CXX remain clang/clang++ (no global toolchain switch) -> permitted, documented. ~multi-hour
  build (gcc+nodejs+rust+ffmpeg+gtk3+firefox 779MB src); full-LTO link is RAM-heavy (OOM risk @16G).
- Mullvad Browser / Tor Browser are distributed as glibc binaries (bin packages) -> will NOT run on
  musl; firefox-from-source is the representative Firefox-family build here.

## E16-FIX: removed -Wl,--icf=safe from global LDFLAGS (lld-only; breaks GNU-ld builds)
- The E16 hardening escalation added -Wl,--icf=safe to LDFLAGS. `--icf` is an lld/gold-only option;
  GNU ld (binutils) rejects it ("unrecognized option '--icf=safe'"). sys-devel/gcc-16 bootstrap links
  libgcc_s.so with GNU ld (gcc's internal collect2 uses binutils ld, not the system LD=ld.lld), so gcc
  FAILED -> dropped nodejs -> dropped firefox. FINDING: an lld-only flag in global LDFLAGS breaks any
  package that links via GNU ld (notably the gcc bootstrap). Fix: drop --icf=safe globally (kept
  -z,noexecstack/-z,separate-code which both linkers accept). Prior snapshots built fine because all
  other pkgs used lld; only gcc uses GNU ld internally.

## E20-FINDING: firefox fails on musl — static rust-bin can't dlopen libclang (bindgen)
- firefox-152.0 builds gcc-16/nodejs/rust-bin/l10n + configures (libclang found), but `mach build`
  dies in a rust build-script: bindgen panics at lib.rs:615 "Unable to find libclang: ...
  libclang.so.21.1.8 could not be opened: **Dynamic loading not supported**".
- Root cause: the toolchain pulled `dev-lang/rust-bin` which is a **statically-linked musl** rustc;
  static musl binaries cannot `dlopen()`. bindgen dlopens libclang at runtime -> fails. Classic
  musl + static-rust + bindgen gotcha. Affects ANY bindgen-using package built with static rust-bin.
- FIX (deferred): build dev-lang/rust from SOURCE (dynamically linked rustc) so dlopen works; that
  also unblocks the rust backlog (niri/cosmic/etc.) and other bindgen consumers. ~1.5-3h build.
- Status: firefox deferred until source rust is built (P1 foundation). Not a constraint weakening.

## E20-FINDING (cont.): firefox musl path = dynamic rust MATCHED to firefox's LLVM slot (21)
- After making dev-lang/rust (source, dynamic) the active rust, firefox STILL failed bindgen dlopen,
  because firefox pins rust to its LLVM slot: firefox-152 wants LLVM_SLOT=21, but the source rust we
  built is LLVM_SLOT=22 -> firefox falls back to a static rust / wants rust@21. Removing rust-bin made
  emerge schedule dev-lang/rust-1.94.1[LLVM_SLOT=21] (a ~1h source build) before firefox.
- So a working firefox-on-musl needs: dev-lang/rust (SOURCE, dynamic) built against the SAME LLVM slot
  firefox selects (21). Path is clear but ~3-4h (rust@21 + firefox). DEFERRED (browsers = "나중에";
  KDE is the decided priority). Will resume firefox after KDE/enforcing.

## E14-COROLLARY: global -elogind (elogind unbuildable on musl; was in briefing USE)
- The briefing USE included `elogind`. But sys-auth/elogind does not build on musl (E14: gshadow.h).
  Keeping `elogind` in global USE makes every package with an elogind USE flag (huge across KDE:
  polkit/accountsservice/udisks/networkmanager/switcheroo/libei/...) try to pull the unbuildable
  elogind. So switched global USE to `-elogind`; seatd provides seat management. Documented deviation
  forced by the musl elogind blocker. (Per-package -elogind was used earlier; now global for the KDE tree.)

## E22 / FINDING: KDE Plasma BLOCKED on musl (logind wall, same root as GNOME)
- Attempted full Plasma (kde-plasma/plasma-desktop) with X enabled for the KDE/Qt stack (decision A).
- Resolved 277 pkgs after many fixes: enable qt6 + X across dev-qt/kde, qtbase[X,icu,opengl,cups,libproxy],
  xerces-c[icu] (musl REQUIRED_USE elibc_musl?(icu)), libxkbcommon/mesa/libepoxy/libglvnd[X], -test
  (else libglvnd[test,X] pulls xorg-server[xvfb]); -policykit on plasma-workspace dropped accountsservice
  (which needs ^^(elogind systemd)).
- HARD BLOCKER: kde-plasma/plasma-workspace UNCONDITIONALLY deps kde-frameworks/networkmanager-qt,
  which hard-deps net-misc/networkmanager[elogind]; elogind is unbuildable on musl (E14), systemd
  prohibited. No USE flag drops networkmanager-qt from plasma-workspace -> KDE core cannot build.
- Same fundamental logind entanglement as GNOME (E19), reached via a deeper chain. NOTE (better than
  GNOME on one axis): with -test, KDE needs only X CLIENT libs + XWayland, NOT a full xorg-server.
- To unblock BOTH GNOME and KDE one would need a working musl elogind (port around gshadow) or systemd.
- Global config from the attempt kept: `-elogind` (elogind unbuildable anyway), `*/* qt6`, KDE/Qt X flags
  (inert unless KDE/qt installed). Documented.
