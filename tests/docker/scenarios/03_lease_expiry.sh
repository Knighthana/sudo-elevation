#!/bin/bash
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se

log "warm the base cache first (request must still force the dialog)"
set_ui 15 testpass
assert_ok as_tester sudo -A true

log "request a 24s lease (choice 0.4 minutes)"
set_ui 0.4 testpass
if ! as_tester /usr/local/bin/sudo-elevation request --for 24s --reason "docker lease expiry test" >/tmp/se-request.log 2>&1; then
	cat /tmp/se-request.log
	die "request failed"
fi
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=0.4"
	assert_file /run/sudo-elevation/tester.lease
	assert_mode /run/sudo-elevation/tester.lease 600
	assert_eq "$(stat -c %U /run/sudo-elevation/tester.lease)" tester "lease owned by user"
	assert_contains /run/sudo-elevation/tester.lease "minutes=0.4"
assert_contains /run/sudo-elevation/tester.lease "reason=docker lease expiry test"
assert_contains /run/sudo-elevation/tester.lease "restore=setsid"
assert_contains /var/log/sudo-elevation.log "grant user=tester minutes=0.4"

log "sudo -n works during the lease"
assert_ok as_tester sudo -n true

log "lease expiry enforces re-authentication"
sleep 28
if as_tester sudo -n true >/dev/null 2>&1; then
	die "sudo -n still works after lease expiry"
fi
ok "sudo -n denied after expiry"

log "scheduled restore returns sudoers to base"
wait_for_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=15" 20 \
	|| die "restore to base did not happen"
ok "base window restored"
assert_no_file /run/sudo-elevation/tester.lease
assert_contains /var/log/sudo-elevation.log "restore user=tester"
