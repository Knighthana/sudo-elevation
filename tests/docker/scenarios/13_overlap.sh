#!/bin/bash
# Overlapping leases: the first lease's scheduled restore must be ignored
# after a newer lease replaces it (epoch guard).
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se

log "start a short lease, then immediately replace it with a longer one"
set_ui 0.2 testpass # 12 seconds
as_tester /usr/local/bin/sudo-elevation request --for 12s --reason "overlap old" >/dev/null
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=0.2"

set_ui 0.5 testpass # 30 seconds
as_tester /usr/local/bin/sudo-elevation request --for 30s --reason "overlap new" >/dev/null
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=0.5"

log "wait past the first lease expiry; stale restore must not downgrade"
sleep 15
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=0.5"
assert_ok as_tester sudo -n true
assert_contains /var/log/sudo-elevation.log "restore-skip"
ok "stale restore skipped"

log "lock cleans up the replacement lease"
as_tester /usr/local/bin/sudo-elevation lock >/dev/null
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=15"
assert_no_file /run/sudo-elevation/tester.lease
if as_tester sudo -n true >/dev/null 2>&1; then
	die "cache survived lock"
fi
ok "overlap scenario complete"
