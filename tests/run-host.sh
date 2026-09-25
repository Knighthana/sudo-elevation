#!/bin/bash
# Host-side sandbox tests: install/uninstall logic without touching the system.
# Runs as a normal user with --prefix; privileged paths are validated by the
# docker scenarios instead.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SB=$(mktemp -d /tmp/sudo-elevation-host.XXXXXX)
trap 'rm -rf "$SB"' EXIT
ME=$(id -un)

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
	usr/local/libexec/sudo-elevation/install.sh usr/local/libexec/sudo-elevation/common.sh \
	etc/sudo-elevation.conf \
	etc/sudoers.d/90-sudo-elevation-"$ME" usr/local/share/sudo-elevation/manifest; do
	[ -f "$SB/root/$f" ] || die "missing $f"
done
[ -f "$SB/skill/SKILL.md" ] || die "missing skill"
grep -q '^BASE_MINUTES=15$' "$SB/root/etc/sudo-elevation.conf" || die "bad config"
grep -q 'timestamp_timeout=15' "$SB/root/etc/sudoers.d/90-sudo-elevation-$ME" || die "bad sudoers"
grep -q 'Path askpass' "$SB/root/etc/sudo.conf" || die "no askpass block"
grep -q 'sudo-elevation request' "$SB/skill/SKILL.md" || die "skill not rendered"
ok "install tree complete"

log "production install strips test hooks"
if grep -q 'SUDO_ELEVATION_FAKE_PASSWORD' "$SB/root/usr/local/bin/sudo-askpass"; then
	die "test hooks present in production askpass"
fi
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" --test-hooks >/dev/null
grep -q 'SUDO_ELEVATION_FAKE_PASSWORD' "$SB/root/usr/local/bin/sudo-askpass" \
	|| die "test hooks missing with --test-hooks"
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" >/dev/null
if grep -q 'SUDO_ELEVATION_FAKE_PASSWORD' "$SB/root/usr/local/bin/sudo-askpass"; then
	die "re-install without --test-hooks left hooks behind"
fi
ok "hook stripping works"

log "sudo version comparison (>= 1.8.21 for timestamp_type)"
bash -c '
	. "$1/libexec/sudo-elevation/common.sh" || exit 1
	se_version_ge "Sudo version 1.9.15p5" 1.8.21 || exit 1
	se_version_ge "sudo version 1.8.21" 1.8.21 || exit 1
	se_version_ge "sudo version 1.8.27p1" 1.8.21 || exit 1
	if se_version_ge "sudo version 1.8.20" 1.8.21; then exit 1; fi
	if se_version_ge "sudo version 1.7.3" 1.8.21; then exit 1; fi
	exit 0
' _ "$REPO" || die "version comparison"
ok "version compare"

log "installed CLI works with prefix"
export SUDO_ELEVATION_PREFIX="$SB/root"
SE="$SB/root/usr/local/bin/sudo-elevation"
[ "$("$SE" version)" = "sudo-elevation $(cat "$REPO/VERSION")" ] || die "bad version"
[ "$("$SE" parse 90s)" = "1.5" ] || die "bad parse"
[ "$("$SE" parse 1d)" = "1440" ] || die "bad parse"
status_out=$("$SE" status)
grep -q '无活动租约' <<<"$status_out" || die "bad status"
ok "CLI works"

log "status remaining time uses the leading timestamp of the lease id"
lease="$SB/root/run/sudo-elevation/$ME.lease"
mkdir -p "$(dirname "$lease")"
# Unique id format "start-pid-random": pid/random must not leak into the
# arithmetic (the old code did $((epoch + secs)) and subtracted them).
start=$(($(date +%s) - 1800))
printf 'epoch=%s-5000-7\nuser=%s\nminutes=60\ngranted_at=test\nreason=test\nrestore=none\n' \
	"$start" "$ME" > "$lease"
status_out=$("$SE" status)
grep -qF '活动租约' <<<"$status_out" || die "lease not reported: $status_out"
grep -qF '已到期' <<<"$status_out" && die "active lease reported as expired: $status_out"
grep -qE '剩余: 30(\.0)? 分钟' <<<"$status_out" || die "bad remaining time: $status_out"
rm -f "$lease"
ok "remaining time correct"

log "idempotent re-install"
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" >/dev/null
[ "$(grep -c '# >>> sudo-elevation >>>' "$SB/root/etc/sudo.conf")" = 1 ] || die "duplicate block"
ok "single marker block"

log "install prune preserves admin backups, keeps single own backup"
printf '# admin\n' > "$SB/root/etc/sudo.conf.bak.admin-keep"
printf '# admin2\n' > "$SB/root/etc/sudo.conf.bak.custom"
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" >/dev/null
[ -f "$SB/root/etc/sudo.conf.bak.admin-keep" ] || die "admin backup deleted by install prune"
[ -f "$SB/root/etc/sudo.conf.bak.custom" ] || die "admin backup deleted by install prune"
own_n=0
for b in "$SB/root"/etc/sudo.conf.bak.*; do
	[ -f "$b" ] || continue
	rest=${b##*.bak.}
	case "$rest" in
		??????????????|??????????????.*) ;;
		*) continue ;;
	esac
	if printf '%s' "${rest%%.*}" | grep -Eq '^[0-9]{14}$'; then own_n=$((own_n + 1)); fi
done
[ "$own_n" = 1 ] || die "own backup count=$own_n want 1"
grep -q '^SUDO_CONF_BAK=sudo.conf.bak.[0-9]' "$SB/root/usr/local/share/sudo-elevation/manifest" \
	|| die "manifest BAK not own shape"
ok "backup prune precise"

log "unclosed marker block fails closed"
printf '# >>> sudo-elevation >>>\nPath askpass /tmp/x\n' >> "$SB/root/etc/sudo.conf"
if "$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" >/dev/null 2>&1; then
	die "install should fail on unclosed block"
fi
printf '# <<< sudo-elevation <<<\n' >> "$SB/root/etc/sudo.conf"
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" >/dev/null
[ "$(grep -c '# >>> sudo-elevation >>>' "$SB/root/etc/sudo.conf")" = 1 ] || die "block repair failed"
ok "fail-closed then repair"

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

log "skill is English and concise"
grep -q '^Rule: always try `sudo -n' "$SB/skill/SKILL.md" || die "skill not English"
grep -q 'sudo-elevation request' "$SB/skill/SKILL.md" || die "skill missing request"
grep -q '15 minutes' "$SB/skill/SKILL.md" || die "skill base not English"
grep -qF '<=60' "$SB/skill/SKILL.md" || die "skill missing 60-char guidance"
grep -qF 'do not loop requests' "$SB/skill/SKILL.md" || die "skill missing gone-user rule"
ok "skill English"

log "status --porcelain (no lease)"
export SUDO_ELEVATION_PREFIX="$SB/root"
porc=$("$SE" status --porcelain)
grep -qF 'active=0' <<<"$porc" || die "porcelain inactive: $porc"
grep -qF 'base_minutes=15' <<<"$porc" || die "porcelain base: $porc"
ok "porcelain inactive"

log "strict config rejects malformed numbers; invalid displays as 0"
bash -c '
	. "$1/libexec/sudo-elevation/common.sh" || exit 1
	printf "BASE_MINUTES=15.5.5\n" > "$2/c.conf"
	BASE_MINUTES=15 SUDO_ELEVATION_CONFIG="$2/c.conf" se_load_config
	[ "$BASE_MINUTES" = 15 ] || exit 1
	[ "$(se_human_minutes "?")" = "0 秒" ] || exit 1
	[ "$(se_human_minutes_en "?")" = "0 seconds" ] || exit 1
	[ "$(se_human_minutes_en 15)" = "15 minutes" ] || exit 1
	[ "$(se_human_minutes_en 0)" = "0 (strict: password every time)" ] || exit 1
	se_parse_minutes 1m30s >/dev/null 2>&1 && exit 1
	exit 0
' _ "$REPO" "$SB" || die "strict config/human"
if "$SE" parse 1m30s >/dev/null 2>&1; then die "parse 1m30s accepted"; fi
out=$("$SE" parse 1m30s 2>&1 || true)
grep -qF '90s' <<<"$out" || die "composite hint missing: $out"
ok "strict config"

log "uninstall --dry-run touches nothing"
touch "$SB/root/etc/sudo.conf.bak.20990101000000"
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" --uninstall --dry-run >/dev/null
[ -f "$SB/root/etc/sudo.conf.bak.20990101000000" ] || die "dry-run deleted backup"
[ -f "$SB/root/usr/local/bin/sudo-elevation" ] || die "dry-run deleted binaries"
rm -f "$SB/root/etc/sudo.conf.bak.20990101000000"
ok "uninstall dry-run clean"

log "user-install --dry-run resolves XDG layout without touching home"
UH=$(getent passwd "$ME" | cut -d: -f6)
[ -n "$UH" ] || die "no home for $ME"
[ ! -e "$UH/.local/bin/sudo-elevation" ] || die "pre-existing user install, abort"
out=$("$REPO/install.sh" --user-install --no-system --dry-run 2>&1)
grep -qF "$UH/.local/bin" <<<"$out" || die "no user bindir: $out"
grep -qF -- "--no-system" <<<"$out" || die "no-system note missing: $out"
[ ! -e "$UH/.local/bin/sudo-elevation" ] || die "dry-run wrote home"
[ ! -e "$UH/.config/sudo-elevation/env" ] || die "dry-run wrote receipt"
ok "user dry-run clean"

log "keep uninstall via CLI (prefix sandbox, no sudo needed)"
"$SE" uninstall >/dev/null
for f in usr/local/bin/sudo-askpass usr/local/bin/sudo-elevation \
	usr/local/libexec/sudo-elevation/grant usr/local/libexec/sudo-elevation/install.sh \
	usr/local/libexec/sudo-elevation/restore; do
	[ ! -e "$SB/root/$f" ] || die "leftover $f"
done
for f in etc/sudo-elevation.conf etc/sudoers.d/90-sudo-elevation-"$ME" \
	usr/local/share/sudo-elevation/manifest; do
	[ -f "$SB/root/$f" ] || die "config should be kept: $f"
done
[ -f "$SB/skill/SKILL.md" ] || die "skill should be kept"
grep -q 'sudo-elevation' "$SB/root/etc/sudo.conf" || die "marker should be kept"
ok "keep: payload gone, config kept"

log "purge uninstall removes everything"
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" --uninstall --purge >/dev/null
for f in usr/local/bin/sudo-askpass usr/local/bin/sudo-elevation \
	usr/local/libexec/sudo-elevation/grant usr/local/libexec/sudo-elevation/install.sh \
	usr/local/libexec/sudo-elevation/restore etc/sudo-elevation.conf \
	etc/sudoers.d/90-sudo-elevation-"$ME" usr/local/share/sudo-elevation/manifest; do
	[ ! -e "$SB/root/$f" ] || die "leftover $f"
done
[ ! -e "$SB/skill/SKILL.md" ] || die "leftover skill"
if [ -f "$SB/root/etc/sudo.conf" ]; then
	! grep -q 'sudo-elevation' "$SB/root/etc/sudo.conf" || die "leftover sudo.conf block"
fi
ok "purge clean"

printf '\nHOST TESTS PASSED\n'
