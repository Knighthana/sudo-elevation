#!/bin/bash
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se

log "one-shot approval (0 minutes) leaves no cache"
set_ui 0 testpass
if ! as_tester /usr/local/bin/sudo-elevation request --for 0 --reason "one-shot test" >/tmp/se-once.log 2>&1; then
	cat /tmp/se-once.log
	die "request failed"
fi
wait_for_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=15" 20 \
	|| die "restore to base did not happen"
ok "config restored to base"
if as_tester sudo -n true >/dev/null 2>&1; then
	die "one-shot approval leaked a cached timestamp"
fi
ok "no sudo cache after one-shot approval"
