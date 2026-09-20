#!/bin/bash
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se

log "askpass authentication with correct password"
set_ui 15 testpass
out=$(as_tester sudo -A id -u)
assert_eq "$out" 0 "askpass auth returns root"
assert_ok as_tester sudo -n true

log "wrong password is rejected"
runuser -u tester -- sudo -k
printf '%s\n' wrongpass > /tmp/se-test-password
chmod 0644 /tmp/se-test-password
if as_tester sudo -A id -u >/tmp/se-wrong.log 2>&1; then
	cat /tmp/se-wrong.log
	die "wrong password was accepted"
fi
ok "wrong password rejected"
assert_no_file /run/sudo-elevation/tester.lease
