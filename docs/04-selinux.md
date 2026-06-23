# 04 · SELinux

Getting SELinux working on a musl/clang/OpenRC system that is not on a SELinux profile. Most of the
findings came from this work. Cross-references point to [07-exceptions.md](07-exceptions.md) for the
short exception entries.

## Result

SELinux is enabled and **enforcing**: `sestatus` reports enabled, `targeted` policy, enforcing mode.
The filesystem is labeled (`/sbin/init` → `init_exec_t`, `/` → `root_t`), processes are labeled
(`ps -eZ` shows `init_t`, `kernel_t`), and root login is mapped to `sysadm_u:sysadm_r:sysadm_t`, a
confined admin domain rather than `unconfined_t`. `__default__` maps to `unconfined_u`. There are no
AVC denials at boot.

The system first ran in permissive mode so that denials were logged without locking out SSH while the
labeling and policy settled, then moved to enforcing after the denials were resolved (see "Reaching
enforcing" below).

## Blockers, in the order they occurred

1. **The `selinux` USE flag is masked off-profile (E10).** `profiles/base/use.mask` masks `selinux`;
   only the SELinux profiles unmask it. On `musl/llvm` it stays masked, so the userland installs but
   nothing integrates (coreutils, openrc, and pam build with `-selinux`). Fix: add `-selinux` to
   `/etc/portage/profile/use.mask` to unmask it. Without this, boot-time policy loading is not
   possible.

2. **libselinux does not compile on musl (E9).** `selinux_restorecon.c` uses the glibc-only `struct
   stat64` and `lstat64()` (the Makefile sets `USE_LFS=y`). musl has no `*64` API because its `stat`
   and `lstat` are already 64-bit, and clang treats the implicit declaration as an error. Fix: a
   two-line `/etc/portage/patches` patch (`stat64`→`stat`, `lstat64`→`lstat`). libselinux is the base
   of the stack; nothing SELinux builds without it. This is specific to musl, not to clang or LTO.

3. **`FEATURES=test` makes the userland uninstallable (E7/E8).** Global `test` enables the `test` USE
   flag on `selinux-python` and `setools`, which pull `pyqt6[testlib]` and a Python test tree
   (cryptography, werkzeug, pip, poetry-core, and others) ending at `dev-python/pillow` with an
   unsatisfiable `REQUIRED_USE="test? ( jpeg jpeg2k lcms tiff truetype )"`. Fix: disable tests for the
   SELinux cluster and `dev-python/*` only. C/C++ tests stay enabled.

4. **The sandbox blocks SELinux-aware coreutils (E13).** After coreutils is rebuilt with `selinux`,
   `cp -a` writes the fscreate context to `/proc/*/attr/fscreate`, which Gentoo's build sandbox denies,
   so every later emerge install fails. Fix: a `sandbox.d` entry adding `SANDBOX_WRITE` for the
   `/proc/*/attr/` paths. Enabling SELinux silently breaks all later builds until the sandbox is told
   about the attr procfs.

5. **Integrating SELinux without pulling in X11 (E11/E12).** Rebuilding base packages with `selinux`
   under `FEATURES=test` pulls `dbus` and `glib` test dependencies that need `xorg-server` and
   `mesa[X]`, which would reintroduce X11. Fix: run that one rebuild with command-scoped
   `FEATURES=-test`; global `test` is unchanged. Packages rebuilt with `selinux`: openrc, coreutils,
   util-linux, pam, shadow, procps, findutils, openssh, sysvinit.

## Boot-time loading

With `openrc[selinux]`, `sysvinit[selinux]`, and the `selinux-openrc` policy module, the policy loads
automatically at boot (dmesg shows `SELinux: Initializing` and the policy capabilities). The kernel
side is in `kernel-base.fragment` (`SECURITY_SELINUX`, `AUDIT`, `CONFIG_LSM=...,selinux`,
`EXT4_FS_SECURITY`).

## Reaching enforcing

Starting from permissive, the steps are (scripted in `config/selinux/setup-enforcing.sh`):

1. Relabel the whole filesystem: `setfiles -F ... file_contexts /`.
2. Relabel `/root` explicitly. This is the common blocker: `/root` is often left `default_t`, which
   `sshd_t` cannot `search`, so every login fails before a shell starts (the visible symptom is
   `/bin/bash: Permission denied` or `Could not chdir to home directory /root`). `restorecon -RF /root`
   sets it to `user_home_dir_t`.
3. `setsebool -P ssh_sysadm_login on` before flipping to enforcing. This lets an SSH login reach the
   `sysadm_r` role and is the anti-lockout switch; without it, confining root would lock SSH out.
4. `semanage login -a -s sysadm_u root` to map root to the confined `sysadm_u`/`sysadm_t`.
5. Load `config/selinux/qa_local.te` for the residual service denials (a few `mount_t`,
   `systemd_tmpfiles_t`, and `udev_t` accesses); it is generated with `audit2allow`.
6. Enable auditd, set `SELINUX=enforcing`, reboot.

After this the system boots enforcing, `id -Z` shows `sysadm_u:sysadm_r:sysadm_t`, and
`ausearch -m AVC -ts boot` reports no enforced (`permissive=0`) denials. The glibc image uses the same
procedure with the `mcs` policy; it needed only the relabel and the boolean/login mapping, no module.
