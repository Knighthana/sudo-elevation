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
grep -qF -- '--radiolist' <<<"$out" || die "no radio list in dialog: $out"
grep -qF -- '--print-column=2' <<<"$out" || die "wrong print column: $out"
grep -qF -- '--ok-label="继续"' <<<"$out" || die "no continue button: $out"
grep -qF -- 'zenity --entry' <<<"$out" || die "no custom duration dialog: $out"
grep -qF -- 'zenity --password' <<<"$out" || die "no separate password dialog: $out"
grep -qF -- '2 小时（agent 请求）' <<<"$out" || die "requested duration not pre-selected: $out"
grep -qF -- 'ui print' <<<"$out" || die "reason not shown: $out"
ok "lease dialog argv verified"
