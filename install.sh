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
USER_INSTALL=0
NO_SYSTEM=0
SE_NEW_BAK=""

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
run() {
	if [ "$DRY" = 1 ]; then say "[dry-run] $*"; else "$@"; fi
}
# Directory creation honoring user mode: when root installs into a user's
# home, build user-owned trees via runuser so later unattended reinstalls work.
mk_dir() {
	if [ "$USER_INSTALL" = 1 ] && [ "$(id -u)" = 0 ] && command -v runuser >/dev/null 2>&1; then
		run runuser -u "$TARGET_USER" -- install -d -m 0755 "$@"
	else
		run install -d -m 0755 "$@"
	fi
}

usage() {
	cat <<'EOF'
usage: sudo ./install.sh [options]

options:
  --user USER           target user (default: $SUDO_USER or current user)
  --base-timeout SPEC   base window (default 15m; examples: 15m, 30m; strict: 0)
  --max-timeout SPEC    maximum approvable lease (default 365d; non-build hosts: 12h/7d)
  --prefix DIR          install everything under DIR (testing/sandbox; not with --user-install)
  --user-install        XDG user layout: payload into ~/.local, config into
                        ~/.config (no /usr/local pollution). System files
                        (sudoers drop-in, sudo.conf marker) still need root
                        unless --no-system is given.
  --no-system           never touch system directories (sudoers drop-in,
                        sudo.conf marker, /usr/local, /etc, /run, /var/log);
                        without --prefix this implies the --user-install
                        layout for the target user (root included), printing
                        the exact root snippet for an admin instead.
                        Without the snippet applied the tool stays inert.
  --skill-dir DIR       override opencode skill directory
  --no-skill            do not install the opencode skill
  --test-hooks          keep fake/print test hooks in the installed askpass
                        (for the test-suite only; default strips them)
  --dry-run             print actions without changing anything
  --force               take over an existing foreign `Path askpass` setting
  --uninstall           remove software but keep config (sudoers at base window,
                        sudo.conf marker, config, manifest, skill, audit log)
  --purge               with --uninstall: remove config and ALL data too,
                        including files for users missing from the manifest
                        (use when the old data itself is suspect)
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
		--user-install) USER_INSTALL=1; shift ;;
		--no-system) NO_SYSTEM=1; shift ;;
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

[ "$USER_INSTALL" = 1 ] && [ -n "$PREFIX" ] && die "--user-install cannot be combined with --prefix"

# --no-system means "touch no system directory", no matter who runs (root
# included: root gets root's own XDG homes). Without --prefix there is no
# other non-system layout, so it implies --user-install for TARGET_USER.
# Install-time only: uninstall honors the recorded manifest layout, so
# pre-fix installs (payload under /usr/local) still clean up where they
# actually wrote.
if [ "$ACTION" = install ] && [ "$NO_SYSTEM" = 1 ] && [ "$USER_INSTALL" = 0 ] && [ -z "$PREFIX" ]; then
	say "--no-system: using user layout for $TARGET_USER (no system directories touched)"
	USER_INSTALL=1
fi

# XDG user layout must be resolved BEFORE common.sh is sourced: it computes
# every SE_* path at source time. getent is used directly (se_home_of lives
# in common.sh). Only the target user's own XDG env is honored; otherwise
# defaults under their $HOME apply (root's XDG_* must never leak in).
if [ "$USER_INSTALL" = 1 ]; then
	_UI_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)
	[ -n "$_UI_HOME" ] || die "cannot find home for $TARGET_USER"
	if [ "$(id -un)" = "$TARGET_USER" ]; then
		_UI_DATA=${XDG_DATA_HOME:-$_UI_HOME/.local/share}
		_UI_CONF=${XDG_CONFIG_HOME:-$_UI_HOME/.config}
		_UI_STATE=${XDG_STATE_HOME:-$_UI_HOME/.local/state}
	else
		_UI_DATA=$_UI_HOME/.local/share
		_UI_CONF=$_UI_HOME/.config
		_UI_STATE=$_UI_HOME/.local/state
	fi
	export SUDO_ELEVATION_BINDIR="$_UI_HOME/.local/bin"
	export SUDO_ELEVATION_LIBEXECDIR="$_UI_HOME/.local/libexec/sudo-elevation"
	export SUDO_ELEVATION_SHAREDIR="$_UI_DATA/sudo-elevation"
	export SUDO_ELEVATION_CONFIG="$_UI_CONF/sudo-elevation/config"
	export SUDO_ELEVATION_INSTALL_MODE=user
fi

if [ -n "$PREFIX" ]; then export SUDO_ELEVATION_PREFIX=$PREFIX; fi
if [ "$INSTALLED_MODE" = 1 ]; then
	# shellcheck source=common.sh
	. "$SELF_DIR/common.sh"
else
	# shellcheck source=libexec/sudo-elevation/common.sh
	. "$REPO_DIR/libexec/sudo-elevation/common.sh"
fi

# System files (sudoers drop-in, sudo.conf marker) always need root, no
# matter the layout. --no-system skips them (fully unprivileged degraded
# install); anything else without root (and without --prefix sandbox) dies.
if [ "$NO_SYSTEM" = 0 ] && [ "$(id -u)" != 0 ] && [ -z "$PREFIX" ]; then
	die "must run as root (sudo ./install.sh), or add --no-system for a degraded user install"
fi

strip_block() {
	# Remove our marker block(s). Fail closed on an unclosed opening marker
	# instead of silently dropping the file tail.
	awk '
		/^# >>> sudo-elevation >>>[[:space:]]*$/ { skip = 1; next }
		/^# <<< sudo-elevation <<<[[:space:]]*$/ { skip = 0; next }
		skip != 1 { print }
		END { if (skip == 1) exit 1 }
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
	[ "$NO_SYSTEM" = 1 ] && return 0
	[ -f "$SE_SUDO_CONF" ] || return 0
	[ "$FORCE" = 1 ] && return 0
	tmp=$(mktemp)
	strip_block < "$SE_SUDO_CONF" > "$tmp" \
		|| { rm -f "$tmp"; die "$SE_SUDO_CONF has an unclosed sudo-elevation block (refusing to guess)" ; }
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
		strip_block < "$SE_SUDO_CONF" > "$tmp" \
			|| { rm -f "$tmp"; die "$SE_SUDO_CONF has an unclosed sudo-elevation block (refusing to rewrite)" ; }
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
	if [ "$NO_SYSTEM" = 1 ]; then
		rm -f "$tmp"
		SE_NEW_BAK=""
		return 0
	fi
	if [ -f "$SE_SUDO_CONF" ]; then
		# Backup names carry PID so two installs within the same second
		# never collide; prune keeps only the newest OWN backup. Admin files
		# matching bak.* but not our strict shape are never touched.
		SE_NEW_BAK="$SE_SUDO_CONF.bak.$(date +%Y%m%d%H%M%S).$$"
		cp -a "$SE_SUDO_CONF" "$SE_NEW_BAK"
		# cp -a preserves the source mtime; bump to now so the just-created
		# backup is unambiguously newest among our own (no ls -t lottery).
		touch "$SE_NEW_BAK"
		# Keep only this backup; repeated installs must not pile up.
		# Loop instead of xargs so unusual filenames stay safe; skip self
		# and anything that is not our own strict backup shape.
		for old in "$SE_SUDO_CONF".bak.*; do
			[ -e "$old" ] || continue
			[ "$old" = "$SE_NEW_BAK" ] && continue
			se_own_backup "$old" || continue
			rm -f -- "$old" || true
		done
		SE_NEW_BAK=$(basename "$SE_NEW_BAK")
	else
		SE_NEW_BAK=""
	fi
	se_install_file "$tmp" "$SE_SUDO_CONF" 0644
	rm -f "$tmp"
}

# Root snippet for --no-system: the two blocks an admin must apply.
print_system_snippet() {
	local dest
	dest="$SE_SUDOERS_DIR/90-sudo-elevation-$(se_user_slug "$TARGET_USER")"
	say ""
	say "--no-system: system files were NOT touched. Ask an admin to apply:"
	say "  1) sudoers drop-in $dest :"
	say "       Defaults:$TARGET_USER timestamp_type=global"
	say "       Defaults:$TARGET_USER timestamp_timeout=$BASE_MINUTES"
	say "  2) append to $SE_SUDO_CONF :"
	say "       # >>> sudo-elevation >>>"
	say "       Path askpass $SE_BIN_DIR/sudo-askpass"
	say "       # <<< sudo-elevation <<<"
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
	local home dir target base_human_en esc_base esc_ver
	home=$(se_home_of "$TARGET_USER")
	[ -n "$home" ] || return 0
	dir=${SKILL_DIR:-$home/.config/opencode/skill/sudo-elevation}
	target="$dir/SKILL.md"
	base_human_en=$(se_human_minutes_en "$BASE_MINUTES")
	if [ "$DRY" = 1 ]; then
		say "[dry-run] install skill -> $target"
		return 0
	fi
	mkdir -p "$dir"
	# '|' delimiter plus '&' escape: future English duration text must not
	# break the substitution even if it ever contains '/' or '&'.
	esc_base=$(printf '%s' "$base_human_en" | sed -e 's/[&|\\]/\\&/g')
	esc_ver=$(printf '%s' "$VERSION" | sed -e 's/[&|\\]/\\&/g')
	sed -e "s|@@BASE_HUMAN_EN@@|$esc_base|g" \
		-e "s|@@VERSION@@|$esc_ver|g" \
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

	if [ "$NO_SYSTEM" = 1 ]; then
		mk_dir "$SE_BIN_DIR" "$SE_LIBEXEC" "$SE_SHARE"
	else
		mk_dir "$SE_BIN_DIR" "$SE_LIBEXEC" "$SE_SHARE"
		run install -d -m 0755 "$SE_SUDOERS_DIR"
	fi
	# Config/receipt live in files whose parent may not exist (XDG homes).
	mk_dir "$(dirname "$SE_CONFIG")"

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
	elif [ "$NO_SYSTEM" = 1 ]; then
		# Still validate the rendered drop-in so the admin snippet is known good.
		visudo -cf "$tmp" >/dev/null 2>&1 || die "rendered sudoers failed validation"
		rm -f "$tmp"
		say "[no-system] skip $dest (see snippet below)"
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
		printf 'INSTALL_MODE=%s\n' "$([ "$USER_INSTALL" = 1 ] && printf user || printf system)"
		printf 'SYSTEM=%s\n' "$([ "$NO_SYSTEM" = 1 ] && printf 0 || printf 1)"
		printf 'SUDO_CONF_BAK=%s\n' "$SE_NEW_BAK"
		if [ "$USER_INSTALL" = 1 ]; then
			printf 'BINDIR=%s\n' "$SE_BIN_DIR"
			printf 'LIBEXECDIR=%s\n' "$SE_LIBEXEC"
			printf 'SHAREDIR=%s\n' "$SE_SHARE"
			printf 'CONFIG=%s\n' "$SE_CONFIG"
		fi
		if [ "$DO_SKILL" = 1 ]; then
			printf 'SKILL_DIR=%s\n' "${SKILL_DIR:-$(se_home_of "$TARGET_USER")/.config/opencode/skill/sudo-elevation}"
		fi
	} > "$tmp"
	run se_install_file "$tmp" "$SE_SHARE/manifest" 0644
	rm -f "$tmp"

	install_skill
	write_receipt
	chown_user_payload

	if [ "$DRY" != 1 ] && [ "$NO_SYSTEM" != 1 ] && [ "$(id -u)" = 0 ] && [ -z "$SE_PREFIX" ]; then
		visudo -c >/dev/null || die "sudoers validation failed"
		sudo -V >/dev/null 2>&1 || die "sudo.conf could not be parsed"
	fi

	if [ "$NO_SYSTEM" = 1 ]; then
		print_system_snippet
	fi

	say ""
	say "完成。下一步："
	say "  sudo -v                         # 或在 agent 中: sudo-elevation request --for 2h --reason \"...\""
	say "  sudo-elevation status"
}

# User-install receipt: lets the installed CLI resolve user paths without
# exports (explicit env still wins). Paths only, no secrets.
write_receipt() {
	[ "$USER_INSTALL" = 1 ] || return 0
	[ "$DO_SKILL" = 1 ] || true
	local home conf_home dir target tmp
	home=$(se_home_of "$TARGET_USER")
	[ -n "$home" ] || return 0
	if [ "$(id -un)" = "$TARGET_USER" ]; then
		conf_home=${XDG_CONFIG_HOME:-$home/.config}
	else
		conf_home=$home/.config
	fi
	dir="$conf_home/sudo-elevation"
	target="$dir/env"
	if [ "$DRY" = 1 ]; then
		say "[dry-run] install receipt -> $target"
		return 0
	fi
	tmp=$(mktemp)
	{
		printf '# Managed by sudo-elevation install.sh --user-install.\n'
		printf 'SUDO_ELEVATION_BINDIR=%s\n' "$SE_BIN_DIR"
		printf 'SUDO_ELEVATION_LIBEXECDIR=%s\n' "$SE_LIBEXEC"
		printf 'SUDO_ELEVATION_SHAREDIR=%s\n' "$SE_SHARE"
		printf 'SUDO_ELEVATION_CONFIG=%s\n' "$SE_CONFIG"
	} > "$tmp"
	mk_dir "$dir"
	run se_install_file "$tmp" "$target" 0644
	rm -f "$tmp"
	if [ "$(id -u)" = 0 ]; then
		chown "$TARGET_USER" "$target" 2>/dev/null || true
		chown "$TARGET_USER" "$dir" 2>/dev/null || true
	fi
	say "installed receipt: $target"
}

# In user mode the payload belongs to the target user even when root runs
# the installer (se_install_file would otherwise chown root). Only our own
# files are touched: never chown -R a shared dir like ~/.local/bin.
chown_user_payload() {
	[ "$USER_INSTALL" = 1 ] || return 0
	[ "$(id -u)" = 0 ] || return 0
	[ "$DRY" = 1 ] && return 0
	chown "$TARGET_USER" "$SE_BIN_DIR/sudo-askpass" "$SE_BIN_DIR/sudo-elevation" 2>/dev/null || true
	chown -R "$TARGET_USER" "$SE_LIBEXEC" "$SE_SHARE" 2>/dev/null || true
	chown "$TARGET_USER" "$SE_CONFIG" 2>/dev/null || true
}

# Our own sudoers drop-ins carry this header (see se_render_sudoers).
# Ghost sweep must not delete an admin's hand-made file that merely shares
# the 90-sudo-elevation-* prefix: require the marker, fail closed otherwise.
se_is_own_sudoers() {
	local f=${1-}
	[ -f "$f" ] || return 1
	grep -q 'Managed by sudo-elevation' "$f" 2>/dev/null
}

# Our own lease files carry epoch + minutes/restore keys (see se_write_lease
# and grant). Sweep must not delete a foreign *.lease that merely lands in a
# redirected RUNTIME_DIR: require the keys, fail closed otherwise.
se_is_own_lease() {
	local f=${1-}
	[ -f "$f" ] || return 1
	grep -q '^epoch=' "$f" 2>/dev/null || return 1
	grep -qE '^(minutes|restore)=' "$f" 2>/dev/null
}

# Only kill sleepers that look like our scheduled restore (setsid sh -c
# "sleep ...; exec .../restore ..." or systemd path). Never kill an arbitrary
# pid recorded in a hand-made lease file.
se_safe_kill_restore_pid() {
	local pid=${1-}
	case "$pid" in ''|*[!0-9]*) return 0 ;; esac
	if [ -r "/proc/$pid/cmdline" ]; then
		if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE 'restore|sudo-elevation|(^| )sleep( |$)'; then
			run kill "$pid" || true
		else
			say "warning: not killing foreign pid $pid" >&2
		fi
	else
		if kill -0 "$pid" 2>/dev/null; then run kill "$pid" || true; fi
	fi
}
# Config/log deletion guard: SUDO_ELEVATION_CONFIG/LOG are env-redirectable.
# Only delete files that look like ours (name + content marker); otherwise
# preserve with a warning so a redirected purge never eats an arbitrary file.
se_is_own_config() {
	local f=${1-}
	[ -n "$f" ] || return 1
	[ -e "$f" ] || return 0
	case "${f##*/}" in
		sudo-elevation.conf|config) ;;
		*) return 1 ;;
	esac
	[ ! -s "$f" ] && return 0
	grep -q 'sudo-elevation configuration' "$f" 2>/dev/null
}

se_is_own_log() {
	local f=${1-}
	[ -n "$f" ] || return 1
	[ -e "$f" ] || return 0
	case "${f##*/}" in
		sudo-elevation.log) ;;
		*) return 1 ;;
	esac
	[ ! -s "$f" ] && return 0
	grep -q 'actor=' "$f" 2>/dev/null
}
# Skill deletion guard: only remove our own rendered SKILL.md (anchored
# marker from templates/SKILL.md.in), never a third-party file that merely
# mentions the name. Path must be absolute and not filesystem root.
se_safe_rm_skill() {
	local dir=${1-}
	case "$dir" in
		/*) ;;
		*) say "warning: refusing non-absolute skill dir: $dir" >&2; return 0 ;;
	esac
	if [ "$dir" = "/" ]; then
		say "warning: refusing skill dir /" >&2
		return 0
	fi
	if [ -f "$dir/SKILL.md" ] && grep -q 'sudo-elevation request' "$dir/SKILL.md" 2>/dev/null; then
		run rm -f -- "$dir/SKILL.md"
	else
		[ -f "$dir/SKILL.md" ] && say "warning: preserving non-sudo-elevation skill: $dir/SKILL.md" >&2 || true
	fi
	run rmdir "$dir" 2>/dev/null || true
}
# Our own sudo.conf backup names: bak.YYYYMMDDHHMMSS[.PID]. Used to tell
# our backups apart from an admin's own files (never delete those).
se_own_backup() {
	local base=${1##*/}
	case "$base" in
		sudo.conf.bak.*) ;;
		*) return 1 ;;
	esac
	base=${base#sudo.conf.bak.}
	printf '%s' "$base" | grep -Eq '^[0-9]{14}(\.[0-9]+)?$'
}

# Warn when the manifest's recorded layout disagrees with the requested one
# (e.g. XDG drift between install and uninstall). Advisory only.
check_manifest_layout() {
	[ "$USER_INSTALL" = 1 ] || return 0
	[ -f "$SE_SHARE/manifest" ] || return 0
	local k want got
	for k in BINDIR LIBEXECDIR SHAREDIR CONFIG; do
		want=$(se_read_kv "$SE_SHARE/manifest" "$k" || true)
		[ -n "$want" ] || continue
		case "$k" in
			BINDIR) got=$SE_BIN_DIR ;;
			LIBEXECDIR) got=$SE_LIBEXEC ;;
			SHAREDIR) got=$SE_SHARE ;;
			CONFIG) got=$SE_CONFIG ;;
		esac
		if [ "$want" != "$got" ]; then
			say "warning: manifest $k=$want differs from requested $got; using requested" >&2
		fi
	done
}

do_uninstall() {
	local users u arr lease mech pid home sk tmp skdir bak dest _bak _bpath _ghost _lease _ui_home _ui_conf
	users=""
	skdir=""
	bak=""
	se_load_config
	if [ -f "$SE_SHARE/manifest" ]; then
		users=$(se_read_kv "$SE_SHARE/manifest" USERS || true)
		skdir=$(se_read_kv "$SE_SHARE/manifest" SKILL_DIR || true)
		bak=$(se_read_kv "$SE_SHARE/manifest" SUDO_CONF_BAK || true)
		# Dirty manifests (pre-fix installs could record an admin file as
		# SUDO_CONF_BAK) must never lead to deleting it: validate early.
		if [ -n "$bak" ] && ! se_own_backup "$bak"; then
			say "warning: odd recorded backup name, ignoring: $bak" >&2
			bak=""
		fi
		check_manifest_layout
	fi
	[ -n "$SKILL_DIR" ] && skdir=$SKILL_DIR
	[ -n "$users" ] || users=$TARGET_USER
	IFS=',' read -r -a arr <<< "$users,$TARGET_USER"
	# --no-system never touches /etc or /run (unprivileged): user payload
	# only, plus a manual snippet for the admin at the end.
	SYS_OK=1
	[ "$NO_SYSTEM" = 1 ] && SYS_OK=0

	if [ "$PURGE" = 1 ]; then
		say "uninstall --purge: removing config and ALL sudo-elevation data (no mercy)"
	else
		say "uninstall: removing software, keeping config (add --purge to delete everything)"
	fi

	# Phase 1 (both modes): end leases and pin every managed sudoers file to
	# the base window FIRST, while helpers still exist. Deleting a lease file
	# without restoring would strand sudoers at the lease timeout forever.
	for u in "${arr[@]}"; do
		[ -n "$u" ] || continue
		se_valid_user "$u" || continue

		lease=$(se_lease_file "$u")
		if [ -f "$lease" ]; then
			mech=$(se_read_kv "$lease" restore || true)
			pid=${mech##*pid=}
			pid=${pid%%:*}
			# NOTE: only setsid sleepers are tracked. systemd transient
			# timers are not cancelled here; they self-exit (no lease ->
			# restore prints nothing-to-do without touching sudoers).
			se_safe_kill_restore_pid "$pid"
		fi
		dest="$SE_SUDOERS_DIR/90-sudo-elevation-$(se_user_slug "$u")"
		if [ "$DRY" = 1 ]; then
			say "[dry-run] restore base sudoers for $u + clear cache"
		elif [ "$SYS_OK" != 1 ]; then
			say "[no-system] skip lease/sudoers for $u (admin snippet below)"
		elif [ -x "$SE_LIBEXEC/restore" ] && "$SE_LIBEXEC/restore" --user "$u" --force >/dev/null 2>&1; then
			: # restore cleared cache, pinned base, removed the lease
		else
			# Fallback (non-root sandbox, missing helper): pin base directly.
			tmp=$(mktemp)
			se_render_sudoers "$u" "$BASE_MINUTES" "$tmp"
			if [ "$(id -u)" = 0 ] && [ -z "$SE_PREFIX" ]; then
				se_install_sudoers "$tmp" "$dest" || true
			else
				se_install_sudoers "$tmp" "$dest" >/dev/null 2>&1 || true
			fi
			rm -f "$tmp" "$lease" 2>/dev/null || true
		fi

		if [ "$DRY" != 1 ] && [ "$(id -u)" = 0 ] && [ -z "$SE_PREFIX" ] \
		   && [ "$NO_SYSTEM" != 1 ] \
		   && command -v runuser >/dev/null 2>&1; then
			runuser -u "$u" -- sudo -k >/dev/null 2>&1 || true
		fi
	done

	# Phase 2 (both modes): remove software payload.
	run rm -f "$SE_BIN_DIR/sudo-askpass" "$SE_BIN_DIR/sudo-elevation"
	run rm -f "$SE_LIBEXEC/common.sh" "$SE_LIBEXEC/grant" "$SE_LIBEXEC/restore" "$SE_LIBEXEC/install.sh"
	run rmdir "$SE_LIBEXEC" 2>/dev/null || true
	run rm -f "$SE_SHARE/VERSION" "$SE_SHARE/LICENSE"
	if [ "$PURGE" = 1 ]; then
		run rm -f "$SE_SHARE/manifest"
	fi
	run rmdir "$SE_SHARE" 2>/dev/null || true
	if [ "$PURGE" = 1 ]; then
		# Tidy parents created for user installs (only empty dirs go).
		run rmdir "$(dirname "$SE_LIBEXEC")" 2>/dev/null || true
		run rmdir "$(dirname "$SE_SHARE")" 2>/dev/null || true
	fi

	if [ "$PURGE" != 1 ]; then
		say "sudo-elevation: 软件已卸载，配置保留（sudoers 基窗/marker/配置/manifest/skill/审计）"
		say "sudo-elevation: 需要删干净时用 --purge；sudo -A 在重装前不可用（askpass 已删），普通 sudo 不受影响"
		[ "$SYS_OK" = 1 ] || print_uninstall_snippet
		return 0
	fi

	# Phase 3 (purge only): delete config and every sudo-elevation trace,
	# including users missing from the manifest (suspect data included).
	for u in "${arr[@]}"; do
		[ -n "$u" ] || continue
		se_valid_user "$u" || continue
		if [ "$SYS_OK" = 1 ]; then
			run rm -f "$SE_SUDOERS_DIR/90-sudo-elevation-$(se_user_slug "$u")"
		fi

		home=$(se_home_of "$u")
		if [ -n "$skdir" ]; then
			se_safe_rm_skill "$skdir"
		elif [ -n "$home" ]; then
			sk="$home/.config/opencode/skill/sudo-elevation"
			se_safe_rm_skill "$sk"
		fi
	done
	# Ghost sweep: drop-ins for users the manifest never knew. Only our own
	# rendered files (marker header) go; an admin hand-made file sharing the
	# prefix is preserved with a warning.
	if [ "$SYS_OK" = 1 ]; then
		for _ghost in "$SE_SUDOERS_DIR"/90-sudo-elevation-*; do
			[ -e "$_ghost" ] || continue
			if se_is_own_sudoers "$_ghost"; then
				run rm -f "$_ghost"
			else
				say "warning: preserving non-sudo-elevation file: $_ghost" >&2
			fi
		done
	fi
	# Ghost sweep: leases (kill tracked sleepers first). Foreign *.lease files
	# without our keys (e.g. in a redirected RUNTIME_DIR) are preserved.
	if [ "$SYS_OK" = 1 ]; then
		for _lease in "$SE_RUNTIME_DIR"/*.lease; do
			[ -f "$_lease" ] || continue
			if ! se_is_own_lease "$_lease"; then
				say "warning: preserving non-sudo-elevation lease: $_lease" >&2
				continue
			fi
			mech=$(se_read_kv "$_lease" restore || true)
			pid=${mech##*pid=}
			pid=${pid%%:*}
			se_safe_kill_restore_pid "$pid"
			run rm -f "$_lease"
		done
	fi

	if [ "$SYS_OK" = 1 ] && [ -f "$SE_SUDO_CONF" ] && grep -q '^# >>> sudo-elevation >>>' "$SE_SUDO_CONF"; then
		if [ "$DRY" = 1 ]; then
			say "[dry-run] remove marker block from $SE_SUDO_CONF"
		else
			tmp=$(mktemp)
			strip_block < "$SE_SUDO_CONF" > "$tmp" \
				|| { rm -f "$tmp"; die "$SE_SUDO_CONF has an unclosed sudo-elevation block (refusing to rewrite)" ; }
			se_install_file "$tmp" "$SE_SUDO_CONF" 0644
			rm -f "$tmp"
		fi
	fi

	if se_is_own_config "$SE_CONFIG"; then
		run rm -f "$SE_CONFIG"
	else
		say "warning: preserving non-sudo-elevation config: $SE_CONFIG" >&2
	fi
	# Backups live next to the system sudo.conf: purge-only and SYS_OK-only.
	# The manifest-recorded basename always; legacy ones only when they
	# match our own strict name shape (an admin's bak.* files are kept).
	if [ "$SYS_OK" != 1 ]; then
		say "[no-system] skip sudo.conf backups (admin snippet below)"
	fi
	if [ "$SYS_OK" = 1 ] && [ -n "$bak" ]; then
		case "$bak" in
			*/*) say "warning: odd recorded backup name, skipping: $bak" >&2 ;;
			*)
				_bpath="${SE_SUDO_CONF%/*}/$bak"
				if se_own_backup "$_bpath"; then
					run rm -f "$_bpath"
				else
					say "warning: odd recorded backup name, skipping: $bak" >&2
				fi
				;;
		esac
	fi
	if [ "$SYS_OK" = 1 ]; then
		for _bak in "$SE_SUDO_CONF".bak.*; do
			[ -e "$_bak" ] || continue
			se_own_backup "$_bak" || continue
			run rm -f "$_bak"
		done
	fi
	# User-install receipt belongs to the install and goes with purge.
	if [ "$USER_INSTALL" = 1 ]; then
		_ui_home=$(se_home_of "$TARGET_USER")
		if [ -n "$_ui_home" ]; then
			if [ "$(id -un)" = "$TARGET_USER" ]; then
				_ui_conf=${XDG_CONFIG_HOME:-$_ui_home/.config}
			else
				_ui_conf=$_ui_home/.config
			fi
			run rm -f "$_ui_conf/sudo-elevation/env"
			run rmdir "$_ui_conf/sudo-elevation" 2>/dev/null || true
		fi
	fi
	if [ "$SYS_OK" = 1 ]; then
		run rmdir "$SE_RUNTIME_DIR" 2>/dev/null || true
		if se_is_own_log "$SE_LOG"; then
			run rm -f "$SE_LOG"
		else
			say "warning: preserving non-sudo-elevation log: $SE_LOG" >&2
		fi
	fi

	if [ "$DRY" != 1 ] && [ "$SYS_OK" = 1 ] && [ "$(id -u)" = 0 ] && [ -z "$SE_PREFIX" ]; then
		visudo -c >/dev/null || die "sudoers validation failed after uninstall"
		sudo -V >/dev/null 2>&1 || die "sudo.conf could not be parsed after uninstall"
	fi
	if [ "$SYS_OK" != 1 ]; then
		print_uninstall_snippet
	fi
	say "sudo-elevation: 卸载完成"
}

# Manual snippet for --no-system uninstall: system files the admin removes.
print_uninstall_snippet() {
	local u
	say ""
	say "--no-system: system files were NOT touched. Ask an admin to remove:"
	for u in "${arr[@]}"; do
		[ -n "$u" ] || continue
		se_valid_user "$u" || continue
		say "  rm -f $SE_SUDOERS_DIR/90-sudo-elevation-$(se_user_slug "$u")"
	done
	say "  (strip the '# >>> sudo-elevation >>>' block from $SE_SUDO_CONF)"
	say "  rm -f $SE_RUNTIME_DIR/*.lease   # then rmdir it; also: sudo -k per user"
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
