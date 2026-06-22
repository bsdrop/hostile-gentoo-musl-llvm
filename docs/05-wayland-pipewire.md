# 05 · Wayland / PipeWire — no X11, no PulseAudio, seatd not elogind

> **Context:** How the display/audio direction was satisfied while keeping X11 and PulseAudio out.
> Standalone; touches the elogind blocker (full detail in [07-exceptions.md](07-exceptions.md) E14/E15).

## What got installed
`media-video/pipewire`, `media-video/wireplumber`, `dev-libs/wayland`, `dev-libs/wayland-protocols`,
`sys-auth/seatd`, `media-libs/mesa`, `sys-apps/dbus`, plus `selinux-wayland`/`selinux-seatd` policy
modules. All built on musl/clang/LTO. `dbus` + `seatd` are enabled as OpenRC services.

## No X11 (verified)
`mesa` is built `USE="-X wayland vaapi vulkan"`; **no `x11-base/xorg-server`** is installed.
`VIDEO_CARDS="virtio virgl"` targets QEMU's virtio-gpu. The only catch was indirect: under
`FEATURES=test`, GUI libraries' test-deps pull xorg-server/mesa[X] (see [04-selinux.md](04-selinux.md)
E11), so this stack is installed with command-scoped `FEATURES=-test`. Global `test` stays on.

## No PulseAudio (verified)
`pipewire` is built `-pulseaudio`; **no `media-sound/pulseaudio`** installed. PipeWire is the
intended audio server. (`sound-server`/`pipewire-alsa` USE can be enabled to make it the active ALSA
backend; left off for the minimal "prove the direction" install.)

## Why seatd instead of elogind
The brief's USE direction lists `elogind`, but **`elogind-257.16` fails to compile on musl** (E14):
`src/libelogind/sd-journal/journal-file.h` references an incomplete `struct stat` (musl needs an
explicit `<sys/stat.h>`; glibc pulls it in transitively, and clang errors hard). elogind on musl is
a known-hard port.

The musl-idiomatic seat/session manager is **standalone `seatd`** (`sys-auth/seatd` with `server`,
`-elogind`). So `-elogind` is set on `pipewire`, `wireplumber`, `seatd`, `polkit`, `dbus`, and seatd
runs as the seat daemon. `elogind` stays in *global* USE (target intent preserved); it's only
disabled where it would otherwise be pulled into a build that can't succeed.

## Next: compositors + session stack + desktop + browsers (the "B" goals)
On the hardened full-LTO base, in order (snapshotting between stages), **XWayland off (`-X`)** for the
Wayland-native stages:
1. **Hyprland** (via third-party `hyproverlay`) — heavy C++ Wayland stack; combined full-LTO + musl
   + clang torture test.
2. **wlroots + sway** — the reference wlroots compositor, also `-X`.
3. **Wayland session/portal stack** — `pipewire` (have) + `seatd` (have) + `xdg-desktop-portal-wlr`.
4. **SELinux → enforcing** — switch from permissive after reviewing AVC denials.
5. **GNOME** — stretch goal (fails even on Arch per the user), **plus a comparison**: everything is
   `-X` so far; also test GNOME with `+X`/**XWayland enabled** to see whether X11/XWayland actually
   works better than pure Wayland here.
6. **Browsers**, ≥1 running per family under Wayland:
   - Firefox family: **Mullvad Browser** / **Tor Browser** / **LibreWolf**
   - Chromium family: **Trivalent** / **Cromite** / **Brave**

Status + results tracked in [08-findings.md](08-findings.md).
