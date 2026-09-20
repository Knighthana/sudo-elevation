#!/bin/bash
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se

log "terminal/headless grant path (no request dialog, just password)"
set_ui 15 testpass
if ! as_tester /usr/local/bin/sudo-elevation grant --for 5m --reason "headless grant" >/tmp/se-grant.log 2>&1; then
	cat /tmp/se-grant.log
	die "headless grant failed"
fi
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=5"
assert_file /run/sudo-elevation/tester.lease
assert_contains /run/sudo-elevation/tester.lease "reason=headless grant"
assert_ok as_tester sudo -n true
assert_contains /var/log/sudo-elevation.log "grant user=tester minutes=5"
