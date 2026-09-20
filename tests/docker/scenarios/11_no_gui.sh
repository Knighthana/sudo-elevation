#!/bin/bash
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se

log "no GUI + no tty fails fast with a clear message"
set_ui 15 testpass
printf 'testpass\n' > /tmp/se-test-password
chmod 0644 /tmp/se-test-password
if runuser -u tester -- timeout 15 sudo -A id -u >/tmp/se-nogui.log 2>&1; then
	die "sudo -A unexpectedly succeeded without a UI"
fi
grep -q '没有可用的图形界面' /tmp/se-nogui.log \
	|| { cat /tmp/se-nogui.log; die "missing no-GUI error message"; }
ok "clean failure without GUI"

log "no request file: simple password dialog path is used"
out=$(runuser -u tester -- env SUDO_ASKPASS="$REPO/tests/docker/fake-askpass-print" timeout 15 sudo -A id -u 2>&1 || true)
grep -qF -- '--password' <<<"$out" || die "simple dialog not used: $out"
grep -qF -- '窗口' <<<"$out" || die "base window not shown: $out"
ok "simple dialog argv verified"
