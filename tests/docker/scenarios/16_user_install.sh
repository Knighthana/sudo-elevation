#!/bin/bash
# 0.1.6: XDG user-install (root installs into tester's XDG homes).
# Layout, ownership, receipt auto-source, real lease flow, keep/purge, ghosts.
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
log "user-install as root for tester"
"$REPO/install.sh" --user-install --user tester --test-hooks >/dev/null
assert_file /home/tester/.local/bin/sudo-elevation
assert_file /home/tester/.local/bin/sudo-askpass
assert_file /home/tester/.local/libexec/sudo-elevation/grant
assert_file /home/tester/.config/sudo-elevation/config
assert_file /home/tester/.config/sudo-elevation/env
assert_contains /home/tester/.config/sudo-elevation/env "SUDO_ELEVATION_BINDIR=/home/tester/.local/bin"
assert_no_file /usr/local/share/sudo-elevation/manifest
assert_no_file /usr/local/bin/sudo-elevation
assert_no_file /usr/local/bin/sudo-askpass
ok "user layout, system payload untouched"
assert_eq "$(stat -c %U /home/tester/.local/bin/sudo-elevation)" tester "payload owned by user"
assert_eq "$(stat -c %U /home/tester/.config/sudo-elevation/config)" tester "config owned by user"
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=15"
assert_contains /etc/sudo.conf "Path askpass /home/tester/.local/bin/sudo-askpass"
grep -q 'INSTALL_MODE=user' /home/tester/.local/share/sudo-elevation/manifest || die "manifest mode"
grep -q 'SYSTEM=1' /home/tester/.local/share/sudo-elevation/manifest || die "manifest system flag"
ok "system step applied + manifest"

log "CLI works via receipt (no exports)"
out=$(runuser -u tester -- /home/tester/.local/bin/sudo-elevation status --porcelain)
grep -qF 'active=0' <<<"$out" || die "receipt resolution broken: $out"
ok "receipt auto-source"

log "real lease flow through user paths"
cat > /tmp/se-ui-fake <<'EOF'
#!/bin/sh
export SUDO_ELEVATION_UI=fake
SUDO_ELEVATION_FAKE_CHOICE="$(cat /tmp/se-test-choice 2>/dev/null || echo 15)"
SUDO_ELEVATION_FAKE_PASSWORD="$(cat /tmp/se-test-password 2>/dev/null || echo testpass)"
export SUDO_ELEVATION_FAKE_CHOICE SUDO_ELEVATION_FAKE_PASSWORD
exec /home/tester/.local/bin/sudo-askpass "$@"
EOF
chmod 0755 /tmp/se-ui-fake
set_ui 15 testpass
if ! runuser -u tester -- env SUDO_ASKPASS=/tmp/se-ui-fake \
	/home/tester/.local/bin/sudo-elevation request --for 15m --reason "user install" >/tmp/se-ui-req.log 2>&1; then
	cat /tmp/se-ui-req.log
	die "user-install request failed"
fi
assert_contains /run/sudo-elevation/tester.lease "reason=user install"
assert_ok runuser -u tester -- sudo -n true
out=$(runuser -u tester -- /home/tester/.local/bin/sudo-elevation status --porcelain)
grep -qF 'minutes=15' <<<"$out" || die "porcelain minutes: $out"
ok "lease works"

log "keep uninstall via CLI (manifest forwards --user-install)"
if ! runuser -u tester -- env SUDO_ASKPASS=/tmp/se-ui-fake \
	/home/tester/.local/bin/sudo-elevation uninstall --keep >/tmp/se-ui-keep.log 2>&1; then
	cat /tmp/se-ui-keep.log
	die "CLI keep uninstall failed"
fi
assert_no_file /home/tester/.local/bin/sudo-elevation
assert_no_file /home/tester/.local/bin/sudo-askpass
assert_file /home/tester/.config/sudo-elevation/config
assert_file /home/tester/.local/share/sudo-elevation/manifest
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=15"
assert_contains /etc/sudo.conf "Path askpass /home/tester/.local/bin/sudo-askpass"
if runuser -u tester -- sudo -n true >/dev/null 2>&1; then die "cache survived keep"; fi
ok "keep: payload gone, config kept, lease ended"

log "purge removes everything including own ghosts, preserves handmade"
printf '# Managed by sudo-elevation test -- do not edit.\nDefaults:ghost timestamp_timeout=15\n' > /etc/sudoers.d/90-sudo-elevation-ghost
chmod 0440 /etc/sudoers.d/90-sudo-elevation-ghost
printf 'Defaults:handmade timestamp_timeout=10\n' > /etc/sudoers.d/90-sudo-elevation-handmade
chmod 0440 /etc/sudoers.d/90-sudo-elevation-handmade
printf 'epoch=1-1-1\nminutes=5\nrestore=none\n' > /run/sudo-elevation/ghost.lease
printf 'foreign\n' > /run/sudo-elevation/notes.txt
touch /etc/sudo.conf.bak.20000101000000
printf '# admin backup\n' > /etc/sudo.conf.bak.admin-keep
"$REPO/install.sh" --user-install --user tester --uninstall --purge >/dev/null
assert_no_file /etc/sudoers.d/90-sudo-elevation-tester
assert_no_file /etc/sudoers.d/90-sudo-elevation-ghost
assert_file /etc/sudoers.d/90-sudo-elevation-handmade
rm -f /etc/sudoers.d/90-sudo-elevation-handmade
assert_no_file /run/sudo-elevation/ghost.lease
assert_file /run/sudo-elevation/notes.txt
rm -f /run/sudo-elevation/notes.txt
rmdir /run/sudo-elevation 2>/dev/null || true
assert_no_file /home/tester/.config/sudo-elevation/config
assert_no_file /home/tester/.config/sudo-elevation/env
assert_no_file /home/tester/.local/share/sudo-elevation/manifest
assert_no_file /etc/sudo.conf.bak.20000101000000
assert_file /etc/sudo.conf.bak.admin-keep
rm -f /etc/sudo.conf.bak.admin-keep
assert_not_contains /etc/sudo.conf "# >>> sudo-elevation >>>"
assert_ok visudo -c
assert_ok sudo -V
ok "purge clean, admin backup kept"
