#!/usr/bin/env bash
###############################################################################
# Reproducible install: hostile musl/LLVM/hardened/SELinux/Wayland Gentoo VM
#
# RUN INSIDE the Gentoo minimal live ISO (booted in QEMU), as root.
# Assumes the stage3 musl-llvm-openrc tarball + this repository are reachable
# (here via a 9p mount at /mnt/hostshare). Target disk = $DISK (default /dev/vda).
#
# This reproduces the FINAL hardened state, not the early bring-up:
#   full -flto, -O3, CET, stack-clash, auto-var-init, zero-call-regs (E16);
#   a clang KCFI/LTO hardened kernel (kernel-base.fragment + kernel-hardened.fragment);
#   KSPP sysctl; SELinux enforcing with root mapped to sysadm_t.
# The canonical config files live in this repository's config/ directory.
# Deviations are documented in docs/07-exceptions.md (E1..E22).
###############################################################################
set -euo pipefail
REPO=/mnt/hostshare                  # this repository, made available to the installer
STAGE3=$REPO/stage3-amd64-musl-llvm-openrc-20260614T170130Z.tar.xz
G=/mnt/gentoo

# Install target disk. Set DISK for the target hardware
# (e.g. /dev/sda or /dev/nvme0n1). Defaults to /dev/vda.
DISK="${DISK:-/dev/vda}"
P=""; case "$DISK" in *[0-9]) P=p ;; esac   # nvme/loop need a 'p' before the partition number
ESP="${DISK}${P}1"; SWAP="${DISK}${P}2"; ROOT="${DISK}${P}3"

############################ 1. partition + format ############################
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+512M -t1:ef00 -c1:ESP \
       -n2:0:+8G   -t2:8200 -c2:swap \
       -n3:0:0     -t3:8300 -c3:root "$DISK"
mkfs.vfat -F32 -n ESP "$ESP"
mkswap -L swap "$SWAP" && swapon "$SWAP"
mkfs.ext4 -q -L root "$ROOT"

############################ 2. unpack stage3 #################################
mkdir -p $G && mount "$ROOT" $G
tar xpf "$STAGE3" -C $G --xattrs-include='*.*' --numeric-owner
# profile is already default/linux/amd64/23.0/musl/llvm (clang/lld/llvm-ar set by profile)

############################ 3. chroot prep ##################################
cp --dereference /etc/resolv.conf $G/etc/
mount --types proc /proc $G/proc
mount --rbind /sys $G/sys;  mount --make-rslave $G/sys
mount --rbind /dev $G/dev;  mount --make-rslave $G/dev
mount --bind /run $G/run;   mount --make-slave $G/run
mkdir -p $G/boot && mount "$ESP" $G/boot   # REQUIRED: mount-boot.eclass guard

############################ 4. make.conf + portage overrides ################
# The full hardened make.conf (full -flto, -O3, CET, stack-clash, auto-var-init,
# zero-call-regs, FORTIFY=3; RELRO/BIND_NOW/noexecstack/separate-code LDFLAGS).
# See config/make.conf and docs/02-configuration.md. Bring-up may use -flto=thin
# first and escalate to full -flto via `emerge -e @world` (E1, docs/06-full-lto.md).
cp $REPO/config/make.conf $G/etc/portage/make.conf

# All the documented portage overrides (the exceptions), shipped in the repository:
#   profile/use.mask (-selinux, E10); package.use (grub -device-mapper E4,
#   *-elogind E14/E15, selinux python bindings); package.env + env/notest.conf
#   (per-package FEATURES=-test, E5-E8); patches/sys-libs/libselinux (E9); bashrc
#   (net-tools ROSE off, E17); repos.conf; package.accept_keywords.
cp -a $REPO/config/etc-portage/. $G/etc/portage/
# sandbox write for the SELinux fscreate procfs path (E13):
mkdir -p $G/etc/sandbox.d
echo 'SANDBOX_WRITE="/proc/self/attr/:/proc/thread-self/attr/"' > $G/etc/sandbox.d/30selinux-attr

############################ 5. sync + base config ###########################
chroot $G /bin/bash -lc 'emerge-webrsync'
chroot $G /bin/bash -lc 'echo "C.UTF-8 UTF-8" > /etc/locale.gen; true'
ln -sf /usr/share/zoneinfo/UTC $G/etc/localtime

############################ 6. boot tooling + hardened kernel ###############
chroot $G /bin/bash -lc 'emerge --keep-going=y sys-kernel/gentoo-sources sys-kernel/installkernel \
    sys-boot/grub sys-boot/efibootmgr sys-fs/dosfstools sys-apps/diffutils dev-vcs/git'
chroot $G /bin/bash -lc 'eselect kernel set 1'
cp $REPO/config/kernel-base.fragment $REPO/config/kernel-hardened.fragment $G/root/
# clang build (LLVM=1); merge the base virtio/SELinux fragment AND the v2 hardened
# fragment (KCFI: CONFIG_CFI, LTO_CLANG, lockdown LSM, KSPP, IOMMU strict, KFENCE).
chroot $G /bin/bash -lc 'cd /usr/src/linux && make LLVM=1 defconfig \
    && ./scripts/kconfig/merge_config.sh -m .config /root/kernel-base.fragment /root/kernel-hardened.fragment \
    && make LLVM=1 olddefconfig && make LLVM=1 -j8 \
    && make LLVM=1 modules_install && make LLVM=1 install'

############################ 7. fstab + bootloader (hardened cmdline) ########
# fstab: UUID= for $ROOT (/ ext4), $ESP (/boot vfat), $SWAP (swap)
# /etc/default/grub GRUB_CMDLINE_LINUX: serial console, SELinux LSM, and the full
# KSPP + CPU-mitigation + lockdown command line:
#   console=tty0 console=ttyS0,115200 lsm=landlock,lockdown,yama,integrity,selinux,bpf
#   lockdown=confidentiality mitigations=auto,nosmt spectre_v2=on spec_store_bypass_disable=on
#   l1tf=full,force mds=full,nosmt tsx=off tsx_async_abort=full,nosmt mmio_stale_data=full,nosmt
#   retbleed=auto,nosmt gather_data_sampling=force slab_nomerge init_on_alloc=1 init_on_free=1
#   randomize_kstack_offset=on pti=on vsyscall=none debugfs=off
chroot $G /bin/bash -lc 'grub-install --target=x86_64-efi --efi-directory=/boot --removable --boot-directory=/boot'
chroot $G /bin/bash -lc 'grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo --boot-directory=/boot || true'
chroot $G /bin/bash -lc 'grub-mkconfig -o /boot/grub/grub.cfg'

############################ 8. sysctl hardening #############################
# KSPP-style runtime hardening + perf tuning (applies to both images):
cp $REPO/config/sysctl-hardening.conf $G/etc/sysctl.d/99-hardening.conf

############################ 9. services + root + ssh #######################
echo 'hostname="gentoo-hostile"' > $G/etc/conf.d/hostname
echo "root:gentooqa" | chroot $G chpasswd
sed -i -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
       -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' $G/etc/ssh/sshd_config
printf '\ns0:12345:respawn:/sbin/agetty 115200 ttyS0 vt100\n' >> $G/etc/inittab   # serial getty
chroot $G /bin/bash -lc 'rc-update add sshd default; rc-update add dhcpcd default'

########################### 10. SELinux: install + permissive first #########
# selinux USE unmasked (E10); userland needs the libselinux musl patch (E9).
chroot $G /bin/bash -lc 'emerge sec-policy/selinux-base-policy sys-apps/policycoreutils \
    sys-libs/libselinux sys-apps/checkpolicy sys-apps/selinux-python sys-process/audit'
printf 'SELINUX=permissive\nSELINUXTYPE=targeted\n' > $G/etc/selinux/config
# Rebuild base with selinux integration WITHOUT tests (E11/E12 avoid the X11 cascade):
chroot $G /bin/bash -lc 'FEATURES="-test" emerge -1 sys-apps/openrc sys-apps/coreutils \
    sys-apps/util-linux sys-libs/pam sys-apps/shadow sys-apps/findutils sys-process/procps \
    net-misc/openssh sys-apps/dbus sys-apps/sysvinit'
chroot $G /bin/bash -lc 'setfiles -F -e /proc -e /sys -e /dev -e /run \
    /etc/selinux/targeted/contexts/files/file_contexts /'

########################### 11. PipeWire / Wayland (no X11, no elogind) #####
chroot $G /bin/bash -lc 'FEATURES="-test" emerge media-video/pipewire media-video/wireplumber \
    dev-libs/wayland dev-libs/wayland-protocols sys-auth/seatd media-libs/mesa'
chroot $G /bin/bash -lc 'rc-update add dbus default; rc-update add seatd default'

########################### 12. full LTO escalation #########################
# Switch COMMON_FLAGS -flto=thin -> -flto (full) in make.conf if bring-up used thin,
# then re-apply across the system (CFLAG change is not tracked by -uDN, needs emptytree):
#   FEATURES="-test" emerge -e --keep-going=y @world
# (E11: a full @world under FEATURES=test pulls X11 / hits unsat REQUIRED_USE.)

########################### 13. SELinux -> enforcing ########################
# After reviewing AVC denials in permissive: load a local policy module for the
# sshd login transition (qa_local), map root to the confined sysadm_t domain, then:
#   sed -i 's/^SELINUX=permissive/SELINUX=enforcing/' /etc/selinux/config
# Reboot; verify `sestatus` -> enforcing and `id -Z` -> sysadm_u:sysadm_r:sysadm_t.

echo "DONE. Reboot from disk (UEFI -> /boot/EFI/BOOT/BOOTX64.EFI -> GRUB)."
