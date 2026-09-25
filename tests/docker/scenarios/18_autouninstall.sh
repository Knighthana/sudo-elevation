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

log "manifest records full layout keys"
for k in VERSION BASE_MINUTES MAX_MINUTES USERS INSTALL_MODE SYSTEM SUDO_CONF_BAK PREFIX \
	BINDIR LIBEXECDIR SHAREDIR CONFIG SUDO_CONF SUDOERS_DIR RUNTIME_DIR LOG SKILL_DIR; do
	grep -q "^$k=" /usr/local/share/sudo-elevation/manifest || die "manifest lacks $k"
done
grep -q "^PREFIX=$" /usr/local/share/sudo-elevation/manifest || die "system manifest PREFIX should be empty"
ok "manifest full keys"

log "bare uninstall without tty only lists (exit 2, nothing removed)"
rc=0
"$REPO/install.sh" --uninstall </dev/null >/tmp/se-list.log 2>&1 || rc=$?
[ "$rc" -eq 2 ] || die "list-only should exit 2, got $rc"
grep -q "nothing was removed" /tmp/se-list.log || die "list must state nothing removed"
grep -q "^    keep: " /tmp/se-list.log || die "list must print keep replay"
grep -q "^    purge: " /tmp/se-list.log || die "list must print purge replay"
grep -qF -- "--user 'tester'" /tmp/se-list.log || die "replay must carry --user"
assert_file /usr/local/bin/sudo-elevation
ok "list-only safe"

log "automatic mode fails fast without a timestamp (keep and purge)"
runuser -u tester -- sudo -k || true
for flag in --keep --purge; do
	rc=0
	runuser -u tester -- /usr/local/bin/sudo-elevation uninstall "$flag" >/tmp/se-nots.log 2>&1 || rc=$?
	[ "$rc" -eq 1 ] || die "fail-fast $flag should exit 1, got $rc"
	grep -q "no valid sudo timestamp" /tmp/se-nots.log || die "fail-fast message missing"
done
assert_file /usr/local/bin/sudo-elevation
assert_file /etc/sudo-elevation.conf
assert_contains /run/sudo-elevation/tester.lease "reason=auto test"
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
assert_no_file /run/sudo-elevation/tester.lease
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=15"
if as_tester sudo -n true >/dev/null 2>&1; then
	die "cache survived automatic keep"
fi
grep -q "install.sh.*--uninstall --purge" /tmp/se-akeep.log || die "keep must print purge replay"
grep -qF -- "--user 'tester'" /tmp/se-akeep.log || die "replay must carry --user"
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

log "interactive EOF on a pty skips without input"
install_se >/dev/null
set_ui 15 testpass
as_tester /usr/local/bin/sudo-elevation request --for 15m --reason "auto test" >/dev/null
script -qec "$REPO/install.sh --uninstall" /dev/null >/tmp/se-ieof.log 2>&1 </dev/null || true
grep -q "no input; skipping" /tmp/se-ieof.log || die "EOF skip message missing"
grep -q "skipped=1" /tmp/se-ieof.log || die "EOF skip summary missing"
assert_file /usr/local/bin/sudo-elevation
ok "EOF skip safe"

log "interactive purge on a pty removes config too"
printf 'p\n' | script -qec "$REPO/install.sh --uninstall" /dev/null >/tmp/se-ipurge.log 2>&1 || true
grep -q "purged=1" /tmp/se-ipurge.log || die "purge summary missing"
assert_no_file /usr/local/bin/sudo-elevation
assert_no_file /etc/sudo-elevation.conf
assert_no_file /usr/local/share/sudo-elevation/manifest
ok "interactive purge works"

log "prefix mismatch warns and only touches the requested tree"
install_se >/dev/null
mkdir -p /tmp/pxroot
"$REPO/install.sh" --prefix /tmp/pxroot --user tester --skill-dir /tmp/pxskill >/dev/null
cp -r /tmp/pxroot /tmp/pxother
"$REPO/install.sh" --prefix /tmp/pxother --user tester --skill-dir /tmp/pxskill --uninstall --keep >/tmp/se-mismatch.log 2>&1 \
	|| die "mismatched uninstall failed"
grep -q "manifest PREFIX=/tmp/pxroot differs" /tmp/se-mismatch.log \
	|| die "PREFIX mismatch warning missing"
assert_file /tmp/pxroot/usr/local/bin/sudo-elevation
assert_no_file /tmp/pxother/usr/local/bin/sudo-elevation
rm -rf /tmp/pxroot /tmp/pxother /tmp/pxskill
ok "prefix mismatch safe"

log "leaked PREFIX does not hijack user trees"
"$REPO/install.sh" --user-install --user tester --test-hooks >/dev/null
# home-relative chains made by earlier system installs must belong to the
# user, or later user-owned installs fail on permissions
[ "$(stat -c %U /home/tester/.config)" = tester ] || die "root-owned .config chain"
[ "$(stat -c %U /home/tester/.config/opencode)" = tester ] || die "root-owned opencode chain"
set_ui 15 testpass
runuser -u tester -- env SUDO_ASKPASS="$ASKPASS" sudo -A true >/dev/null
if ! runuser -u tester -- env HOME=/home/tester SUDO_ELEVATION_PREFIX=/tmp/stale SUDO_ASKPASS="$ASKPASS" \
	/home/tester/.local/bin/sudo-elevation uninstall --keep >/tmp/se-leak.log 2>&1; then
	cat /tmp/se-leak.log
	die "leaked-PREFIX uninstall failed"
fi
assert_no_file /home/tester/.local/bin/sudo-elevation
assert_file /usr/local/bin/sudo-elevation
ok "user layout wins over leaked PREFIX"

log "repo purge finishes clean"
"$REPO/install.sh" --user tester --uninstall --purge >/dev/null
assert_no_file /usr/local/bin/sudo-elevation
assert_no_file /etc/sudo-elevation.conf
assert_no_file /usr/local/share/sudo-elevation/manifest
assert_ok visudo -c
assert_ok sudo -V
ok "purge clean"
