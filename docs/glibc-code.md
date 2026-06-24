# glibc image — desktop config (code only)

The second image keeps the hardened/LLVM/OpenRC/SELinux stack and drops only musl
(glibc + GCC stage3, profile `default/linux/amd64/23.0/hardened/selinux`). elogind
builds on glibc, so GNOME, KDE, Firefox, and Chromium all work here — the desktops
and browsers blocked on musl by the logind requirement (see
[07-exceptions.md](07-exceptions.md) E19/E22 and [08-findings.md](08-findings.md) F9/F10).

`make.conf` is the same hardened set as the musl image ([../config/make.conf](../config/make.conf))
with the glibc CHOST and one addition: `LDFLAGS` includes **`-fuse-ld=lld`**. The glibc hardened
profile makes clang default to GNU `ld`, which cannot link LTO bitcode (`file format not recognized`);
forcing lld fixes it. What follows are the per-package USE overrides specific to reaching the desktops
and browsers; the global make.conf hardening is unchanged.

## /etc/portage/package.use/qa-gnome

```
*/* gnome
dev-qt/qtbase:6 X
x11-wm/mutter udev
media-libs/libglvnd X
# GNOME forces X11/XWayland across its stack (documented exception, Wayland-only target)
x11-libs/cairo X
# printing stack (cups->system-config-printer->samba->ngtcp2) not needed for a bring-up
gnome-base/gnome-control-center -cups
# udev-backed libusb (colord/system-config-printer chain)
virtual/libusb udev
dev-libs/libusb udev
# PipeWire as the sound server (PipeWire-not-PulseAudio); provides the pulse-compat daemon
media-video/pipewire pulse sound-server
media-libs/libcanberra pulseaudio   # client lib only; PipeWire provides the pulse server
# accumulating GNOME USE deps (autounmask-suggested)
media-libs/harfbuzz icu
app-crypt/gcr gtk
# evolution-data-server oauth-gtk3 drags in the whole webkit-gtk build; not needed
gnome-extra/evolution-data-server -oauth-gtk3
media-libs/freetype harfbuzz
x11-base/xwayland libei
media-libs/vulkan-loader X
app-text/xmlto text
```

## /etc/portage/package.use/qa-kde

```
*/* qt6
dev-qt/qtbase:6 X cups libproxy opengl icu
dev-qt/* X qml icu
kde-frameworks/* X qml
kde-plasma/* X qml
kde-apps/* X qml
x11-libs/libxkbcommon X
media-libs/libepoxy X
media-libs/libglvnd X
kde-frameworks/kconfig qml
app-text/xmlto text
sys-apps/dbus X
```

## /etc/portage/package.use/qa-gnome-bg (wallpaper / JPEG-XL)

```
x11-libs/gdk-pixbuf jpeg
media-libs/glycin-loaders jpegxl
```

Without these, GNOME 49 shows the solid `primary-color` fallback instead of the `adwaita-*.jxl`
wallpaper: `x11-themes/gnome-backgrounds` must be installed, and the wallpaper is JPEG-XL, so glycin
(GNOME's image loader) needs `jpegxl` to decode it. See F15.

## /etc/portage/package.use/qa-firefox, qa-chromium

```
# qa-firefox
media-libs/libvpx postproc
# qa-chromium
dev-libs/libxml2 icu
media-libs/libva X
sys-libs/zlib minizip
```

Firefox on glibc builds with the system clang/rust directly (no LLVM-slot juggling, unlike musl —
F10). Chromium is `:beta`; it needs the unRAR license:

```
# /etc/portage/package.license/qa-chromium
>=www-client/chromium-150.0.7871.13:beta unRAR
```

## amdgpu build test (VIDEO_CARDS)

```
# /etc/portage/env/amdgpu.conf
VIDEO_CARDS="virtio virgl amdgpu radeonsi"
# /etc/portage/package.env/qa-amdgpu
media-libs/mesa amdgpu.conf
x11-libs/libdrm amdgpu.conf
```

The AMD driver stack (mesa radeonsi, RADV Vulkan, `xf86-video-amdgpu`) builds; it is not run, since the
guest has only virtio-gpu (F14 also covers building it under enforcing).
