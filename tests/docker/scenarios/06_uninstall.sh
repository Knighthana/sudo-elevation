#!/bin/bash
# Uninstall in two modes (repo-flag path covered by run-host):
#   keep (default): payload gone, config kept, lease ended, sudo stays usable;
#   purge: everything gone including ghosts (suspect data included).
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

log "active lease before keep uninstall"
set_ui 15 testpass
as_tester /usr/local/bin/sudo-elevation request --for 15m --reason "keep test" >/dev/null

log "keep uninstall via CLI: payload gone, config kept, lease ended"
if ! as_tester /usr/local/bin/sudo-elevation uninstall >/tmp/se-uninstall.log 2>&1; then
	cat /tmp/se-uninstall.log
	die "CLI keep uninstall failed"
fi
assert_no_file /usr/local/bin/sudo-askpass
assert_no_file /usr/local/bin/sudo-elevation
assert_no_file /usr/local/libexec/sudo-elevation/grant
assert_no_file /usr/local/libexec/sudo-elevation/install.sh
assert_file /etc/sudo-elevation.conf
assert_file /etc/sudoers.d/90-sudo-elevation-tester
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=15"
assert_contains /etc/sudo.conf "# container-custom-marker"
assert_contains /etc/sudo.conf "# >>> sudo-elevation >>>"
assert_file /home/tester/.config/opencode/skill/sudo-elevation/SKILL.md
assert_file /usr/local/share/sudo-elevation/manifest
assert_file /var/log/sudo-elevation.log
if as_tester sudo -n true >/dev/null 2>&1; then
	die "cache survived keep uninstall"
fi
ok "keep: coherent base state, sudo still usable"
assert_ok sudo -V
# sudo -A fails without askpass, plain sudo path unaffected (password path):
runuser -u tester -- sudo -k || true
if runuser -u tester -- env SUDO_ASKPASS=/bin/false timeout 10 sudo -A true >/dev/null 2>&1; then
	die "sudo -A unexpectedly worked without askpass"
fi
ok "dangling askpass only breaks sudo -A"

log "purge via installer removes everything including ghosts"
printf 'Defaults: ghost timestamp_timeout=15\n' > /etc/sudoers.d/90-sudo-elevation-ghost
"$REPO/install.sh" --user tester --uninstall --purge >/dev/null
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
assert_no_file /etc/sudoers.d/90-sudo-elevation-ghost
assert_no_file /home/tester/.config/opencode/skill/sudo-elevation/SKILL.md
assert_no_file /usr/local/share/sudo-elevation/manifest
assert_no_file /run/sudo-elevation
assert_no_file /var/log/sudo-elevation.log
baks=()
for b in /etc/sudo.conf.bak.*; do
	[ -f "$b" ] && baks+=("$b")
done
assert_eq "${#baks[@]}" 0 "no sudo.conf backups left"
assert_ok visudo -c
assert_ok sudo -V
ok "purge clean (no backups, no runtime dir, foreign lines kept, ghosts gone)"
