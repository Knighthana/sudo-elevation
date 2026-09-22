#!/bin/bash
# sudo-elevation installer / uninstaller.
#
# Installs:
#   /usr/local/bin/sudo-askpass                 GUI askpass helper
#   /usr/local/bin/sudo-elevation               user CLI
#   /usr/local/libexec/sudo-elevation/{grant,restore,common.sh}
#   /etc/sudo-elevation.conf                    base/max window config
#   /etc/sudo.conf                              marker block: Path askpass ...
#   /etc/sudoers.d/90-sudo-elevation-<user>     base timestamp_timeout
#   ~/.config/opencode/skill/sudo-elevation/SKILL.md
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$SELF_DIR
# Repo checkout has VERSION next to this script; the installed copy in
# libexec reads the manifest copy under share/ instead.
VERSION=$(cat "$REPO_DIR/VERSION" 2>/dev/null \
	|| cat "${REPO_DIR%/libexec/sudo-elevation}/share/sudo-elevation/VERSION" 2>/dev/null \
	|| printf 'dev')
INSTALLED_MODE=0
[ -f "$SELF_DIR/common.sh" ] && INSTALLED_MODE=1

PREFIX=""
TARGET_USER=""
BASE_SPEC="15m"
MAX_SPEC="365d"
DRY=0
FORCE=0
DO_SKILL=1
TEST_HOOKS=0
SKILL_DIR=""
ACTION=install
PURGE=0

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
run() {
	if [ "$DRY" = 1 ]; then say "[dry-run] $*"; else "$@"; fi
}

usage() {
	cat <<'EOF'
usage: sudo ./install.sh [options]

options:
  --user USER           target user (default: $SUDO_USER or current user)
  --base-timeout SPEC   base window (default 15m; examples: 15m, 30m)
  --max-timeout SPEC    maximum approvable lease (default 365d)
  --prefix DIR          install everything under DIR (testing/sandbox)
  --skill-dir DIR       override opencode skill directory
  --no-skill            do not install the opencode skill
  --test-hooks          keep fake/print test hooks in the installed askpass
                        (for the test-suite only; default strips them)
  --dry-run             print actions without changing anything
  --force               take over an existing foreign `Path askpass` setting
  --uninstall           remove sudo-elevation
  --purge               with --uninstall: also remove the audit log
  --version             print version
  --help                this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--user) TARGET_USER=${2-}; shift 2 ;;
		--base-timeout) BASE_SPEC=${2-}; shift 2 ;;
		--max-timeout) MAX_SPEC=${2-}; shift 2 ;;
		--prefix) PREFIX=${2-}; shift 2 ;;
		--skill-dir) SKILL_DIR=${2-}; shift 2 ;;
		--no-skill) DO_SKILL=0; shift ;;
		--test-hooks) TEST_HOOKS=1; shift ;;
		--dry-run|-n) DRY=1; shift ;;
		--force|-f) FORCE=1; shift ;;
		--uninstall) ACTION=uninstall; shift ;;
		--purge) PURGE=1; shift ;;
		--version) printf '%s\n' "$VERSION"; exit 0 ;;
		--help|-h) usage; exit 0 ;;
		*) die "unknown option: $1 (try --help)" ;;
	esac
done

[ -n "$TARGET_USER" ] || TARGET_USER=${SUDO_USER:-$(id -un)}
id "$TARGET_USER" >/dev/null 2>&1 || die "no such user: $TARGET_USER"

if [ -n "$PREFIX" ]; then export SUDO_ELEVATION_PREFIX=$PREFIX; fi
if [ "$INSTALLED_MODE" = 1 ]; then
	# shellcheck source=common.sh
	. "$SELF_DIR/common.sh"
else
	# shellcheck source=libexec/sudo-elevation/common.sh
	. "$REPO_DIR/libexec/sudo-elevation/common.sh"
fi

if [ "$(id -u)" != 0 ] && [ -z "$PREFIX" ]; then
	die "must run as root (sudo ./install.sh)"
fi

strip_block() {
	awk '
		/^# >>> sudo-elevation >>>[[:space:]]*$/ { skip = 1; next }
		/^# <<< sudo-elevation <<<[[:space:]]*$/ { skip = 0; next }
		skip != 1 { print }
	'
}

strip_test_hooks() {
	awk '
		/^# >>> test hooks >>>[[:space:]]*$/ { skip = 1; next }
		/^# <<< test hooks <<<[[:space:]]*$/ { skip = 0; next }
		skip != 1 { print }
	'
}

check_foreign_askpass() {
	local tmp
	[ -f "$SE_SUDO_CONF" ] || return 0
	[ "$FORCE" = 1 ] && return 0
	tmp=$(mktemp)
	strip_block < "$SE_SUDO_CONF" > "$tmp"
	if grep -qE '^[[:space:]]*Path[[:space:]]+askpass([[:space:]]|$)' "$tmp"; then
		rm -f "$tmp"
		die "$SE_SUDO_CONF already configures a different askpass helper (use --force to take over)"
	fi
	rm -f "$tmp"
}

write_config() {
	local tmp
	tmp=$(mktemp)
	{
		printf '# sudo-elevation configuration (managed by install.sh).\n'
		printf '# Numeric values are minutes; fractions allowed.\n'
		printf 'BASE_MINUTES=%s\n' "$BASE_MINUTES"
		printf 'MAX_MINUTES=%s\n' "$MAX_MINUTES"
		printf 'DIALOG_TIMEOUT=%s\n' "$DIALOG_TIMEOUT"
		printf 'REQUEST_TTL=%s\n' "$REQUEST_TTL"
		printf 'GUI_BACKEND=auto\n'
	} > "$tmp"
	run se_install_file "$tmp" "$SE_CONFIG" 0644
	rm -f "$tmp"
}

write_sudo_conf() {
	local tmp
	tmp=$(mktemp)
	if [ -f "$SE_SUDO_CONF" ]; then
		strip_block < "$SE_SUDO_CONF" > "$tmp"
	else
		: > "$tmp"
	fi
	if [ "$FORCE" != 1 ] && grep -qE '^[[:space:]]*Path[[:space:]]+askpass([[:space:]]|$)' "$tmp"; then
		rm -f "$tmp"
		die "$SE_SUDO_CONF already configures a different askpass helper (use --force to take over)"
	fi
	{
		printf '# >>> sudo-elevation >>>\n'
		printf 'Path askpass %s\n' "$SE_BIN_DIR/sudo-askpass"
		printf '# <<< sudo-elevation <<<\n'
	} >> "$tmp"
	if [ "$DRY" = 1 ]; then
		say "[dry-run] update $SE_SUDO_CONF (marker block)"
		rm -f "$tmp"
		return 0
	fi
	if [ -f "$SE_SUDO_CONF" ]; then
		cp -a "$SE_SUDO_CONF" "$SE_SUDO_CONF.bak.$(date +%Y%m%d%H%M%S)"
		# Keep only the newest backup; repeated installs must not pile up.
		{ ls -1t "$SE_SUDO_CONF".bak.* 2>/dev/null || true; } | tail -n +2 | xargs -r rm -f -- || true
	fi
	se_install_file "$tmp" "$SE_SUDO_CONF" 0644
	rm -f "$tmp"
}

manifest_users() {
	local old
	if [ -f "$SE_SHARE/manifest" ]; then
		old=$(se_read_kv "$SE_SHARE/manifest" USERS || true)
		if [ -n "$old" ]; then
			case ",$old," in
				*",$TARGET_USER,"*) printf '%s' "$old"; return 0 ;;
				*) printf '%s' "$old,$TARGET_USER"; return 0 ;;
			esac
		fi
	fi
	printf '%s' "$TARGET_USER"
}

install_skill() {
	[ "$DO_SKILL" = 1 ] || return 0
	local home dir target base_human
	home=$(se_home_of "$TARGET_USER")
	[ -n "$home" ] || return 0
	dir=${SKILL_DIR:-$home/.config/opencode/skill/sudo-elevation}
	target="$dir/SKILL.md"
	base_human=$(se_human_minutes "$BASE_MINUTES")
	if [ "$DRY" = 1 ]; then
		say "[dry-run] install skill -> $target"
		return 0
	fi
	mkdir -p "$dir"
	sed -e "s/@@BASE_HUMAN@@/$base_human/g" \
		-e "s/@@VERSION@@/$VERSION/g" \
		"$REPO_DIR/templates/SKILL.md.in" > "$target"
	chmod 0644 "$target"
	if [ "$(id -u)" = 0 ]; then
		chown "$TARGET_USER" "$target" 2>/dev/null || true
		chown "$TARGET_USER" "$dir" 2>/dev/null || true
	fi
	say "installed skill: $target"
}

do_install() {
	if [ "$INSTALLED_MODE" = 1 ]; then
		die "install requires the repository checkout (the installed copy under libexec only supports --uninstall/--version/--help)"
	fi

	say "sudo-elevation $VERSION"
	say "  user: $TARGET_USER"
	say "  base window: $(se_human_minutes "$BASE_MINUTES")"
	say "  max lease:   $(se_human_minutes "$MAX_MINUTES")"
	say "  prefix:      ${PREFIX:-/}"

	command -v sudo >/dev/null 2>&1 || die "sudo not found"
	sudo_ver=$(sudo -V 2>/dev/null | head -n 1 || true)
	se_version_ge "$sudo_ver" "1.8.21" \
		|| die "sudo too old (${sudo_ver:-unknown}): >= 1.8.21 required (timestamp_type)"
	if ! command -v zenity >/dev/null 2>&1 && ! command -v kdialog >/dev/null 2>&1; then
		say "警告: 未找到 zenity/kdialog，GUI 弹窗不可用；"
		say "      'sudo-elevation request' 将失败，可用终端 'sudo-elevation grant' 审批。"
	fi

	check_foreign_askpass

	run install -d -m 0755 "$SE_BIN_DIR" "$SE_LIBEXEC" "$SE_SHARE" "$SE_SUDOERS_DIR"

	local f tmp_ask
	if [ "$TEST_HOOKS" = 1 ]; then
		run se_install_file "$REPO_DIR/bin/sudo-askpass" "$SE_BIN_DIR/sudo-askpass" 0755
	else
		tmp_ask=$(mktemp)
		strip_test_hooks < "$REPO_DIR/bin/sudo-askpass" > "$tmp_ask"
		run se_install_file "$tmp_ask" "$SE_BIN_DIR/sudo-askpass" 0755
		rm -f "$tmp_ask"
	fi
	run se_install_file "$REPO_DIR/bin/sudo-elevation" "$SE_BIN_DIR/sudo-elevation" 0755
	for f in grant restore; do
		run se_install_file "$REPO_DIR/libexec/sudo-elevation/$f" "$SE_LIBEXEC/$f" 0755
	done
	# Self-copy so `sudo-elevation uninstall` works without a repo checkout.
	run se_install_file "$REPO_DIR/install.sh" "$SE_LIBEXEC/install.sh" 0755
	run se_install_file "$REPO_DIR/libexec/sudo-elevation/common.sh" "$SE_LIBEXEC/common.sh" 0644
	run se_install_file "$REPO_DIR/VERSION" "$SE_SHARE/VERSION" 0644
	run se_install_file "$REPO_DIR/LICENSE" "$SE_SHARE/LICENSE" 0644
	SE_VERSION=$VERSION

	write_config
	write_sudo_conf

	local dest tmp
	dest="$SE_SUDOERS_DIR/90-sudo-elevation-$(se_user_slug "$TARGET_USER")"
	tmp=$(mktemp)
	se_render_sudoers "$TARGET_USER" "$BASE_MINUTES" "$tmp"
	if [ "$DRY" = 1 ]; then
		say "[dry-run] install $dest (timestamp_timeout=$BASE_MINUTES)"
		rm -f "$tmp"
	else
		se_install_sudoers "$tmp" "$dest" || die "failed to validate/install $dest"
		rm -f "$tmp"
		say "installed sudoers: $dest"
	fi

	tmp=$(mktemp)
	{
		printf 'VERSION=%s\n' "$VERSION"
		printf 'BASE_MINUTES=%s\n' "$BASE_MINUTES"
		printf 'MAX_MINUTES=%s\n' "$MAX_MINUTES"
		printf 'USERS=%s\n' "$(manifest_users)"
		if [ "$DO_SKILL" = 1 ]; then
			printf 'SKILL_DIR=%s\n' "${SKILL_DIR:-$(se_home_of "$TARGET_USER")/.config/opencode/skill/sudo-elevation}"
		fi
	} > "$tmp"
	run se_install_file "$tmp" "$SE_SHARE/manifest" 0644
	rm -f "$tmp"

	install_skill

	if [ "$DRY" != 1 ] && [ "$(id -u)" = 0 ] && [ -z "$SE_PREFIX" ]; then
		visudo -c >/dev/null || die "sudoers validation failed"
		sudo -V >/dev/null 2>&1 || die "sudo.conf could not be parsed"
	fi

	say ""
	say "完成。下一步："
	say "  sudo -v                         # 或在 agent 中: sudo-elevation request --for 2h --reason \"...\""
	say "  sudo-elevation status"
}

do_uninstall() {
	local users u arr lease mech pid home sk tmp skdir
	users=""
	skdir=""
	if [ -f "$SE_SHARE/manifest" ]; then
		users=$(se_read_kv "$SE_SHARE/manifest" USERS || true)
		skdir=$(se_read_kv "$SE_SHARE/manifest" SKILL_DIR || true)
	fi
	[ -n "$SKILL_DIR" ] && skdir=$SKILL_DIR
	[ -n "$users" ] || users=$TARGET_USER
	IFS=',' read -r -a arr <<< "$users,$TARGET_USER"

	for u in "${arr[@]}"; do
		[ -n "$u" ] || continue
		se_valid_user "$u" || continue

		lease=$(se_lease_file "$u")
		if [ -f "$lease" ]; then
			mech=$(se_read_kv "$lease" restore || true)
			pid=${mech##*pid=}
			pid=${pid%%:*}
			case "$pid" in
				''|*[!0-9]*) ;;
				*) if kill -0 "$pid" 2>/dev/null; then run kill "$pid" || true; fi ;;
			esac
			run rm -f "$lease"
		fi
		run rm -f "$SE_SUDOERS_DIR/90-sudo-elevation-$(se_user_slug "$u")"

		if [ "$DRY" != 1 ] && [ "$(id -u)" = 0 ] && [ -z "$SE_PREFIX" ] \
		   && command -v runuser >/dev/null 2>&1; then
			runuser -u "$u" -- sudo -k >/dev/null 2>&1 || true
		fi

		home=$(se_home_of "$u")
		if [ -n "$skdir" ]; then
			if [ -f "$skdir/SKILL.md" ] && grep -q 'sudo-elevation' "$skdir/SKILL.md"; then
				run rm -f "$skdir/SKILL.md"
			fi
			rmdir "$skdir" 2>/dev/null || true
		elif [ -n "$home" ]; then
			sk="$home/.config/opencode/skill/sudo-elevation"
			[ -f "$sk/SKILL.md" ] && grep -q 'sudo-elevation' "$sk/SKILL.md" && run rm -f "$sk/SKILL.md"
			rmdir "$sk" 2>/dev/null || true
		fi
	done

	if [ -f "$SE_SUDO_CONF" ] && grep -q '^# >>> sudo-elevation >>>' "$SE_SUDO_CONF"; then
		if [ "$DRY" = 1 ]; then
			say "[dry-run] remove marker block from $SE_SUDO_CONF"
		else
			tmp=$(mktemp)
			strip_block < "$SE_SUDO_CONF" > "$tmp"
			se_install_file "$tmp" "$SE_SUDO_CONF" 0644
			rm -f "$tmp"
		fi
	fi

	run rm -f "$SE_BIN_DIR/sudo-askpass" "$SE_BIN_DIR/sudo-elevation"
	run rm -f "$SE_LIBEXEC/common.sh" "$SE_LIBEXEC/grant" "$SE_LIBEXEC/restore" "$SE_LIBEXEC/install.sh"
	rmdir "$SE_LIBEXEC" 2>/dev/null || true
	run rm -f "$SE_SHARE/VERSION" "$SE_SHARE/LICENSE" "$SE_SHARE/manifest"
	rmdir "$SE_SHARE" 2>/dev/null || true
	run rm -f "$SE_CONFIG"
	rm -f "$SE_SUDO_CONF".bak.* 2>/dev/null || true
	rmdir "$SE_RUNTIME_DIR" 2>/dev/null || true
	[ "$PURGE" = 1 ] && run rm -f "$SE_LOG"

	if [ "$DRY" != 1 ] && [ "$(id -u)" = 0 ] && [ -z "$SE_PREFIX" ]; then
		visudo -c >/dev/null || die "sudoers validation failed after uninstall"
		sudo -V >/dev/null 2>&1 || die "sudo.conf could not be parsed after uninstall"
	fi
	say "sudo-elevation: 卸载完成"
}

BASE_MINUTES=$(se_parse_minutes "$BASE_SPEC") || die "invalid --base-timeout: $BASE_SPEC"
MAX_MINUTES=$(se_parse_minutes "$MAX_SPEC") || die "invalid --max-timeout: $MAX_SPEC"
[ "$BASE_MINUTES" = "-1" ] && die "--base-timeout cannot be -1 (use runtime until-lock instead)"
se_valid_minutes "$BASE_MINUTES" || die "--base-timeout out of range: $BASE_SPEC"
se_valid_minutes "$MAX_MINUTES" || die "--max-timeout out of range: $MAX_SPEC"
awk -v b="$BASE_MINUTES" -v m="$MAX_MINUTES" 'BEGIN{exit !(b+0 <= m+0)}' \
	|| die "--base-timeout must be <= --max-timeout"

if [ "$ACTION" = uninstall ]; then
	do_uninstall
else
	do_install
fi
