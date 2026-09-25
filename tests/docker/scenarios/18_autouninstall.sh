#!/bin/bash
# Bare --uninstall is interactive (or list-only without a tty);
# any flag means automatic fail-fast mode. Covers keep->purge replay.
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se >/dev/null

log "active lease for realistic state"
set_ui 15 testpass
as_tester /usr/local/bin/sudo-elevation request --for 15m --reason "auto test" >/dev/null

log "bare uninstall without tty only lists (exit 2, nothing removed)"
if "$REPO/install.sh" --uninstall </dev/null >/tmp/se-list.log 2>&1; then
	die "list-only should exit nonzero when action is needed"
fi
grep -q "nothing was removed" /tmp/se-list.log || die "list must state nothing removed"
grep -q "purge:" /tmp/se-list.log || die "list must print replay commands"
assert_file /usr/local/bin/sudo-elevation
ok "list-only safe"

log "automatic mode fails fast without a timestamp"
runuser -u tester -- sudo -k || true
if runuser -u tester -- /usr/local/bin/sudo-elevation uninstall --purge >/tmp/se-nots.log 2>&1; then
	die "automatic uninstall should fail without timestamp"
fi
grep -q "no valid sudo timestamp" /tmp/se-nots.log || die "fail-fast message missing"
assert_file /usr/local/bin/sudo-elevation
ok "fail-fast, nothing touched"

log "automatic keep works once authenticated"
runuser -u tester -- env SUDO_ASKPASS="$ASKPASS" sudo -A true >/dev/null
if ! as_tester /usr/local/bin/sudo-elevation uninstall --keep >/tmp/se-akeep.log 2>&1; then
	cat /tmp/se-akeep.log
	die "automatic keep failed"
fi
assert_no_file /usr/local/bin/sudo-elevation
assert_file /etc/sudo-elevation.conf
assert_file /usr/local/share/sudo-elevation/manifest
grep -q "install.sh.*--uninstall --purge" /tmp/se-akeep.log || die "keep must print purge replay"
ok "automatic keep + replay hint"

log "interactive skip on a pty keeps everything"
install_se >/dev/null
set_ui 15 testpass
as_tester /usr/local/bin/sudo-elevation request --for 15m --reason "auto test" >/dev/null
printf 's\n' | script -qec "$REPO/install.sh --uninstall" /dev/null >/tmp/se-iskip.log 2>&1 || true
grep -q "skipped=1" /tmp/se-iskip.log || die "skip summary missing"
assert_file /usr/local/bin/sudo-elevation
ok "interactive skip safe"

log "interactive keep on a pty removes payload, keeps config"
printf 'k\n' | script -qec "$REPO/install.sh --uninstall" /dev/null >/tmp/se-ikeep.log 2>&1 || true
grep -q "kept=1" /tmp/se-ikeep.log || die "keep summary missing"
assert_no_file /usr/local/bin/sudo-elevation
assert_file /usr/local/share/sudo-elevation/manifest
grep -q "install.sh.*--uninstall --purge" /tmp/se-ikeep.log || die "keep must print purge replay"
ok "interactive keep works (no re-prompt loop)"

log "repo purge finishes clean"
"$REPO/install.sh" --user tester --uninstall --purge >/dev/null
assert_no_file /usr/local/bin/sudo-elevation
assert_no_file /etc/sudo-elevation.conf
assert_no_file /usr/local/share/sudo-elevation/manifest
assert_ok visudo -c
assert_ok sudo -V
ok "purge clean"
