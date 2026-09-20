#!/bin/bash
# Host-side sandbox tests: install/uninstall logic without touching the system.
# Runs as a normal user with --prefix; privileged paths are validated by the
# docker scenarios instead.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d /tmp/sudo-elevation-host.XXXXXX)
trap 'rm -rf "$SB"' EXIT
ME=$(id -un)
FAIL=0

ok() { printf '  ok: %s\n' "$*"; }
die() {
	printf '  FAIL: %s\n' "$*" >&2
	exit 1
}
log() { printf '\n== %s ==\n' "$*"; }

log "syntax check"
for f in install.sh bin/sudo-askpass bin/sudo-elevation \
	libexec/sudo-elevation/grant libexec/sudo-elevation/restore \
	libexec/sudo-elevation/common.sh; do
	bash -n "$REPO/$f"
done
ok "all scripts parse"

log "dry-run does not touch the sandbox"
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" --dry-run >/dev/null
[ ! -e "$SB/root/usr/local/bin/sudo-askpass" ] || die "dry-run created files"
ok "dry-run clean"

log "prefix install"
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" >/dev/null
for f in usr/local/bin/sudo-askpass usr/local/bin/sudo-elevation \
	usr/local/libexec/sudo-elevation/grant usr/local/libexec/sudo-elevation/restore \
	usr/local/libexec/sudo-elevation/common.sh etc/sudo-elevation.conf \
	etc/sudoers.d/90-sudo-elevation-"$ME" usr/local/share/sudo-elevation/manifest; do
	[ -f "$SB/root/$f" ] || die "missing $f"
done
[ -f "$SB/skill/SKILL.md" ] || die "missing skill"
grep -q '^BASE_MINUTES=15$' "$SB/root/etc/sudo-elevation.conf" || die "bad config"
grep -q 'timestamp_timeout=15' "$SB/root/etc/sudoers.d/90-sudo-elevation-$ME" || die "bad sudoers"
grep -q 'Path askpass' "$SB/root/etc/sudo.conf" || die "no askpass block"
grep -q 'sudo-elevation request' "$SB/skill/SKILL.md" || die "skill not rendered"
ok "install tree complete"

log "installed CLI works with prefix"
export SUDO_ELEVATION_PREFIX="$SB/root"
SE="$SB/root/usr/local/bin/sudo-elevation"
[ "$("$SE" version)" = "sudo-elevation 0.1.0" ] || die "bad version"
[ "$("$SE" parse 90s)" = "1.5" ] || die "bad parse"
[ "$("$SE" parse 1d)" = "1440" ] || die "bad parse"
status_out=$("$SE" status)
grep -q '无活动租约' <<<"$status_out" || die "bad status"
ok "CLI works"

log "idempotent re-install"
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" >/dev/null
[ "$(grep -c '# >>> sudo-elevation >>>' "$SB/root/etc/sudo.conf")" = 1 ] || die "duplicate block"
ok "single marker block"

log "foreign askpass conflict"
mkdir -p "$SB/conflict/etc"
printf 'Path askpass /bin/false\n' > "$SB/conflict/etc/sudo.conf"
if "$REPO/install.sh" --prefix "$SB/conflict" --user "$ME" --skill-dir "$SB/skill2" >/dev/null 2>&1; then
	die "install should refuse foreign askpass"
fi
ok "refused"
"$REPO/install.sh" --prefix "$SB/conflict" --user "$ME" --skill-dir "$SB/skill2" --force >/dev/null
grep -q 'Path askpass /bin/false' "$SB/conflict/etc/sudo.conf" || die "foreign line lost"
grep -q '^# >>> sudo-elevation >>>$' "$SB/conflict/etc/sudo.conf" || die "block missing"
ok "--force works"

log "uninstall"
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" --uninstall >/dev/null
for f in usr/local/bin/sudo-askpass usr/local/bin/sudo-elevation \
	usr/local/libexec/sudo-elevation/grant etc/sudo-elevation.conf \
	etc/sudoers.d/90-sudo-elevation-"$ME" usr/local/share/sudo-elevation/manifest; do
	[ ! -e "$SB/root/$f" ] || die "leftover $f"
done
[ ! -e "$SB/skill/SKILL.md" ] || die "leftover skill"
if [ -f "$SB/root/etc/sudo.conf" ]; then
	! grep -q 'sudo-elevation' "$SB/root/etc/sudo.conf" || die "leftover sudo.conf block"
fi
ok "uninstall clean"

printf '\nHOST TESTS PASSED\n'
