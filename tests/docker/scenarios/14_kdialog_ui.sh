#!/bin/bash
# kdialog lease dialog: argv verification via a PATH stub (no KDE needed).
# The wrapper forces SUDO_ELEVATION_UI=kdialog and points askpass at the stub,
# mirroring fake-askpass-print for zenity.
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se

log "kdialog radiolist dialog is built with the requested duration pre-selected"
rc=0
out=$(runuser -u tester -- env SUDO_ASKPASS="$REPO/tests/docker/fake-askpass-kdialog" \
	/usr/local/bin/sudo-elevation request --for 2h --reason "kdialog ui" 2>&1) || rc=$?
if [ "$rc" != 0 ]; then
	printf '%s\n' "$out"
	die "request via kdialog stub failed (rc=$rc)"
fi

logfile=/tmp/se-kdialog.log
assert_file "$logfile"
assert_contains "$logfile" "--radiolist"
assert_contains "$logfile" "2 小时（agent 请求）"
assert_contains "$logfile" "--password"
assert_contains "$logfile" "手动输入…"
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=120"
log_line=$(grep -n -- '--radiolist' "$logfile" | head -1 | cut -d: -f1)
pass_line=$(grep -n -- '--password' "$logfile" | head -1 | cut -d: -f1)
[ "$log_line" -lt "$pass_line" ] || die "radiolist must come before password dialog"
ok "kdialog dialog flow verified"
