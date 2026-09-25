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
# Sandbox CLI runner: SUDO_ELEVATION_PREFIX is set per-command (never
# exported) so user-tree tests below cannot accidentally hit the wrong tree
# when someone forgets env -u.
se() { env SUDO_ELEVATION_PREFIX="$SB/root" "$@"; }

log "syntax check"
for f in install.sh bin/sudo-askpass bin/sudo-elevation \
	libexec/sudo-elevation/grant libexec/sudo-elevation/restore \
	libexec/sudo-elevation/common.sh tests/manual/lock-tty.sh; do
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
SE="$SB/root/usr/local/bin/sudo-elevation"
[ "$(se "$SE" version)" = "sudo-elevation $(cat "$REPO/VERSION")" ] || die "bad version"
[ "$(se "$SE" parse 90s)" = "1.5" ] || die "bad parse"
[ "$(se "$SE" parse 1d)" = "1440" ] || die "bad parse"
status_out=$(se "$SE" status)
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
status_out=$(se "$SE" status)
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
porc=$(se "$SE" status --porcelain)
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
if se "$SE" parse 1m30s >/dev/null 2>&1; then die "parse 1m30s accepted"; fi
out=$(se "$SE" parse 1m30s 2>&1 || true)
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

log "no-system user-install: real files land in HOME, system untouched, purge preserves foreign"
FAKEHOME=$SB/fakehome
mkdir -p "$SB/fakebin" "$FAKEHOME"
# full sandbox: fake sudo (no privilege) + fake getent (redirect passwd home);
# --user-install resolves all paths from getent, the CLI receipt from HOME
# fake sudo: answers -V, strips -n/-A (emulates a valid timestamp), else execs
printf '#!/bin/sh\nif [ "$1" = "-V" ]; then echo "Sudo version 1.9.15p5"; exit 0; fi\nwhile :; do case "$1" in -n|-A) shift;; *) break;; esac; done\nexec "$@"\n' > "$SB/fakebin/sudo"
{
	printf '#!/bin/sh\n'
	printf 'if [ "$1" = passwd ] && [ "$2" = "%s" ]; then\n' "$ME"
	printf '	printf "%%s:x:1000:1000::%%s:/bin/bash\\n" "%s" "%s"\n' "$ME" "$FAKEHOME"
	printf 'else\n	exec /usr/bin/getent "$@"\nfi\n'
} > "$SB/fakebin/getent"
chmod 0755 "$SB/fakebin/sudo" "$SB/fakebin/getent"
command -v getent >/dev/null || die "getent missing"
[ -x /usr/bin/getent ] || die "expected getent at /usr/bin/getent"
printf '#!/bin/sh\necho hi\n' > "$FAKEHOME/unrelated-tool"
printf 'third party without marker\n' > "$FAKEHOME/foreign-skill.md"
# NOTE: SUDO_ELEVATION_PREFIX is intentionally unset here (the se() helper
# scopes it per-command); user installs are receipt-located, not prefixed.
env -u SUDO_ELEVATION_PREFIX PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$REPO/install.sh" --user-install --user "$ME" --no-system --skill-dir "$FAKEHOME/skill" >/dev/null
[ -f "$FAKEHOME/.local/bin/sudo-elevation" ] || die "no-system payload missing"
[ -f "$FAKEHOME/.config/sudo-elevation/config" ] || die "no-system config missing"
[ -f "$FAKEHOME/.config/sudo-elevation/env" ] || die "no-system receipt missing"
grep -q '^SYSTEM=0$' "$FAKEHOME/.local/share/sudo-elevation/manifest" || die "manifest SYSTEM!=0"
grep -q 'sudo-elevation request' "$FAKEHOME/skill/SKILL.md" || die "no-system skill missing"
[ -f "$FAKEHOME/unrelated-tool" ] || die "foreign tool lost on install"
mkdir -p "$FAKEHOME/skill-other"
cp "$FAKEHOME/foreign-skill.md" "$FAKEHOME/skill-other/SKILL.md"
# full CLI path (fake sudo stands in for privilege): manifest SYSTEM=0 must
# forward --no-system so no root-owned system path is touched
env -u SUDO_ELEVATION_PREFIX PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$FAKEHOME/.local/bin/sudo-elevation" uninstall --purge >/dev/null
[ ! -e "$FAKEHOME/.local/bin/sudo-elevation" ] || die "no-system purge left payload"
[ ! -e "$FAKEHOME/.config/sudo-elevation/config" ] || die "no-system purge left config"
[ ! -e "$FAKEHOME/.config/sudo-elevation/env" ] || die "no-system purge left receipt"
[ ! -e "$FAKEHOME/.local/share/sudo-elevation/manifest" ] || die "no-system purge left manifest"
[ ! -e "$FAKEHOME/skill/SKILL.md" ] || die "no-system purge left skill"
[ -f "$FAKEHOME/unrelated-tool" ] || die "no-system purge deleted foreign tool"
[ -f "$FAKEHOME/skill-other/SKILL.md" ] || die "no-system purge deleted third-party skill"
[ ! -e "$UH/.local/bin/sudo-elevation" ] || die "no-system leaked into real HOME"
[ ! -e "$UH/.config/sudo-elevation/env" ] || die "no-system leaked receipt into real HOME"
ok "no-system install/uninstall precise"

log "bare --no-system implies user layout (never system dirs)"
env -u SUDO_ELEVATION_PREFIX PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$REPO/install.sh" --user "$ME" --no-system --skill-dir "$FAKEHOME/skill2" >/dev/null
grep -q '^INSTALL_MODE=user$' "$FAKEHOME/.local/share/sudo-elevation/manifest" || die "bare no-system not user mode"
grep -q '^SYSTEM=0$' "$FAKEHOME/.local/share/sudo-elevation/manifest" || die "bare no-system SYSTEM!=0"
[ -f "$FAKEHOME/.local/bin/sudo-elevation" ] || die "bare no-system payload missing"
[ -f "$FAKEHOME/.config/sudo-elevation/config" ] || die "bare no-system config missing"
env -u SUDO_ELEVATION_PREFIX PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$FAKEHOME/.local/bin/sudo-elevation" uninstall --purge >/dev/null
[ ! -e "$FAKEHOME/.local/bin/sudo-elevation" ] || die "bare no-system purge left payload"
[ ! -e "$FAKEHOME/.local/share/sudo-elevation/manifest" ] || die "bare no-system purge left manifest"
[ -f "$FAKEHOME/unrelated-tool" ] || die "bare no-system purge deleted foreign tool"
[ ! -e "$UH/.local/bin/sudo-elevation" ] || die "bare no-system leaked into real HOME"
ok "bare no-system stays in user dirs"

log "prefix + no-system: sandbox system files skipped on uninstall"
NSR=$SB/nsroot
mkdir -p "$NSR/etc/sudoers.d"
printf 'Defaults lecture\n' > "$NSR/etc/sudo.conf"
printf 'root ALL=(ALL) ALL\n' > "$NSR/etc/sudoers.d/10-admin"
chmod 0440 "$NSR/etc/sudoers.d/10-admin"
printf '# admin\n' > "$NSR/etc/sudo.conf.bak.admin-keep"
"$REPO/install.sh" --prefix "$NSR" --user "$ME" --skill-dir "$SB/nsskill" --no-system >/dev/null
grep -q '^SYSTEM=0$' "$NSR/usr/local/share/sudo-elevation/manifest" || die "prefix manifest SYSTEM!=0"
[ ! -e "$NSR/etc/sudoers.d/90-sudo-elevation-$ME" ] || die "no-system install wrote sudoers"
SUDO_ELEVATION_PREFIX="$NSR" PATH="$SB/fakebin:$PATH" "$NSR/usr/local/bin/sudo-elevation" uninstall --purge >/dev/null
[ ! -e "$NSR/usr/local/bin/sudo-elevation" ] || die "prefix no-system purge left payload"
[ -f "$NSR/etc/sudoers.d/10-admin" ] || die "prefix no-system purge deleted foreign sudoers"
grep -q 'Defaults lecture' "$NSR/etc/sudo.conf" || die "prefix sudo.conf foreign lost"
[ -f "$NSR/etc/sudo.conf.bak.admin-keep" ] || die "prefix no-system purge deleted admin backup"
ok "prefix no-system skips system files"

log "keep uninstall via CLI (prefix sandbox, no sudo needed)"
start=$(($(date +%s) - 60))
printf 'epoch=%s-1-1\nuser=%s\nminutes=15\nrestore=none\n' "$start" "$ME" > "$SB/root/run/sudo-elevation/$ME.lease"
se "$SE" uninstall --keep >/dev/null
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
[ ! -e "$SB/root/run/sudo-elevation/$ME.lease" ] || die "keep left lease behind"
ok "keep: payload gone, config kept, lease ended"

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

log "bare uninstall without tty only lists (exit 2, nothing removed)"
"$REPO/install.sh" --prefix "$SB/ilist" --user "$ME" --skill-dir "$SB/iskill" >/dev/null
rc=0
SUDO_ELEVATION_PREFIX="$SB/ilist" "$REPO/install.sh" --uninstall </dev/null >"$SB/se-list.log" 2>&1 || rc=$?
[ "$rc" -eq 2 ] || die "list-only should exit 2, got $rc"
grep -qF "$SB/ilist/usr/local/share/sudo-elevation/manifest" "$SB/se-list.log" \
	|| die "list missed sandbox tree: $(cat "$SB/se-list.log")"
grep -q "nothing was removed" "$SB/se-list.log" || die "list must state nothing removed"
grep -q "^    keep: " "$SB/se-list.log" || die "list must print keep replay"
grep -q "^    purge: " "$SB/se-list.log" || die "list must print purge replay"
grep -qF -- "--prefix '$SB/ilist'" "$SB/se-list.log" || die "replay must carry --prefix"
[ -f "$SB/ilist/usr/local/bin/sudo-elevation" ] || die "list-only removed payload"
ok "list-only safe"

log "manifest records full layout keys"
for k in VERSION BASE_MINUTES MAX_MINUTES USERS INSTALL_MODE SYSTEM SUDO_CONF_BAK PREFIX \
	BINDIR LIBEXECDIR SHAREDIR CONFIG SUDO_CONF SUDOERS_DIR RUNTIME_DIR LOG SKILL_DIR; do
	grep -q "^$k=" "$SB/ilist/usr/local/share/sudo-elevation/manifest" || die "manifest lacks $k"
done
grep -q "^PREFIX=$SB/ilist$" "$SB/ilist/usr/local/share/sudo-elevation/manifest" \
	|| die "manifest PREFIX wrong"
ok "manifest full keys"

log "prefix mismatch warns and only touches the requested tree"
cp -r "$SB/ilist" "$SB/other"
"$REPO/install.sh" --prefix "$SB/other" --user "$ME" --skill-dir "$SB/otherskill" --uninstall --keep >"$SB/se-mismatch.log" 2>&1 \
	|| die "mismatched uninstall failed"
grep -q "manifest PREFIX=$SB/ilist differs" "$SB/se-mismatch.log" \
	|| die "PREFIX mismatch warning missing: $(cat "$SB/se-mismatch.log")"
[ -f "$SB/ilist/usr/local/bin/sudo-elevation" ] || die "mismatched uninstall touched tree A"
[ ! -e "$SB/other/usr/local/bin/sudo-elevation" ] || die "mismatched uninstall missed tree B"
ok "prefix mismatch safe"

log "bare uninstall on a pty asks per tree (skip keeps everything)"
if command -v script >/dev/null 2>&1; then
	printf 's\n' | script -qec "env SUDO_ELEVATION_PREFIX='$SB/ilist' '$REPO/install.sh' --uninstall" /dev/null >"$SB/se-pty.log" 2>&1 || true
	grep -q "skipped=1" "$SB/se-pty.log" || die "pty skip summary missing: $(cat "$SB/se-pty.log")"
	[ -f "$SB/ilist/usr/local/bin/sudo-elevation" ] || die "pty skip removed payload"
	ok "interactive skip safe"

	log "bare uninstall on a pty answers keep (payload gone, config kept)"
	printf 'k\n' | script -qec "env SUDO_ELEVATION_PREFIX='$SB/ilist' '$REPO/install.sh' --uninstall" /dev/null >"$SB/se-pty2.log" 2>&1 || true
	grep -q "kept=1" "$SB/se-pty2.log" || die "pty keep summary missing: $(cat "$SB/se-pty2.log")"
	[ ! -e "$SB/ilist/usr/local/bin/sudo-elevation" ] || die "pty keep left payload"
	[ -f "$SB/ilist/usr/local/share/sudo-elevation/manifest" ] || die "pty keep removed manifest"
	grep -q "install.sh.*--uninstall --purge" "$SB/se-pty2.log" || die "keep must print purge replay"
	grep -qF -- "--prefix '$SB/ilist'" "$SB/se-pty2.log" || die "replay must carry --prefix"
	grep -qF -- "--user '$ME'" "$SB/se-pty2.log" || die "replay must carry --user"
	ok "interactive keep works"
else
	ok "pty tests skipped (no script(1))"
fi

log "install.sh --keep direct call keeps config without prompts"
"$REPO/install.sh" --prefix "$SB/ilist" --user "$ME" --skill-dir "$SB/iskill" --uninstall --keep >/dev/null
[ ! -e "$SB/ilist/usr/local/bin/sudo-elevation" ] || die "direct keep left payload"
[ -f "$SB/ilist/usr/local/share/sudo-elevation/manifest" ] || die "direct keep removed manifest"
ok "direct --keep works"

log "automatic mode fails fast without timestamp (rc=1, nothing touched)"
env -u SUDO_ELEVATION_PREFIX PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$REPO/install.sh" --user "$ME" --no-system --skill-dir "$SB/ffskill" >/dev/null
rc=0
HOME="$FAKEHOME" PATH="/usr/bin:/bin" "$FAKEHOME/.local/bin/sudo-elevation" uninstall --keep >"$SB/se-ff.log" 2>&1 || rc=$?
[ "$rc" -eq 1 ] || die "fail-fast should exit 1, got $rc"
grep -q "no valid sudo timestamp" "$SB/se-ff.log" || die "fail-fast message missing"
[ -f "$FAKEHOME/.local/bin/sudo-elevation" ] || die "fail-fast removed payload"
ok "fail-fast safe"

log "leaked PREFIX does not hijack user trees"
SUDO_ELEVATION_PREFIX="$SB/root" PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$FAKEHOME/.local/bin/sudo-elevation" uninstall --keep >"$SB/se-leak.log" 2>&1 \
	|| die "leaked-PREFIX uninstall failed"
[ ! -e "$FAKEHOME/.local/bin/sudo-elevation" ] || die "leaked PREFIX missed XDG tree"
[ -f "$SB/ilist/usr/local/share/sudo-elevation/manifest" ] || die "leaked PREFIX touched sandbox tree"
ok "user layout wins over leaked PREFIX"
env -u SUDO_ELEVATION_PREFIX PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$REPO/install.sh" --user-install --user "$ME" --no-system --uninstall --purge >/dev/null
[ ! -e "$FAKEHOME/.local/bin/sudo-elevation" ] || die "fakehome cleanup left payload"
[ ! -e "$FAKEHOME/.local/share/sudo-elevation/manifest" ] || die "fakehome cleanup left manifest"
[ ! -e "$FAKEHOME/.config/sudo-elevation/config" ] || die "fakehome cleanup left config"

printf '\nHOST TESTS PASSED\n'
