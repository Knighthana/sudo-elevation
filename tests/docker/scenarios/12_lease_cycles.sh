#!/bin/bash
# Repeated short lease cycles: grant -> use -> expiry -> restore.
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se

CYCLES=${CYCLES:-5}
for i in $(seq 1 "$CYCLES"); do
	log "lease cycle $i/$CYCLES"
	set_ui 0.1 testpass # 6 seconds
	if ! as_tester /usr/local/bin/sudo-elevation request --for 6s --reason "cycle $i" >/tmp/se-cycle.log 2>&1; then
		cat /tmp/se-cycle.log
		die "request failed in cycle $i"
	fi
	assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=0.1"
	assert_ok as_tester sudo -n true
	sleep 8
	if as_tester sudo -n true >/dev/null 2>&1; then
		die "cache leaked in cycle $i"
	fi
	wait_for_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=15" 20 \
		|| die "restore did not happen in cycle $i"
done

assert_eq "$(grep -c 'grant user=tester minutes=0.1' /var/log/sudo-elevation.log)" "$CYCLES" "grant audit lines"
assert_eq "$(grep -c 'restore user=tester' /var/log/sudo-elevation.log)" "$CYCLES" "restore audit lines"
ok "all $CYCLES cycles completed without cache leaks"
