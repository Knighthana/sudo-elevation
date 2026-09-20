#!/bin/bash
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se

log "until-lock lease"
set_ui -1 testpass
if ! as_tester /usr/local/bin/sudo-elevation request --for until-lock --reason "infinite test" >/tmp/se-inf.log 2>&1; then
	cat /tmp/se-inf.log
	die "request failed"
fi
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=-1"
assert_contains /run/sudo-elevation/tester.lease "restore=none"
assert_ok as_tester sudo -n true

log "status reports the lease"
out=$(as_tester /usr/local/bin/sudo-elevation status)
grep -qF '活动租约' <<<"$out" || die "status did not report a lease: $out"
grep -qF 'infinite test' <<<"$out" || die "status missing reason: $out"
ok "status shows lease"

log "lock revokes the lease"
as_tester /usr/local/bin/sudo-elevation lock >/dev/null
wait_for_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=15" 10 \
	|| die "lock did not restore base"
assert_no_file /run/sudo-elevation/tester.lease
if as_tester sudo -n true >/dev/null 2>&1; then
	die "sudo cache survived lock"
fi
ok "lock cleared cache and restored base"
