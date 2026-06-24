# Hostile Gentoo — musl · LLVM/Clang · OpenRC · SELinux · Wayland · PipeWire · LTO

A Gentoo install that combines options which are each supported on their own but rarely used
together: musl instead of glibc, the LLVM/Clang toolchain instead of GCC, OpenRC, hardened toolchain
flags, SELinux, Wayland without X11, PipeWire without PulseAudio, and full LTO.

This repository documents what breaks when these options are combined, and how each break was fixed
or worked around. It is a reference for anyone considering some or all of these options. It is not a
configuration to copy onto a real machine.

Every install step runs inside a disposable QEMU/KVM guest, never on the host
(see [docs/01-environment.md](docs/01-environment.md)).

---

## Read this before you do anything stupid with it

This repository is written entirely by an AI assistant. No human edited the content for correctness.
Treat every statement as unverified until you reproduce it yourself.

**Do not contribute any part of this to Gentoo.** Gentoo prohibits contributing content produced with
AI/NLP tools, and the rule is broad. It covers:

- code and packaging — ebuilds, eclasses, patches, commits, metadata;
- bug reports and every comment on them; pull/merge requests and their reviews;
- prose — wiki edits, documentation, news items, GLEPs, mailing-list and forum posts;
- summaries — a findings report, a reproducer write-up, or a posted diff is still AI content.

This repository's `docs/08-findings.md`, `artifacts/constraint-exceptions.md`, and any
`final-report.md` are exactly the kind of material the policy forbids. An informal comment in an
unofficial space (for example r/Gentoo) is not the official contribution path, but using it to get a
finding triaged or routed to a maintainer is. When unsure, treat anything aimed at Gentoo as covered.

If a finding here looks like a real bug (for example `libselinux`'s `stat64` use on musl), a human
must reproduce it independently on a supported setup, understand it, and write it up from scratch with
no reference to this text, then file that.

---

## Contents

- The full configuration — `make.conf`, USE flags, `FEATURES`, kernel config, and the reason for
  each choice; the clang/LLVM/lld toolchain bring-up; a step-by-step install.
- The breakage found when these options are combined ([docs/08-findings.md](docs/08-findings.md)):
  `libselinux` using the glibc-only `stat64` on musl; `FEATURES=test` pulling X11 onto a no-X11
  system; the logind requirement that blocks GNOME and KDE on musl; Firefox needing a dynamic source
  rust to `dlopen` libclang on musl (a static rust binary cannot); and a full-LTO clang kernel with
  KCFI that builds and boots.
- SELinux on a source-based, OpenRC, non-systemd system: enabling it, labeling the filesystem, and
  reaching enforcing mode with `root` confined to `sysadm_t` ([docs/04-selinux.md](docs/04-selinux.md)).
- Wayland without X11 and PipeWire without PulseAudio, using seatd
  ([docs/05-wayland-pipewire.md](docs/05-wayland-pipewire.md)).
- Hardening: full LTO, PIE, CET, a KCFI/LTO clang kernel, and KSPP sysctl settings. The findings also
  state the limit of this: hardening reduces the impact of a bug, but does not replace keeping
  packages updated ([docs/08-findings.md](docs/08-findings.md)).
- A second image on glibc: the same hardened/LLVM/OpenRC/SELinux setup without musl, used to reach the
  GNOME desktop and browsers that the musl logind requirement blocks.

Every deviation from the target configuration is recorded with its cause in
[docs/07-exceptions.md](docs/07-exceptions.md).

---

## Repo layout

| Path | Contents |
|------|----------|
| [`docs/`](docs/) | Documentation. Each file can be read on its own. |
| [`scripts/`](scripts/) | Operational scripts: install, VM launchers, ssh/serial helpers. |
| [`config/`](config/) | Config artifacts: `make.conf`, kernel fragment, `etc-portage/` overrides. |
| [`artifacts/`](artifacts/) | Raw run record: `commands.log`, `constraint-exceptions.md`, per-step emerge logs, checkpoints. |

The live runtime (the running VM, its qcow2 disk and snapshots, and sockets) is not in the repository.

## Document index

1. [docs/00-overview.md](docs/00-overview.md) — what the project is, the target options, and the result.
2. [docs/01-environment.md](docs/01-environment.md) — why the install runs in a QEMU guest, and how to reach and control the VM.
3. [docs/02-configuration.md](docs/02-configuration.md) — `make.conf`, USE, `FEATURES`, and kernel config, with the reason for each.
4. [docs/03-install-walkthrough.md](docs/03-install-walkthrough.md) — the install, step by step.
5. [docs/04-selinux.md](docs/04-selinux.md) — enabling SELinux, labeling the filesystem, and reaching enforcing mode.
6. [docs/05-wayland-pipewire.md](docs/05-wayland-pipewire.md) — Wayland without X11, PipeWire without PulseAudio, seatd.
7. [docs/06-full-lto.md](docs/06-full-lto.md) — moving to full LTO and rebuilding `@world`.
8. [docs/07-exceptions.md](docs/07-exceptions.md) — E1–E22: each deviation from the target, with cause and fix.
9. [docs/08-findings.md](docs/08-findings.md) — the breakage found, with cause. A human must reproduce before any upstream use.
10. [docs/09-reproduce.md](docs/09-reproduce.md) — how to reproduce the build from scratch.
11. [docs/10-final-report-musl.md](docs/10-final-report-musl.md) — final report for the musl image.

Code-only appendices: [docs/musl-code.md](docs/musl-code.md) (musl config: make.conf, USE, kernel,
patches) and [docs/glibc-code.md](docs/glibc-code.md) (glibc desktop config: the GNOME/KDE/browser
package.use sets).

## Status

**musl image (first):** boots with musl, clang/LLD, and OpenRC; SSH works; SELinux is enforcing with
`root` mapped to `sysadm_t`; Wayland and PipeWire with no X11 and no PulseAudio; PIE/SSP/FORTIFY/RELRO
and full LTO; a KCFI/LTO clang kernel; no systemd and no gcc. Hyprland and sway build and run. Firefox
builds and runs (using a dynamic source rust at a matching LLVM slot). GNOME and KDE do not build on
musl (logind requirement).

**glibc image (second):** the same hardened/LLVM/OpenRC/SELinux setup without musl. It runs the GNOME
desktop (interactively, in a QEMU GTK window — wallpaper, Settings, and a GNOME Shell extension all
work), Firefox, and Chromium, builds KDE Plasma, boots SELinux enforcing with root confined to
`sysadm_t`, and the AMD GPU driver stack (mesa radeonsi, RADV Vulkan, `xf86-video-amdgpu`) builds (it
is not run, since the guest has only virtio-gpu). See [docs/08-findings.md](docs/08-findings.md) F15 for
the display setup.

## What worked / what failed

Worked, on both images: the full hardened toolchain (full LTO, `-O3`, CET, stack-clash,
auto-var-init, zero-call-regs, FORTIFY=3, RELRO/BIND_NOW); a clang **KCFI + LTO** kernel; **SELinux
enforcing** with root confined to `sysadm_t`; OpenRC with no systemd; Wayland/PipeWire/seatd with no
X11 and no PulseAudio. The clang/LLVM/lld toolchain rebuilt itself under full LTO.

Worked, musl only: four wlroots compositors (Hyprland, sway, river, wayfire); Firefox (with a dynamic
source rust at a matching LLVM slot); mpv, GStreamer, Lua, LuaJIT, yt-dlp, zig, nim, and crystal all
build and run.

Worked, glibc only: GNOME (runs headless), Firefox and Chromium (render headless), KDE Plasma (builds;
`kwin_wayland` starts as a compositor), and the AMD GPU driver stack (builds).

Failed or blocked:

- **GNOME and KDE on musl** — both require logind, and elogind does not build on musl (`gshadow.h`)
  while systemd is prohibited. Both build on glibc, which isolates logind as the only cause.
- **`FEATURES=test`** — the dominant friction throughout: it reintroduces X11 on a no-X11 target and
  produces unsatisfiable `REQUIRED_USE`/cycles. Kept global; handled with narrow per-package exceptions.
- **`-Wl,--icf=safe`** (lld-only) broke the gcc bootstrap (gcc links libgcc with GNU ld); removed.
- **net-tools** failed on a missing kernel UAPI header (`linux/rose.h`); fixed by disabling ROSE.
- **Firefox under enforcing** — SELinux denies its content sandbox's user-namespace layer (degraded,
  not a failure). **kwin headless rendering** fails in QEMU (no working KMS for its virtual backend);
  an environment limit, not a build failure.

Full detail in [docs/08-findings.md](docs/08-findings.md) and [docs/07-exceptions.md](docs/07-exceptions.md).

The largest single source of breakage in both images is global `FEATURES=test`; see
[docs/08-findings.md](docs/08-findings.md).
