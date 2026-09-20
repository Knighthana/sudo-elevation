#!/bin/bash
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se

log "stale restore job must not clobber a newer lease"
/usr/local/libexec/sudo-elevation/grant --user tester --minutes 5 >/dev/null
epoch1=$(sed -n 's/^epoch=//p' /run/sudo-elevation/tester.lease)
[ -n "$epoch1" ] || die "no epoch in lease"
sleep 1
/usr/local/libexec/sudo-elevation/grant --user tester --minutes 10 >/dev/null
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=10"

/usr/local/libexec/sudo-elevation/restore --user tester --epoch "$epoch1" >/dev/null
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=10"
ok "stale restore was ignored"

log "forced restore returns to base"
/usr/local/libexec/sudo-elevation/restore --user tester --force >/dev/null
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=15"
assert_no_file /run/sudo-elevation/tester.lease
