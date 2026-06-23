# musl image — code only (diffs / configs / key commands)

> Generated from the actual artifacts. Minimal prose. Narrative: docs/02,04,07,08.

## /etc/portage/make.conf
```sh
# Gentoo musl/LLVM hostile VM make.conf
# Profile: default/linux/amd64/23.0/musl/llvm
# Toolchain (clang/clang++/ld.lld/llvm-ar/llvm-nm) is set by the profile; not overridden here.
# Exceptions & rationale: /root/ai-run/constraint-exceptions.md

CHOST="x86_64-pc-linux-musl"

# Hostile hardening flags. Do not remove globally to make builds pass.
COMMON_FLAGS="-march=x86-64-v3 -O3 -pipe"
COMMON_FLAGS="${COMMON_FLAGS} -fstack-protector-strong -fno-semantic-interposition"
# LTO: ThinLTO for base bring-up; escalate to full -flto later (user request). See exceptions doc.
COMMON_FLAGS="${COMMON_FLAGS} -flto"
COMMON_FLAGS="${COMMON_FLAGS} -D_FORTIFY_SOURCE=3 -fstack-clash-protection -fcf-protection=full -ftrivial-auto-var-init=zero -fzero-call-used-regs=used-gpr"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"

# PIE/hardening linkage. lld is the profile linker.
LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,separate-code"

MAKEOPTS="-j8 -l12"

# Experimental musl/llvm profile -> keyword acceptance needed. Documented in exceptions.
ACCEPT_KEYWORDS="~amd64"

# Keep tests + logs + binpkgs. Do NOT globally disable tests.
FEATURES="test fail-clean buildpkg preserve-libs parallel-install"

# Hostile but coherent global USE.
USE="clang lto pie selinux hardened btrfs -elogind dbus nls"
USE="${USE} opengl qml"
USE="${USE} wayland pipewire alsa libinput"
USE="${USE} policykit networkmanager screencast vaapi vulkan"
USE="${USE} -X -pulseaudio -systemd -gnome -kde -qt5 -qt6"

VIDEO_CARDS="virtio virgl"
INPUT_DEVICES="libinput"

# AI automation: never --ask; keep verbose logs; modest parallelism to survive LTO RAM use.
EMERGE_DEFAULT_OPTS="--verbose --jobs=2 --load-average=12 --keep-going=y --with-bdeps=y"

PORTAGE_ELOG_CLASSES="log warn error qa"
PORTAGE_ELOG_SYSTEM="save"

GENTOO_MIRRORS="https://distfiles.gentoo.org https://mirror.leaseweb.com/gentoo"
LC_MESSAGES=C.UTF-8
GRUB_PLATFORMS="efi-64"
PORTAGE_LOGDIR="/var/log/portage"
```

## /etc/portage/package.use/qa-boot
```
# VM has no LVM/device-mapper root -> drop grub device-mapper, which otherwise pulls
# sys-fs/lvm2[test] whose REQUIRED_USE="test? ( lvm )" conflicts under global FEATURES=test.
# This does NOT weaken any target constraint (LVM is not a target). See constraint-exceptions.md E4.
sys-boot/grub -device-mapper
```

## /etc/portage/package.use/qa-kde
```
# full KDE (user request): flip -kde -qt6 for the desktop stack. elogind unbuildable on musl ->
# rely on seatd; drop fontconfig on plasma-workspace to avoid REQUIRED_USE fontconfig?(X).
*/*  qt6
kde-plasma/plasma-workspace  -fontconfig -policykit
kde-plasma/kwin  lock
dev-libs/xerces-c  icu
sys-apps/dbus      X
dev-libs/libei -elogind
x11-libs/libxkbcommon X
media-libs/mesa X
kde-frameworks/kwindowsystem X
# Decision A: enable X across the whole KDE/Qt stack (XWayland/KX11Extras). No xorg-server with -test.
dev-qt/*          X
kde-frameworks/*  X
kde-plasma/*      X
kde-apps/*        X
net-misc/networkmanager  -elogind
app-text/xmlto           text
media-libs/libepoxy      X
media-libs/libglvnd      X
sys-libs/zlib            minizip
dev-qt/qtbase:6 X cups libproxy opengl icu
dev-qt/qt5compat   icu
x11-base/xwayland  libei
```

## /etc/portage/package.use/qa-selinux
```
# SELinux userland needs python bindings (legit, not a weakening).
sys-libs/libselinux python
sys-process/audit    python
app-misc/pax-utils python
sys-apps/dbus -elogind
```

## /etc/portage/package.use/qa-wayland
```
# elogind does not build on musl (E14). Route seat/session via standalone seatd instead.
sys-auth/seatd          server -elogind
media-video/pipewire    -elogind
media-video/wireplumber -elogind
sys-auth/polkit         -elogind
media-libs/freetype harfbuzz
gui-libs/xdg-desktop-portal-wlr -elogind
media-libs/libvpx postproc
```

## /etc/portage/package.env/qa-notest
```
# Per-package test exceptions (global FEATURES=test stays on). See constraint-exceptions.md.
# E5: expect<->dejagnu circular build dep induced by FEATURES=test auto-enabling their test USE.
dev-tcltk/expect   notest.conf
dev-util/dejagnu   notest.conf
sys-libs/efivar       notest.conf
# E7: SELinux userland test-dep cascade (FEATURES=test). selinux-python/setools[test]
# pull pyqt6 testlib + a python test tree ending in pillow REQUIRED_USE conflict.
sys-apps/selinux-python   notest.conf
app-admin/setools         notest.conf
sys-apps/policycoreutils  notest.conf
sec-policy/selinux-base   notest.conf
# E8: FEATURES=test causes pervasive dev-python test-dep cascades (pillow REQUIRED_USE,
# setuptools slot conflicts, pyqt6 testlib). Disable python TEST SUITES only; C/C++ tests stay on.
dev-python/*  notest.conf
sys-process/audit  notest.conf
# E21: FEATURES=test forces test USE across Qt6/KDE -> pervasive test?(...) REQUIRED_USE conflicts
# (qtbase test?(icu), qtmultimedia, etc.). Disable test suites for the Qt6/KDE desktop stack only.
dev-qt/*           notest.conf
kde-frameworks/*   notest.conf
kde-plasma/*       notest.conf
kde-apps/*         notest.conf
kde-misc/*         notest.conf
```

## /etc/portage/env/notest.conf
```
FEATURES="-test"
```

## /etc/portage/profile/use.mask
```
-selinux
```

## patches/sys-libs/libselinux/0001-musl-no-stat64.patch
```diff
--- a/src/selinux_restorecon.c	2026-06-21 12:50:54.150860027 +0000
+++ b/src/selinux_restorecon.c	2026-06-21 12:50:54.151881263 +0000
@@ -443,7 +443,7 @@
 	file_spec_t *prevfl, *fl;
 	uint32_t h;
 	int ret;
-	struct stat64 sb;
+	struct stat sb;
 
 	__pthread_mutex_lock(&fl_mutex);
 
@@ -457,7 +457,7 @@
 	for (prevfl = &fl_head[h], fl = fl_head[h].next; fl;
 	     prevfl = fl, fl = fl->next) {
 		if (ino == fl->ino) {
-			ret = lstat64(fl->file, &sb);
+			ret = lstat(fl->file, &sb);
 			if (ret < 0 || sb.st_ino != ino) {
 				freecon(fl->con);
 				free(fl->file);
```

## /etc/sandbox.d/30selinux-attr
```sh
SANDBOX_WRITE="/proc/self/attr/:/proc/thread-self/attr/"
```

## /etc/portage/bashrc
```sh
# disable ROSE in net-tools — kernel-7.1 UAPI lacks linux/rose.h, but net-tools
# config.in defaults HAVE_AFROSE/HAVE_HWROSE to 'y', so rose.c fails to compile. See E17.
post_src_prepare() {
    if [[ ${CATEGORY}/${PN} == sys-apps/net-tools ]]; then
        einfo "E17: disabling ROSE (HAVE_AFROSE/HAVE_HWROSE) — kernel lacks linux/rose.h"
        sed -i -e "/^bool.* HAVE_AFROSE /s:[yn]\$:n:" \
               -e "/^bool.* HAVE_HWROSE /s:[yn]\$:n:" config.in || true
    fi
}
```

## kernel-base.fragment
```
# kernel config fragment (merged onto `make defconfig` with clang/LLVM=1).
# Goal: boot a virtio UEFI guest off ext4 root with no initramfs, plus SELinux + hardening.

# --- boot/firmware ---
CONFIG_EFI=y
CONFIG_EFI_STUB=y
CONFIG_EFI_MIXED=n
CONFIG_FB_EFI=y
CONFIG_EFIVAR_FS=y

# --- console (serial for headless boot) ---
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_CMDLINE_BOOL=y

# --- virtio (root disk, net, etc.) built-in so no initramfs needed ---
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_PCI_LEGACY=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_VIRTIO_BALLOON=y
CONFIG_VIRTIO_INPUT=y
CONFIG_SCSI_VIRTIO=y

# --- block / fs ---
CONFIG_BLK_DEV=y
CONFIG_EXT4_FS=y
CONFIG_VFAT_FS=y
CONFIG_FAT_DEFAULT_UTF8=y
CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ISO8859_1=y
CONFIG_TMPFS=y
CONFIG_BTRFS_FS=y

# --- DRM for virtio-gpu / wayland (virgl) ---
CONFIG_DRM=y
CONFIG_DRM_VIRTIO_GPU=y
CONFIG_DRM_FBDEV_EMULATION=y

# --- networking core ---
CONFIG_INET=y
CONFIG_PACKET=y
CONFIG_UNIX=y

# --- SELinux + auditing + hardening (security target) ---
CONFIG_SECURITY=y
CONFIG_SECURITYFS=y
CONFIG_SECURITY_NETWORK=y
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_DEVELOP=y
CONFIG_SECURITY_SELINUX_AVC_STATS=y
CONFIG_DEFAULT_SECURITY_SELINUX=y
CONFIG_LSM="landlock,lockdown,yama,integrity,selinux,bpf"
CONFIG_AUDIT=y
CONFIG_AUDITSYSCALL=y
CONFIG_EXT4_FS_SECURITY=y
CONFIG_BTRFS_FS_POSIX_ACL=y

# extended attrs / labels
CONFIG_TMPFS_XATTR=y

# --- hardening knobs ---
CONFIG_STACKPROTECTOR=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_RANDOMIZE_MEMORY=y
CONFIG_FORTIFY_SOURCE=y
CONFIG_HARDENED_USERCOPY=y
CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y
CONFIG_INIT_STACK_ALL_ZERO=y
CONFIG_SLAB_FREELIST_RANDOM=y
CONFIG_SLAB_FREELIST_HARDENED=y

# --- cgroups/namespaces for elogind/openrc/containers ---
CONFIG_CGROUPS=y
CONFIG_NAMESPACES=y
CONFIG_BLK_DEV_INITRD=y

# --- misc ---
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_RTC_CLASS=y
CONFIG_RTC_DRV_CMOS=y
CONFIG_HYPERVISOR_GUEST=y
CONFIG_PARAVIRT=y
CONFIG_KVM_GUEST=y
```

## kernel-hardened.fragment
```
# Hardened kernel fragment v2 — merged ON TOP of kernel-base.fragment, clang/LLVM build.
# Adds clang-specific + KSPP hardening beyond the base (KASLR/FORTIFY/usercopy/init-on-alloc/
# slab-hardening/SSP-strong already in kernel-base.fragment). Build with `make LLVM=1`.
# NOTE: gcc-plugin hardening (STACKLEAK, RANDSTRUCT) is UNAVAILABLE under a clang build — clang has
# no GCC plugins; we use clang's stronger CFI + kernel LTO instead. See docs/02 + docs/04.

# --- clang Control Flow Integrity (forward-edge) — requires kernel LTO (clang) ---
CONFIG_LTO_CLANG=y
CONFIG_LTO_CLANG_THIN=y
CONFIG_CFI=y
CONFIG_CFI_CLANG=y  # (pre-7.1 alias; 7.1 uses CONFIG_CFI)
CONFIG_CFI_PERMISSIVE=n

# --- register / stack hardening ---
CONFIG_ZERO_CALL_USED_REGS=y
CONFIG_RANDOMIZE_KSTACK_OFFSET=y
CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=y
CONFIG_SCHED_STACK_END_CHECK=y
CONFIG_VMAP_STACK=y

# --- lockdown LSM (cmdline already lists lockdown in CONFIG_LSM; enable the module) ---
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y
# mode chosen at boot via lockdown= (integrity by default; can use confidentiality)

# --- memory allocator / list hardening (KSPP) ---
CONFIG_INIT_ON_FREE_DEFAULT_ON=y
CONFIG_SHUFFLE_PAGE_ALLOCATOR=y
CONFIG_LIST_HARDENED=y
CONFIG_BUG_ON_DATA_CORRUPTION=y
CONFIG_SLAB_BUCKETS=y
CONFIG_KFENCE=y
CONFIG_KFENCE_SAMPLE_INTERVAL=100

# --- DMA / IOMMU (protect against malicious devices) ---
CONFIG_IOMMU_DEFAULT_DMA_STRICT=y
CONFIG_IOMMU_SUPPORT=y
CONFIG_INTEL_IOMMU=y
CONFIG_AMD_IOMMU=y

# --- misc tightening (KSPP) ---
CONFIG_STRICT_KERNEL_RWX=y
CONFIG_STRICT_MODULE_RWX=y
CONFIG_DEBUG_WX=y
CONFIG_SECURITY_DMESG_RESTRICT=y
CONFIG_STATIC_USERMODEHELPER=n
CONFIG_LEGACY_VSYSCALL_NONE=y
CONFIG_DEVMEM=n
CONFIG_PROC_KCORE=n
CONFIG_HARDENED_USERCOPY=y
CONFIG_FORTIFY_SOURCE=y

# --- module signing off-topic here; keep modules but restrict ---
CONFIG_MODULE_SIG=n
```

## /etc/sysctl.d/99-qa-hardening.conf
```
# /etc/sysctl.d/99-qa-hardening.conf — KSPP-style hardening + perf tuning.
# Applies to BOTH the musl and glibc images. Values that need a kernel feature the VM lacks
# (e.g. bbr/fq, some bpf knobs) just warn and are skipped — harmless.

############################ HARDENING (KSPP + common) ############################
# kernel info-leak / introspection
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.printk = 3 3 3 3
kernel.perf_event_paranoid = 3
kernel.kexec_load_disabled = 1
kernel.sysrq = 0
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.yama.ptrace_scope = 2
dev.tty.ldisc_autoload = 0
vm.unprivileged_userfaultfd = 0
kernel.randomize_va_space = 2
# filesystem hardening
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
# network hardening
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

############################ PERFORMANCE ############################
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50
vm.max_map_count = 1048576
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
```

## key commands (artifacts/commands.log, deduped, prose stripped)
```sh
emerge-webrsync starting
emerge-webrsync (retry)
emerge boot tools + kernel sources
re-emerge boot tools with grub -device-mapper
re-emerge boot tools (expect/dejagnu notest)
re-emerge boot tools (efivar notest)
mounted ESP /dev/vda1 at chroot /boot (mount-boot.eclass guard)
re-emerge grub with /boot mounted
kernel build LLVM=1 -j8 start
grub-install + grub-mkconfig
POST-REBOOT: installed system boots from disk; musl+clang+openrc+ssh confirmed
emerge SELinux userland (36 pkgs)
rebuild libselinux with -fail-clean to capture compile error
libselinux musl patch + audit notest; re-emerge SELinux
setfiles relabel / and /boot
one-shot FEATURES=-test SELinux integration rebuild (42 pkgs)
sandbox fscreate fix; retry glib/dbus/elogind/polkit stack
relabel fs before reboot (boot-time SELinux test)
REBOOT for boot-time SELinux test
install PipeWire/Wayland stack (tests off, no elogind/X11)
graceful poweroff for snapshot
FULL LTO: emerge -e @world (FEATURES=-test) START
full-LTO @world DONE (436/441; fails: llvm-21(obsolete->22 ok), net-tools(musl rose.h), elogind(E14)); relabel+snapshot
HARDENING escalation flags applied; emerge -e @world START
removed invalid FEATURES=stricter (no-op token); doc corrected
TODO(post-build): fix net-tools rose.h via post_src_configure hook disabling HAVE_AFROSE/HAVE_HWROSE (kernel-7.1 UAPI lacks linux/rose.h); document as E17
E17 net-tools ROSE fix done (RC=0, hardening flags applied); relabel + snapshot base-full-lto-hardened
install eselect-repository + enable GURU for hyprland
syncing GURU overlay
enable+sync hyproverlay for Hyprland
HYPRLAND build START (-X, FEATURES=-test, ~70 pkgs)
Hyprland DRM backend run test (virtio-gpu)
HYPRLAND RUNS: hyprctl monitors shows Virtual-1@drm, wayland-1 socket created (kms_swrast fallback, no virgl)
sway+wlroots build (-X, FEATURES=-test)
sway DRM run test
SWAY RUNS: swaymsg get_outputs ok (1280x800), wlroots 0.20.1 drm backend, kms_swrast
xdg-desktop-portal-wlr stack build (-elogind, basu, FEATURES=-test)
portal stack done; auditd enabled; enforcing deferred to capstone (after GNOME/browsers). AVC preview saved.
GNOME = blocked (elogind/musl + forces X11 + PulseAudio). Documented E19. Reverted experiment overrides.
FIREFOX build START (wayland,-X,-pulseaudio,hardened; FEATURES=-test; pulls gcc16+nodejs+rust)
firefox build (real) start: libvpx postproc added
E16-FIX: dropped lld-only --icf=safe from LDFLAGS (broke gcc/GNU-ld); rebuild firefox(+gcc)
prepared kernel-hardened.fragment (CFI_CLANG+LTO_CLANG+lockdown+kstack-rand+iommu-strict etc); build after firefox
FIREFOX finding: static rust-bin dlopen(libclang) fails on musl; fix=source rust (deferred). Next: hardened kernel build.
hardened kernel cmdline set (KSPP + max mitigations + lockdown=confidentiality); building hardened kernel (CFI_CLANG+LTO_CLANG)
grub-mkconfig with hardened cmdline; rebooting into hardened kernel
enable CONFIG_CFI=y (KCFI, 7.1 naming); rebuild hardened kernel
reboot into KCFI kernel
KCFI kernel boots OK (CFI active, lockdown=confidentiality). snapshot.
source-rust (dev-lang/rust-1.95, dynamic rustc) build start
firefox retry with dynamic source rustc (rust-1.95.0)
removed rust-bin; firefox retry (force dynamic source rust)
firefox deferred (needs dynamic rust@LLVM21; ~3-4h). priority: KDE (decision A) next.
KDE: autounmask-write plasma-desktop (enable X for stack)
KDE = BLOCKED (plasma-workspace->networkmanager-qt->networkmanager[elogind]; musl elogind unbuildable). Same logind wall as GNOME. E22.
enforcing prep: portage cleaned, qa_local module, relabel done
qa_local(sshd->unconfined transition) loaded; enforcing retry
tighten: root->sysadm_u, ssh_sysadm_login=on; reboot
```
