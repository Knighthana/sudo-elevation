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
# when someone forgets env -u. XDG_* are stripped too: install.sh honors the
# caller's XDG_CONFIG_HOME/DATA_HOME when the target user is the caller
# (install.sh:167-169), so a runner that sets them (e.g. actions/checkout
# overriding HOME for global git config) would write outside our sandbox.
se() { env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
	SUDO_ELEVATION_PREFIX="$SB/root" "$@"; }
# Same idea for user-tree (non-prefix) sandboxes: neutral PREFIX and XDG,
# then apply the caller's own env (HOME/PATH).
se_user() { env -u SUDO_ELEVATION_PREFIX -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
	-u XDG_STATE_HOME "$@"; }

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

log "config precedence: flag > existing config > default, and reinstall is idempotent"
CONF="$SB/root/etc/sudo-elevation.conf"
# A hand-edited machine layer, exactly what the README tells users to do.
cat >"$CONF" <<'EOF'
BASE_MINUTES=25
MAX_MINUTES=1440
GUI_BACKEND=wayland
EOF
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" >/dev/null
grep -qx 'BASE_MINUTES=25' "$CONF" || die "reinstall reset BASE_MINUTES: $(cat "$CONF")"
grep -qx 'MAX_MINUTES=1440' "$CONF" || die "reinstall reset MAX_MINUTES: $(cat "$CONF")"
grep -qx 'GUI_BACKEND=wayland' "$CONF" || die "reinstall reset GUI_BACKEND: $(cat "$CONF")"
# The window must reach sudoers too, not just the config file.
grep -q 'timestamp_timeout=25' "$SB/root/etc/sudoers.d/90-sudo-elevation-$ME" \
	|| die "sudoers disagrees with the preserved config"
# Keys the config never mentioned still materialise, so the file stays complete.
grep -qx 'DIALOG_TIMEOUT=300' "$CONF" || die "absent key not materialised: $(cat "$CONF")"
ok "reinstall preserves a hand-edited config and propagates it to sudoers"

log "an explicit flag overrides the config"
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" --base-timeout 30m >/dev/null
grep -qx 'BASE_MINUTES=30' "$CONF" || die "--base-timeout did not win: $(cat "$CONF")"
grep -q 'timestamp_timeout=30' "$SB/root/etc/sudoers.d/90-sudo-elevation-$ME" \
	|| die "flag did not reach sudoers"
# The keys the flag did not cover keep the config's values.
grep -qx 'MAX_MINUTES=1440' "$CONF" || die "unrelated key lost: $(cat "$CONF")"
grep -qx 'GUI_BACKEND=wayland' "$CONF" || die "unrelated key lost: $(cat "$CONF")"
ok "flag wins over config, untouched keys survive"

log "reinstall right after a flag install is idempotent"
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" >/dev/null
grep -qx 'BASE_MINUTES=30' "$CONF" || die "second reinstall reset the flag value: $(cat "$CONF")"
ok "idempotent"

log "a config that violates the flags' own bounds is rejected, not installed"
# Non-numeric values are ignored by the parser (documented fail-safe), so the
# effective value silently falls back to the default. Numeric but nonsensical
# ones must stop the install instead.
printf 'MAX_MINUTES=99999999\n' >"$CONF"
if "$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" >"$SB/badcfg.log" 2>&1; then
	die "installer accepted MAX_MINUTES=99999999"
fi
grep -q 'out of range' "$SB/badcfg.log" || die "no range complaint: $(cat "$SB/badcfg.log")"
printf 'BASE_MINUTES=100\nMAX_MINUTES=50\n' >"$CONF"
if "$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" >"$SB/badcfg.log" 2>&1; then
	die "installer accepted BASE > MAX"
fi
grep -q 'BASE must be <= MAX' "$SB/badcfg.log" || die "no ordering complaint: $(cat "$SB/badcfg.log")"
# A rejected install must not have left a half-applied config behind.
grep -q 'MAX_MINUTES=50' "$CONF" || die "rejected install rewrote the config: $(cat "$CONF")"
# Restore a sane config for the rest of the suite.
cat >"$CONF" <<'EOF'
BASE_MINUTES=15
MAX_MINUTES=525600
EOF
"$REPO/install.sh" --prefix "$SB/root" --user "$ME" --skill-dir "$SB/skill" >/dev/null
ok "out-of-range and inverted configs rejected"

log "se_user_slug is injective (a.b and a_b must not share a file)"
bash -c '
	. "$1/libexec/sudo-elevation/common.sh" || exit 1
	# Ordinary names (no dot, no underscore) must be untouched, or every
	# existing drop-in/lease would be orphaned on upgrade. A name containing
	# either is deliberately renamed -- that is the collision being fixed.
	for u in tester alice root A-1 svcaccount9; do
		[ "$(se_user_slug "$u")" = "$u" ] || { echo "$u was renamed" >&2; exit 1; }
	done
	# The two names the old tr -c mapping collapsed onto one file.
	[ "$(se_user_slug "a.b")" != "$(se_user_slug "a_b")" ] || exit 1
	[ "$(se_legacy_user_slug "a.b")" = "$(se_legacy_user_slug "a_b")" ] \
		|| { echo "legacy mapping is expected to collide" >&2; exit 1; }
	seen=""
	for u in alice bob a.b a_b a-b a.b.c A.B a_b_c a..b a__2e__b a__5f__b; do
		s=$(se_user_slug "$u")
		case " $seen " in
			*" $s "*) echo "collision: $u -> $s" >&2; exit 1 ;;
		esac
		seen="$seen $s"
	done
	# No output may be usable as a path fragment.
	case "$(se_user_slug "a.b")" in */*|.|..) echo "slug is not path-safe" >&2; exit 1 ;; esac
	exit 0
' _ "$REPO" || die "se_user_slug"
ok "slug encoding"


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
# The flow is a numbered list now, so anchor on step 1 rather than the old
# "Rule:" lead-in: same intent (English, and sudo -n comes first), new shape.
grep -q '^1\. Try `sudo -n <cmd>` first' "$SB/skill/SKILL.md" || die "skill not English"
grep -q 'sudo-elevation request' "$SB/skill/SKILL.md" || die "skill missing request"
grep -q '15 minutes' "$SB/skill/SKILL.md" || die "skill base not English"
grep -qF '<=60' "$SB/skill/SKILL.md" || die "skill missing 60-char guidance"
grep -qF 'do not loop requests' "$SB/skill/SKILL.md" || die "skill missing gone-user rule"
# The ownership marker the skill deletion guard keys on, plus the size budget
# that motivated the rewrite: a skill is loaded into an agent's context on every
# trigger, so growth here is a real cost, not a cosmetic one.
grep -q 'Managed by sudo-elevation' "$SB/skill/SKILL.md" || die "skill missing ownership marker"
_skill_bytes=$(wc -c < "$SB/skill/SKILL.md")
[ "$_skill_bytes" -le 2000 ] || die "skill grew to $_skill_bytes bytes (budget 2000)"
ok "skill English, marked, $_skill_bytes bytes"

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

log "se_config_trusted only trusts non-group/world-writable files"
bash -c '
	. "$1/libexec/sudo-elevation/common.sh" || exit 1
	me=$(id -un)
	printf "x\n" > "$2/trust.conf" || exit 1
	for m in 600 400 644 640 750 4755 2755; do
		chmod "$m" "$2/trust.conf"
		se_config_trusted "$2/trust.conf" "$me" || { echo "mode $m wrongly rejected" >&2; exit 1; }
	done
	for m in 660 666 664 606 777 1777; do
		chmod "$m" "$2/trust.conf"
		if se_config_trusted "$2/trust.conf" "$me"; then echo "mode $m wrongly trusted" >&2; exit 1; fi
	done
	# The next three assertions are about OWNERSHIP, and the CI runner executes
	# this suite as root -- where the file we just created is root-owned, which
	# is precisely the case they must not hit. Hand it to a non-root account so
	# "root or the target user, nobody else" is actually exercised either way.
	chmod 0644 "$2/trust.conf"
	owner=$me
	if [ "$(id -u)" = 0 ]; then
		owner=nobody
		chown nobody "$2/trust.conf" || exit 1
	fi
	se_config_trusted "$2/trust.conf" root && { echo "non-root file trusted as root-owned" >&2; exit 1; }
	se_config_trusted "$2/trust.conf" "" && { echo "non-root file trusted with no user" >&2; exit 1; }
	se_config_trusted "$2/trust.conf" "somebody-else" && { echo "third-party file trusted" >&2; exit 1; }
	se_config_trusted "$2/trust.conf" "$owner" || { echo "owner own file not trusted" >&2; exit 1; }
	se_config_trusted "$2/nope.conf" "$me" && { echo "missing file trusted" >&2; exit 1; }
	rm -f "$2/trust.conf"
	exit 0
' _ "$REPO" "$SB" || die "se_config_trusted"
ok "config trust predicate"

log "se_assert_target_user blocks cross-account helpers, not root"
bash -c '
	. "$1/libexec/sudo-elevation/common.sh" || exit 1
	# Not reached through sudo: root may target anyone.
	( unset SUDO_USER; se_assert_target_user grant bob ) || exit 1
	( export SUDO_USER=root;  se_assert_target_user grant bob ) || exit 1
	( export SUDO_USER=alice; se_assert_target_user grant alice ) || exit 1
	( export SUDO_USER=alice; se_assert_target_user grant bob ) 2>/dev/null && exit 1
	( export SUDO_USER=alice; se_assert_target_user restore bob ) 2>/dev/null && exit 1
	out=$(SUDO_USER=alice se_assert_target_user grant bob 2>&1) || true
	grep -qF "refusing --user bob" <<<"$out" || exit 1
	exit 0
' _ "$REPO" || die "se_assert_target_user"
ok "cross-account boundary predicate"


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
# NOTE: se_user neutralizes SUDO_ELEVATION_PREFIX and XDG_* (see helper);
# user installs are receipt-located, not prefixed.
se_user PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$REPO/install.sh" --user-install --user "$ME" --no-system --skill-dir "$FAKEHOME/skill" >/dev/null
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
se_user PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$FAKEHOME/.local/bin/sudo-elevation" uninstall --purge >/dev/null
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
se_user PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$REPO/install.sh" --user "$ME" --no-system --skill-dir "$FAKEHOME/skill2" >/dev/null
grep -q '^INSTALL_MODE=user$' "$FAKEHOME/.local/share/sudo-elevation/manifest" || die "bare no-system not user mode"
grep -q '^SYSTEM=0$' "$FAKEHOME/.local/share/sudo-elevation/manifest" || die "bare no-system SYSTEM!=0"
[ -f "$FAKEHOME/.local/bin/sudo-elevation" ] || die "bare no-system payload missing"
[ -f "$FAKEHOME/.config/sudo-elevation/config" ] || die "bare no-system config missing"
se_user PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$FAKEHOME/.local/bin/sudo-elevation" uninstall --purge >/dev/null
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
se_user PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$REPO/install.sh" --user "$ME" --no-system --skill-dir "$SB/ffskill" >/dev/null
# Needs passworded sudo: with NOPASSWD (e.g. CI runners) sudo -n always
# succeeds and there is nothing to fail fast on; docker 18 covers the real
# fail-fast path with a passworded user.
if sudo -n true 2>/dev/null; then
	ok "fail-fast skipped (passwordless sudo here; covered by docker 18)"
else
	rc=0
	# PATH without fakebin on purpose: the REAL sudo must refuse (-n) so the
	# fail-fast gate triggers. se_user still strips XDG so the CLI finds the
	# receipt we just wrote under $FAKEHOME.
	se_user PATH="/usr/bin:/bin" HOME="$FAKEHOME" "$FAKEHOME/.local/bin/sudo-elevation" uninstall --keep >"$SB/se-ff.log" 2>&1 || rc=$?
	[ "$rc" -eq 1 ] || die "fail-fast should exit 1, got $rc"
	grep -q "no valid sudo timestamp" "$SB/se-ff.log" || die "fail-fast message missing"
	[ -f "$FAKEHOME/.local/bin/sudo-elevation" ] || die "fail-fast removed payload"
	ok "fail-fast safe"
fi

log "leaked PREFIX does not hijack user trees"
se_user SUDO_ELEVATION_PREFIX="$SB/root" PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" \
	"$FAKEHOME/.local/bin/sudo-elevation" uninstall --keep >"$SB/se-leak.log" 2>&1 \
	|| die "leaked-PREFIX uninstall failed"
[ ! -e "$FAKEHOME/.local/bin/sudo-elevation" ] || die "leaked PREFIX missed XDG tree"
[ -f "$SB/ilist/usr/local/share/sudo-elevation/manifest" ] || die "leaked PREFIX touched sandbox tree"
ok "user layout wins over leaked PREFIX"
se_user PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" "$REPO/install.sh" --user-install --user "$ME" --no-system --uninstall --purge >/dev/null
[ ! -e "$FAKEHOME/.local/bin/sudo-elevation" ] || die "fakehome cleanup left payload"
[ ! -e "$FAKEHOME/.local/share/sudo-elevation/manifest" ] || die "fakehome cleanup left manifest"
[ ! -e "$FAKEHOME/.config/sudo-elevation/config" ] || die "fakehome cleanup left config"

log "XDG_* wins for the calling user (config+receipt follow XDG_CONFIG_HOME)"
# Guards install.sh:167-169: when the target user is the caller, their XDG
# dirs take precedence over $HOME defaults. This is the semantic that made the
# CI host test fail (actions/checkout exports XDG_CONFIG_HOME).
XDG=$SB/xdg
se_user PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" XDG_CONFIG_HOME="$XDG" XDG_DATA_HOME="$XDG/data" \
	"$REPO/install.sh" --user-install --user "$ME" --no-system --skill-dir "$FAKEHOME/skill3" >/dev/null
[ -f "$XDG/sudo-elevation/config" ] || die "config not under XDG_CONFIG_HOME"
[ -f "$XDG/sudo-elevation/env" ] || die "receipt not under XDG_CONFIG_HOME"
grep -qF "SUDO_ELEVATION_CONFIG=$XDG/sudo-elevation/config" "$XDG/sudo-elevation/env" \
	|| die "receipt does not point at the XDG config"
[ -f "$XDG/data/sudo-elevation/manifest" ] || die "manifest not under XDG_DATA_HOME"
[ ! -e "$FAKEHOME/.config/sudo-elevation/config" ] || die "config also written to HOME"
# CLI must resolve the XDG tree without exports (receipt follows XDG too).
se_user PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" XDG_CONFIG_HOME="$XDG" XDG_DATA_HOME="$XDG/data" \
	"$FAKEHOME/.local/bin/sudo-elevation" status --porcelain >"$SB/se-xdg.log" 2>&1 \
	|| die "CLI failed to resolve the XDG tree: $(cat "$SB/se-xdg.log")"
grep -qF 'base_minutes=15' "$SB/se-xdg.log" || die "XDG CLI status wrong: $(cat "$SB/se-xdg.log")"
se_user PATH="$SB/fakebin:$PATH" HOME="$FAKEHOME" XDG_CONFIG_HOME="$XDG" XDG_DATA_HOME="$XDG/data" \
	"$REPO/install.sh" --user-install --user "$ME" --no-system --uninstall --purge >/dev/null
[ ! -e "$XDG/sudo-elevation" ] || die "XDG purge left config"
[ ! -e "$XDG/data/sudo-elevation" ] || die "XDG purge left manifest"
ok "XDG precedence honored"

printf '\nHOST TESTS PASSED\n'
