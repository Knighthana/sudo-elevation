#!/bin/bash
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se

log "lease dialog argv is built with the requested duration pre-selected"
set_ui 15 testpass
rc=0
out=$(runuser -u tester -- env SUDO_ASKPASS="$REPO/tests/docker/fake-askpass-print" \
	/usr/local/bin/sudo-elevation request --for 2h --reason "ui print" 2>&1) || rc=$?
[ "$rc" != 0 ] || die "print UI should not succeed"
grep -qF -- '--add-combo' <<<"$out" || die "no combo in dialog: $out"
grep -qF -- '--add-password' <<<"$out" || die "no password field: $out"
grep -qF -- '--add-entry' <<<"$out" || die "no custom duration field: $out"
grep -qF -- '2 小时（agent 请求）' <<<"$out" || die "requested duration not pre-selected: $out"
grep -qF -- 'ui print' <<<"$out" || die "reason not shown: $out"
ok "lease dialog argv verified"
