#!/bin/bash
# Multi-user / multi-tenant boundaries: a second account must not be able to
# reach another account's sudo window, lease or policy, and a user-channel
# install must not take over machine-global state.
set -euo pipefail
. /src/tests/docker/lib.sh

GRANT=/usr/local/libexec/sudo-elevation/grant
RESTORE=/usr/local/libexec/sudo-elevation/restore

setup_user
# A second account, so "may only act on itself" has something to be tested
# against. Not in the sudo group: tester is our only sudo caller.
id bob >/dev/null 2>&1 || {
	useradd -m -s /bin/bash bob
	echo 'bob:bobpass' | chpasswd
}
install_se

log "grant refuses to act on another account when reached through sudo"
set_ui 15 testpass
# Warm the timestamp so the assertion is about our check, not about auth.
as_tester sudo -n true >/dev/null 2>&1 || as_tester sudo -A true >/dev/null
out=$(as_tester sudo -n "$GRANT" --user bob --minutes 30 2>&1) \
	&& die "grant --user bob via sudo unexpectedly succeeded: $out"
grep -qF 'refusing --user bob' <<<"$out" || die "no refusal message: $out"
assert_no_file /etc/sudoers.d/90-sudo-elevation-bob
ok "cross-user grant refused, bob's sudoers untouched"

log "grant still works for the invoking user itself"
as_tester sudo -n "$GRANT" --user tester --minutes 5 >/dev/null 2>&1
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=5"
assert_file /run/sudo-elevation/tester.lease
ok "own-account grant unaffected by the boundary check"

log "restore refuses to act on another account when reached through sudo"
as_tester sudo -n "$GRANT" --user bob --minutes 30 >/dev/null 2>&1 && true
out=$(as_tester sudo -n "$RESTORE" --user bob --force 2>&1) \
	&& die "restore --user bob via sudo unexpectedly succeeded: $out"
grep -qF 'refusing --user bob' <<<"$out" || die "no refusal message: $out"
assert_no_file /run/sudo-elevation/bob.lease
ok "cross-user restore refused"

log "root acting on another account is still allowed (direct and via sudo)"
"$GRANT" --user bob --minutes 3 >/dev/null 2>&1
assert_contains /etc/sudoers.d/90-sudo-elevation-bob "timestamp_timeout=3"
"$RESTORE" --user bob --force >/dev/null 2>&1
assert_contains /etc/sudoers.d/90-sudo-elevation-bob "timestamp_timeout=15"
sudo -n "$GRANT" --user bob --minutes 4 >/dev/null 2>&1 \
	|| die "root using sudo to target another account was refused"
assert_contains /etc/sudoers.d/90-sudo-elevation-bob "timestamp_timeout=4"
"$RESTORE" --user bob --force >/dev/null 2>&1
ok "explicit root action still allowed"

log "grant refuses a config file owned by somebody else"
printf 'MAX_MINUTES=525600\n' >/tmp/se-evil.conf
chown bob /tmp/se-evil.conf
out=$(as_tester sudo -n "$GRANT" --user tester --minutes 5 --config-file /tmp/se-evil.conf 2>&1) \
	&& die "grant accepted a third-party config: $out"
grep -qF 'refusing to load' <<<"$out" || die "no refusal message: $out"
ok "third-party config refused"

log "grant refuses a group/world-writable config even when root-owned"
printf 'MAX_MINUTES=525600\n' >/tmp/se-ww.conf
chown root:root /tmp/se-ww.conf
chmod 0666 /tmp/se-ww.conf
out=$(as_tester sudo -n "$GRANT" --user tester --minutes 5 --config-file /tmp/se-ww.conf 2>&1) \
	&& die "grant accepted a world-writable config: $out"
grep -qF 'refusing to load' <<<"$out" || die "no refusal message: $out"
ok "world-writable config refused"

log "grant accepts the machine config and the caller's own config"
chmod 0644 /tmp/se-evil.conf
chown tester /tmp/se-evil.conf
as_tester sudo -n "$GRANT" --user tester --minutes 5 --config-file /tmp/se-evil.conf >/dev/null 2>&1
ok "caller-owned config accepted"
as_tester sudo -n "$GRANT" --user tester --minutes 5 --config-file /etc/sudo-elevation.conf >/dev/null 2>&1
ok "machine config accepted"

log "user install never claims the machine-global Path askpass"
assert_contains /etc/sudo.conf "Path askpass /usr/local/bin/sudo-askpass"
"$REPO/install.sh" --user-install --user tester --test-hooks >/tmp/se-ui-install.log 2>&1
assert_contains /etc/sudo.conf "Path askpass /usr/local/bin/sudo-askpass"
assert_not_contains /etc/sudo.conf "/home/tester/.local/bin/sudo-askpass"
assert_no_file /home/tester/.config/sudo-elevation/env.bak
ok "system install's block survived, no hijack added"

log "an older install's hijacking block is cleaned up, system one is not"
{
	printf '# >>> sudo-elevation >>>\n'
	printf 'Path askpass /home/tester/.local/bin/sudo-askpass\n'
	printf '# <<< sudo-elevation <<<\n'
} >/etc/sudo.conf
"$REPO/install.sh" --user-install --user tester --test-hooks >/tmp/se-ui-install2.log 2>&1
assert_not_contains /etc/sudo.conf "sudo-askpass"
grep -qF "removed our machine-global 'Path askpass'" /tmp/se-ui-install2.log \
	|| die "no cleanup notice printed: $(cat /tmp/se-ui-install2.log)"
compgen -G '/etc/sudo.conf.bak.*' >/dev/null || die "cleanup did not back up sudo.conf"
ok "hijack removed with a backup"

log "user-channel libexec stays root-owned (grant runs as root via sudo)"
L=/home/tester/.local/libexec/sudo-elevation
assert_eq "$(stat -c %U "$L/grant")" root "grant owner"
assert_eq "$(stat -c %U "$L/restore")" root "restore owner"
assert_eq "$(stat -c %U "$L/common.sh")" root "common.sh owner"
assert_eq "$(stat -c %U "$L/install.sh")" root "install.sh owner"
# The account that will be judged must not be able to rewrite root-run code.
assert_fail runuser -u tester -- test -w "$L/grant"
ok "tester cannot write the root-run helpers"

log "user-space entry points do belong to the target user"
assert_eq "$(stat -c %U /home/tester/.local/bin/sudo-elevation)" tester "cli owner"
assert_eq "$(stat -c %U /home/tester/.local/bin/sudo-askpass)" tester "askpass owner"
ok "cli+askpass owned by tester"

log "an older install's chown -R is reclaimed on the next install"
# What the old chown -R left behind: the whole tree user-owned, including a
# stale helper this version no longer manages (so only the reclaim can fix it).
chown -R tester "$L"
: >"$L/stale-helper"
chown tester "$L/stale-helper"
"$REPO/install.sh" --user-install --user tester --test-hooks >/tmp/se-ui-install3.log 2>&1
assert_eq "$(stat -c %U "$L/grant")" root "grant owner after reinstall"
assert_eq "$(stat -c %U "$L/stale-helper")" root "stale helper reclaimed"
grep -qF 'reclaiming root ownership' /tmp/se-ui-install3.log \
	|| die "no reclaim notice: $(cat /tmp/se-ui-install3.log)"
grep -qF 'runs as root via sudo' /tmp/se-ui-install3.log \
	|| die "reclaim did not explain why: $(cat /tmp/se-ui-install3.log)"
ok "root ownership reclaimed with a warning"

log "the CLI supplies its own askpass helper when the caller set none"
# Which helper sudo ends up running is the whole point, so mark ours and let it
# delegate to the hook-enabled system helper. sudo-elevation runs it through
# `sudo -A`, and SUDO_ASKPASS is what lets a user-channel helper be found at
# all: `Path askpass` in sudo.conf is machine-global and, since the hijack fix,
# a user install never writes it.
cat >/home/tester/.local/bin/sudo-askpass <<'EOF'
#!/bin/bash
echo "SE-USER-ASKPASS-INVOKED" >&2
export SUDO_ELEVATION_UI=fake
SUDO_ELEVATION_FAKE_CHOICE="$(cat /tmp/se-test-choice 2>/dev/null || echo 15)"
SUDO_ELEVATION_FAKE_PASSWORD="$(cat /tmp/se-test-password 2>/dev/null || echo testpass)"
export SUDO_ELEVATION_FAKE_CHOICE SUDO_ELEVATION_FAKE_PASSWORD
exec /usr/local/bin/sudo-askpass "$@"
EOF
chmod 0755 /home/tester/.local/bin/sudo-askpass
chown tester /home/tester/.local/bin/sudo-askpass
set_ui 15 testpass
out=$(runuser -u tester -- /home/tester/.local/bin/sudo-elevation request --for 15m --reason "fallback askpass" 2>&1) \
	|| { printf '%s\n' "$out"; die "request via the CLI's own askpass fallback failed"; }
grep -qF 'SE-USER-ASKPASS-INVOKED' <<<"$out" \
	|| die "the CLI did not point sudo at its own helper: $out"
assert_contains /run/sudo-elevation/tester.lease "reason=fallback askpass"
ok "request used the CLI-supplied helper with no SUDO_ASKPASS in the env"

log "an explicit SUDO_ASKPASS still wins over the fallback"
# A caller-provided helper that does not print the marker: if the fallback
# overrode it, the marker would show up and this request would use ours.
cat >/tmp/se-other-askpass <<'EOF'
#!/bin/bash
export SUDO_ELEVATION_UI=fake
SUDO_ELEVATION_FAKE_CHOICE="$(cat /tmp/se-test-choice 2>/dev/null || echo 12)"
SUDO_ELEVATION_FAKE_PASSWORD="$(cat /tmp/se-test-password 2>/dev/null || echo testpass)"
export SUDO_ELEVATION_FAKE_CHOICE SUDO_ELEVATION_FAKE_PASSWORD
exec /usr/local/bin/sudo-askpass "$@"
EOF
chmod 0755 /tmp/se-other-askpass
set_ui 12 testpass
out=$(runuser -u tester -- env SUDO_ASKPASS=/tmp/se-other-askpass \
	/home/tester/.local/bin/sudo-elevation request --for 12m --reason "explicit askpass" 2>&1) \
	|| { printf '%s\n' "$out"; die "request with an explicit helper failed"; }
grep -qF 'SE-USER-ASKPASS-INVOKED' <<<"$out" \
	&& die "the CLI's fallback overrode an explicit SUDO_ASKPASS: $out"
assert_contains /run/sudo-elevation/tester.lease "reason=explicit askpass"
ok "caller-provided helper respected"

log "a per-account config layer narrows the machine policy, tree-independent"
UCFG=/home/tester/.config/sudo-elevation/config
assert_contains /etc/sudo-elevation.conf "MAX_MINUTES=525600"
mkdir -p "$(dirname "$UCFG")"
printf 'MAX_MINUTES=60\nBASE_MINUTES=5\n' >"$UCFG"
chown -R tester /home/tester/.config/sudo-elevation
# 120 minutes is fine for the host (MAX 525600) but over this account's own cap.
out=$(as_tester sudo -n "$GRANT" --user tester --minutes 120 2>&1) \
	&& die "grant ignored the per-account MAX_MINUTES: $out"
grep -qF 'allowed: 0..60 minutes' <<<"$out" || die "cap not reported: $out"
ok "per-account cap enforced by the root helper"
# And the cap is the user's own, not the host's: 60 must still be grantable.
as_tester sudo -n "$GRANT" --user tester --minutes 60 >/dev/null 2>&1 \
	|| die "grant rejected a duration at the account's own cap"
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=60"
# bob is unaffected: the layer is per account, and bob has no config file.
"$GRANT" --user bob --minutes 120 >/dev/null 2>&1 \
	|| die "another account inherited tester's cap"
"$RESTORE" --user bob --force >/dev/null 2>&1
ok "the cap did not leak to another account"
# The base window is layered too, which the CLI reports.
out=$(runuser -u tester -- /usr/local/bin/sudo-elevation status --porcelain)
grep -qF 'base_minutes=5' <<<"$out" || die "CLI did not use the per-account base window: $out"
ok "per-account base window reaches the CLI"
# Installing must not freeze the account's preference into the machine file.
"$REPO/install.sh" --user tester --test-hooks >/dev/null 2>&1
assert_not_contains /etc/sudo-elevation.conf "MAX_MINUTES=60"
assert_contains /etc/sudo-elevation.conf "MAX_MINUTES=525600"
rm -f "$UCFG"
ok "install left the machine policy alone"

log "policy is tree-independent: the system CLI honours the same account layer"
out=$(env -u XDG_CONFIG_HOME HOME=/home/tester bash -c \
	'SUDO_ELEVATION_CONFIG=/etc/sudo-elevation.conf . /usr/local/libexec/sudo-elevation/common.sh; se_load_config tester; printf "base=%s src=%s\n" "$BASE_MINUTES" "$BASE_MINUTES_SRC"')
grep -qF "base=5 src=user:$UCFG" <<<"$out" \
	|| die "machine tree ignored the account layer: $out"
ok "same effective policy from either tree"

log "teardown: end every lease and both trees, so no restore sleeper lingers"
runuser -u tester -- /home/tester/.local/bin/sudo-elevation lock >/dev/null 2>&1 || true
"$REPO/install.sh" --user-install --user tester --uninstall --keep >/dev/null 2>&1 || true
"$REPO/install.sh" --user tester --uninstall --keep >/dev/null 2>&1 || true
assert_no_file /run/sudo-elevation/tester.lease
ok "teardown clean"

echo "19_multiuser: all checks passed"
