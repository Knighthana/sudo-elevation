#!/bin/bash
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user

log "foreign Path askpass is refused"
printf 'Path askpass /bin/false\n' >> /etc/sudo.conf
if "$REPO/install.sh" --user tester >/tmp/se-conflict.log 2>&1; then
	die "install should have refused the foreign askpass"
fi
grep -q 'different askpass helper' /tmp/se-conflict.log \
	|| { cat /tmp/se-conflict.log; die "missing conflict message"; }
ok "install refused without --force"
assert_no_file /usr/local/bin/sudo-askpass

log "--force takes over"
"$REPO/install.sh" --user tester --force
assert_contains /etc/sudo.conf "Path askpass /bin/false"
assert_contains /etc/sudo.conf "# >>> sudo-elevation >>>"
assert_contains /etc/sudo.conf "Path askpass /usr/local/bin/sudo-askpass"
assert_ok visudo -c
assert_ok sudo -V
