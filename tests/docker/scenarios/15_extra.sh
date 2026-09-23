#!/bin/bash
# 0.1.4 regression: P1 lock until-lock residual + P2 items + porcelain.
# Fast, no long sleeps (uses synthetic leases where possible).
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se

log "X01 invalid durations rejected"
assert_fail /usr/local/bin/sudo-elevation parse garbage
assert_fail /usr/local/bin/sudo-elevation parse ""
assert_fail /usr/local/bin/sudo-elevation parse 1x
if /usr/local/libexec/sudo-elevation/grant --user tester --minutes 9999999 >/dev/null 2>&1; then die "over-MAX accepted"; fi
ok "over-MAX rejected"
if runuser -u tester -- /usr/local/bin/sudo-elevation request --for garbage --reason x >/dev/null 2>&1; then die "request garbage accepted"; fi
ok "request garbage rejected"

log "X02 reason sanitize + truncation hint"
long=$(head -c 500 /dev/zero | tr '\0' 'y')
/usr/local/libexec/sudo-elevation/grant --user tester --minutes 5 --reason "$long" 2>/tmp/se-trunc.err >/dev/null
assert_contains /tmp/se-trunc.err "截断"
reason=$(sed -n 's/^reason=//p' /run/sudo-elevation/tester.lease)
[ "${#reason}" = 200 ] || die "reason len ${#reason} want 200"
ok "truncated to 200 with hint"
/usr/local/libexec/sudo-elevation/restore --user tester --force >/dev/null || true

log "X04 status --porcelain"
/usr/local/libexec/sudo-elevation/grant --user tester --minutes 5 --reason "porc" >/dev/null
out=$(runuser -u tester -- /usr/local/bin/sudo-elevation status --porcelain)
grep -qF 'active=1' <<<"$out" || die "porcelain active: $out"
grep -qF 'minutes=5' <<<"$out" || die "porcelain minutes: $out"
rem=$(printf '%s\n' "$out" | sed -n 's/^remaining_s=//p')
case "$rem" in ''|*[!0-9]*) die "bad remaining_s: $rem" ;; esac
[ "$rem" -gt 0 ] || die "remaining_s not positive: $rem"
ok "porcelain active remaining_s=$rem"
/usr/local/libexec/sudo-elevation/grant --user tester --minutes -1 --reason "p-until" >/dev/null
out=$(runuser -u tester -- /usr/local/bin/sudo-elevation status --porcelain)
grep -qF 'remaining_s=-1' <<<"$out" || die "until porcelain: $out"
ok "porcelain until-lock"
/usr/local/libexec/sudo-elevation/restore --user tester --force >/dev/null
out=$(runuser -u tester -- /usr/local/bin/sudo-elevation status --porcelain)
grep -qF 'active=0' <<<"$out" || die "porcelain inactive: $out"
ok "porcelain inactive"

log "X06 production askpass fail-closed"
install_se_plain
if grep -q 'SUDO_ELEVATION_FAKE_PASSWORD' /usr/local/bin/sudo-askpass; then die "hooks in plain"; fi
ok "plain strips hooks"
if runuser -u tester -- env SUDO_ELEVATION_UI=fake SUDO_ELEVATION_FAKE_PASSWORD=testpass timeout 10 sudo -A id -u >/tmp/se-fake.log 2>&1; then die "fake worked in prod"; fi
ok "fake fail-closed"
install_se

log "X08 cancel preserves timestamp"
set_ui 15 testpass
assert_ok as_tester sudo -A true
assert_ok as_tester sudo -n true
if runuser -u tester -- env SUDO_ASKPASS=/bin/false timeout 15 sudo -k -A id -u >/tmp/se-cancel.log 2>&1; then die "false askpass succeeded"; fi
ok "cancel fails"
assert_ok as_tester sudo -n true
assert_no_file /run/sudo-elevation/tester.lease

log "C1 P1: until-lock + sudo -k + lock must fail loudly (no tty)"
set_ui -1 testpass
as_tester /usr/local/bin/sudo-elevation request --for until-lock --reason "c1" >/dev/null
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=-1"
runuser -u tester -- sudo -k
if runuser -u tester -- /usr/local/bin/sudo-elevation lock >/tmp/se-lock.log 2>&1; then die "lock should fail on -1 residual without tty"; fi
ok "lock exits non-zero on -1 residual"
grep -q 'until-lock' /tmp/se-lock.log || { cat /tmp/se-lock.log; die "missing until-lock hint"; }
ok "lock warns until-lock"
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=-1"
ok "residual -1 preserved for tty fix (not silently claimed)"
/usr/local/libexec/sudo-elevation/restore --user tester --force >/dev/null

log "C2 strict config rejects 15.5.5"
printf 'BASE_MINUTES=15.5.5\n' > /tmp/c.conf
got=$(bash -c '. /usr/local/libexec/sudo-elevation/common.sh; SUDO_ELEVATION_CONFIG=/tmp/c.conf se_load_config; printf "%s" "$BASE_MINUTES"')
assert_eq "$got" 15 "bad BASE ignored"
printf 'BASE_MINUTES=30\n' > /tmp/c.conf
got=$(bash -c '. /usr/local/libexec/sudo-elevation/common.sh; SUDO_ELEVATION_CONFIG=/tmp/c.conf se_load_config; printf "%s" "$BASE_MINUTES"')
assert_eq "$got" 30 "good BASE accepted"
