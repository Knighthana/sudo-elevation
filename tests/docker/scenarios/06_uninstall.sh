#!/bin/bash
# Uninstall through the CLI subcommand (repo-flag path covered by run-host):
# foreign sudo.conf content preserved, every installed artifact removed,
# backups and the runtime directory cleaned up.
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user

log "pre-existing sudo.conf content"
printf '# container-custom-marker\n' >> /etc/sudo.conf
install_se
assert_contains /etc/sudo.conf "# container-custom-marker"
assert_contains /etc/sudo.conf "# >>> sudo-elevation >>>"
assert_file /usr/local/libexec/sudo-elevation/install.sh

log "re-install prunes sudo.conf backups down to one"
install_se >/dev/null
baks=()
for b in /etc/sudo.conf.bak.*; do
	[ -f "$b" ] && baks+=("$b")
done
assert_eq "${#baks[@]}" 1 "single sudo.conf backup"

log "uninstall via CLI (sudo-elevation uninstall)"
set_ui 15 testpass
if ! as_tester /usr/local/bin/sudo-elevation uninstall >/tmp/se-uninstall.log 2>&1; then
	cat /tmp/se-uninstall.log
	die "CLI uninstall failed"
fi
assert_contains /etc/sudo.conf "# container-custom-marker"
assert_not_contains /etc/sudo.conf "# >>> sudo-elevation >>>"
assert_not_contains /etc/sudo.conf "Path askpass /usr/local/bin/sudo-askpass"
assert_no_file /usr/local/bin/sudo-askpass
assert_no_file /usr/local/bin/sudo-elevation
assert_no_file /usr/local/libexec/sudo-elevation/grant
assert_no_file /usr/local/libexec/sudo-elevation/restore
assert_no_file /usr/local/libexec/sudo-elevation/install.sh
assert_no_file /usr/local/libexec/sudo-elevation/common.sh
assert_no_file /etc/sudo-elevation.conf
assert_no_file /etc/sudoers.d/90-sudo-elevation-tester
assert_no_file /home/tester/.config/opencode/skill/sudo-elevation/SKILL.md
assert_no_file /run/sudo-elevation
baks=()
for b in /etc/sudo.conf.bak.*; do
	[ -f "$b" ] && baks+=("$b")
done
assert_eq "${#baks[@]}" 0 "no sudo.conf backups left"
assert_ok visudo -c
assert_ok sudo -V
ok "CLI uninstall clean (no backups, no runtime dir, foreign lines kept)"
