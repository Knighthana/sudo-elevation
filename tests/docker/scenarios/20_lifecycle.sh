#!/bin/bash
# Uninstall lifecycle on a shared host: one account's uninstall must never
# dismantle the install another account is still using.
set -euo pipefail
. /src/tests/docker/lib.sh

GRANT=/usr/local/libexec/sudo-elevation/grant

setup_user
for u in alice bob; do
	id "$u" >/dev/null 2>&1 || {
		useradd -m -s /bin/bash "$u"
		echo "$u:${u}pass" | chpasswd
	}
done

log "two accounts install into the same system tree"
install_se --user alice
install_se --user bob
assert_file /etc/sudoers.d/90-sudo-elevation-alice
assert_file /etc/sudoers.d/90-sudo-elevation-bob
grep -q 'USERS=alice,bob' /usr/local/share/sudo-elevation/manifest \
	|| die "manifest does not list both: $(grep '^USERS=' /usr/local/share/sudo-elevation/manifest)"
ok "both drop-ins and one manifest"

log "both hold a live lease"
"$GRANT" --user alice --minutes 30 >/dev/null 2>&1
"$GRANT" --user bob --minutes 30 >/dev/null 2>&1
assert_file /run/sudo-elevation/alice.lease
assert_file /run/sudo-elevation/bob.lease
ok "two independent leases"

log "alice purges: only alice's state goes"
"$REPO/install.sh" --user alice --uninstall --purge >/tmp/se-alice-purge.log 2>&1
assert_no_file /etc/sudoers.d/90-sudo-elevation-alice
assert_no_file /run/sudo-elevation/alice.lease
ok "alice's own state removed"

log "bob is untouched: drop-in, lease and window intact"
assert_file /etc/sudoers.d/90-sudo-elevation-bob
assert_contains /etc/sudoers.d/90-sudo-elevation-bob "timestamp_timeout=30"
assert_file /run/sudo-elevation/bob.lease
assert_contains /run/sudo-elevation/bob.lease "user=bob"
ok "bob's lease survived another account's uninstall"

log "the shared payload survives while bob still needs it"
assert_file /usr/local/bin/sudo-elevation
assert_file /usr/local/bin/sudo-askpass
assert_file /usr/local/libexec/sudo-elevation/grant
assert_contains /etc/sudo.conf "Path askpass /usr/local/bin/sudo-askpass"
assert_file /etc/sudo-elevation.conf
assert_file /usr/local/share/sudo-elevation/manifest
ok "machine-wide files kept"

log "the manifest stops claiming the removed account"
grep -q 'USERS=bob' /usr/local/share/sudo-elevation/manifest \
	|| die "manifest still lists alice: $(grep '^USERS=' /usr/local/share/sudo-elevation/manifest)"
grep -q 'alice' /usr/local/share/sudo-elevation/manifest \
	&& die "alice still present in the manifest"
ok "USERS=bob only (so the host can still be fully cleaned later)"

log "bob's tree still works after alice's uninstall"
runuser -u bob -- /usr/local/bin/sudo-elevation status >/dev/null 2>&1
ok "bob's CLI runs"

log "the last account out takes the shared payload with it"
"$REPO/install.sh" --user bob --uninstall --purge >/tmp/se-bob-purge.log 2>&1
assert_no_file /etc/sudoers.d/90-sudo-elevation-bob
assert_no_file /run/sudo-elevation/bob.lease
assert_no_file /usr/local/bin/sudo-elevation
assert_no_file /usr/local/bin/sudo-askpass
assert_no_file /usr/local/libexec/sudo-elevation/grant
assert_no_file /usr/local/share/sudo-elevation/manifest
assert_not_contains /etc/sudo.conf "# >>> sudo-elevation >>>"
assert_no_file /etc/sudo-elevation.conf
assert_ok visudo -c
ok "host fully cleaned by the last account"

log "--all-users is the explicit opt-in for the whole manifest"
install_se --user alice
install_se --user bob
"$GRANT" --user alice --minutes 30 >/dev/null 2>&1
"$GRANT" --user bob --minutes 30 >/dev/null 2>&1
"$REPO/install.sh" --user alice --uninstall --purge --all-users >/tmp/se-all-users.log 2>&1
assert_no_file /etc/sudoers.d/90-sudo-elevation-alice
assert_no_file /etc/sudoers.d/90-sudo-elevation-bob
assert_no_file /run/sudo-elevation/alice.lease
assert_no_file /run/sudo-elevation/bob.lease
assert_no_file /usr/local/bin/sudo-elevation
assert_no_file /usr/local/share/sudo-elevation/manifest
ok "every account in the manifest was acted on"

log "a dotted account name no longer shares files with its underscore twin"
# The old slug mapping sent `a.b` and `a_b` to the same sudoers drop-in and the
# same lease file, so either one could end the other's window.
useradd -m -s /bin/bash 'a.b' 2>/dev/null || true
useradd -m -s /bin/bash a_b 2>/dev/null || true
id 'a.b' >/dev/null 2>&1 || die "could not create a.b"
id a_b >/dev/null 2>&1 || die "could not create a_b"
install_se --user 'a.b'
install_se --user a_b
assert_file /etc/sudoers.d/90-sudo-elevation-a__2e__b
assert_file /etc/sudoers.d/90-sudo-elevation-a__5f__b
ok "distinct drop-ins"

"$GRANT" --user 'a.b' --minutes 30 >/dev/null 2>&1
"$GRANT" --user a_b --minutes 45 >/dev/null 2>&1
assert_contains /etc/sudoers.d/90-sudo-elevation-a__2e__b "timestamp_timeout=30"
assert_contains /etc/sudoers.d/90-sudo-elevation-a__5f__b "timestamp_timeout=45"
# a.b's lease must not have clobbered a_b's.
assert_contains /run/sudo-elevation/a__2e__b.lease "minutes=30"
assert_contains /run/sudo-elevation/a__5f__b.lease "minutes=45"
# And ending one must not end the other.
"$REPO/install.sh" --user 'a.b' --uninstall --purge --all-users >/dev/null 2>&1
"$REPO/install.sh" --user a_b --uninstall --purge --all-users >/dev/null 2>&1
ok "distinct leases, no cross-talk"

log "teardown: remove the extra accounts' state"
"$REPO/install.sh" --user tester --uninstall --purge >/dev/null 2>&1 || true
for u in alice bob 'a.b' a_b; do
	rm -f "/run/sudo-elevation/$(bash -c '. "$1/libexec/sudo-elevation/common.sh"; se_user_slug "$2"' _ "$REPO" "$u").lease"
done
ok "teardown clean"

echo "20_lifecycle: all checks passed"
