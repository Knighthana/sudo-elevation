#!/bin/bash
# sudo-elevation - shared shell library.
#
# Sourced by grant, restore, sudo-elevation and sudo-askpass.
# NEVER source untrusted files. All user-supplied files are parsed with
# se_read_kv and validated; no eval is ever used on external data.
#
# SUDO_ELEVATION_PREFIX may be set to relocate every system path (used by
# the test-suite to run the installer inside a sandbox).
#
# Per-directory overrides (used by --user-install; explicit env wins):
#   SUDO_ELEVATION_BINDIR / LIBEXECDIR / SHAREDIR / CONFIG (file) /
#   SUDO_CONF / SUDOERS_DIR / RUNTIME_DIR / LOG
# When none are set, a user-install receipt at
# ${XDG_CONFIG_HOME:-$HOME/.config}/sudo-elevation/env (written by the
# installer) is picked up automatically. Only whitelisted keys with a safe
# charset are accepted; never eval'd.
#
# shellcheck disable=SC2034  # SE_*/config vars are consumed by sourcing scripts

SE_PREFIX="${SUDO_ELEVATION_PREFIX:-}"

se_path() { printf '%s%s' "$SE_PREFIX" "$1"; }

se_load_receipt() {
	# $1 = probing flag: when 1, missing receipt is fine (normal case).
	local receipt conf_home line key val
	conf_home=${XDG_CONFIG_HOME:-${HOME:-}/.config}
	[ -n "$conf_home" ] && [ "$conf_home" != /.config ] || return 0
	receipt="$conf_home/sudo-elevation/env"
	[ -f "$receipt" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%$'\r'}
		case "$line" in ''|'#'*) continue ;; esac
		case "$line" in *=*) ;; *) continue ;; esac
		key=${line%%=*}
		val=${line#*=}
		case "$key" in
			SUDO_ELEVATION_BINDIR|SUDO_ELEVATION_LIBEXECDIR|SUDO_ELEVATION_SHAREDIR|\
			SUDO_ELEVATION_CONFIG|SUDO_ELEVATION_SUDO_CONF|SUDO_ELEVATION_SUDOERS_DIR|\
			SUDO_ELEVATION_RUNTIME_DIR|SUDO_ELEVATION_LOG) ;;
			*) continue ;;
		esac
		# Absolute paths only; spaces allowed ($HOME may contain them), but
		# shell-active chars are rejected: values are interpolated inside
		# double quotes (se_schedule_restore) and must stay inert.
		case "$val" in /*) ;; *) continue ;; esac
		case "$val" in *'"'*|*'`'*|*'$'*|*'\'*) continue ;; esac
		# shellcheck disable=SC2086  # intentional indirect assignment
		[ -n "${!key:-}" ] || printf -v "$key" '%s' "$val"
	done < "$receipt"
}

se_load_receipt

SE_BIN_DIR="${SUDO_ELEVATION_BINDIR:-$(se_path /usr/local/bin)}"
SE_LIBEXEC="${SUDO_ELEVATION_LIBEXECDIR:-$(se_path /usr/local/libexec/sudo-elevation)}"
SE_SHARE="${SUDO_ELEVATION_SHAREDIR:-$(se_path /usr/local/share/sudo-elevation)}"
SE_CONFIG="${SUDO_ELEVATION_CONFIG:-$(se_path /etc/sudo-elevation.conf)}"
SE_SUDO_CONF="${SUDO_ELEVATION_SUDO_CONF:-$(se_path /etc/sudo.conf)}"
SE_SUDOERS_DIR="${SUDO_ELEVATION_SUDOERS_DIR:-$(se_path /etc/sudoers.d)}"
SE_RUNTIME_DIR="${SUDO_ELEVATION_RUNTIME_DIR:-$(se_path /run/sudo-elevation)}"
SE_LOG="${SUDO_ELEVATION_LOG:-$(se_path /var/log/sudo-elevation.log)}"

SE_VERSION="$(cat "$SE_SHARE/VERSION" 2>/dev/null || printf 'dev')"

# Defaults; the config layers below override them (see se_load_config).
BASE_MINUTES=15
MAX_MINUTES=525600
DIALOG_TIMEOUT=300
REQUEST_TTL=300
GUI_BACKEND=auto
# Where each key's effective value came from: "default", "machine:<path>" or
# "user:<path>". `sudo-elevation status` shows this so a surprising value is
# explainable instead of mysterious.
BASE_MINUTES_SRC=default
MAX_MINUTES_SRC=default
DIALOG_TIMEOUT_SRC=default
REQUEST_TTL_SRC=default
GUI_BACKEND_SRC=default

# The per-user config layer: <user's config dir>/sudo-elevation/config.
# A non-root caller IS the account in question, so $HOME is authoritative and
# we skip the getent lookup (this runs in the askpass hot path). Root has to
# resolve the named account, and must never inherit root's own XDG_* -- same
# rule the installer follows. A --prefix sandbox has no real user layer: the
# fake root and the developer's home must not bleed into each other.
se_user_config_path() { # user
	local u=${1-} home conf
	[ -z "$SE_PREFIX" ] || return 0
	if [ "$(id -u 2>/dev/null || printf 0)" != 0 ]; then
		[ -n "${HOME:-}" ] || return 0
		conf=${XDG_CONFIG_HOME:-$HOME/.config}
		printf '%s/sudo-elevation/config' "$conf"
		return 0
	fi
	[ -n "$u" ] || return 0
	home=$(se_home_of "$u")
	[ -n "$home" ] || return 0
	printf '%s/.config/sudo-elevation/config' "$home"
}

# Config layers in increasing priority, as "label<TAB>path" lines. The label
# says who the policy belongs to, which is what `status` reports: "machine" for
# host-wide /etc policy, "user" for one account's own overrides. A user install
# points SE_CONFIG at the user layer already (through its receipt), so that same
# file is labelled "user" and never read twice.
se_config_layers() { # user
	local machine user_layer mlabel
	machine=${SUDO_ELEVATION_CONFIG:-$SE_CONFIG}
	user_layer=$(se_user_config_path "${1-}")
	mlabel=machine
	if [ -n "$user_layer" ] && [ "$user_layer" = "$machine" ]; then
		mlabel=user
	fi
	[ -n "$machine" ] && printf '%s\t%s\n' "$mlabel" "$machine"
	if [ -n "$user_layer" ] && [ "$user_layer" != "$machine" ]; then
		printf 'user\t%s\n' "$user_layer"
	fi
	return 0
}

se_load_config_file() { # file layer
	local file=$1 layer=$2 line key val
	[ -r "$file" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in ''|'#'*) continue ;; esac
		key=${line%%=*}
		val=${line#*=}
		case "$key" in
			GUI_BACKEND)
				case "$val" in
					auto|x11|wayland)
						GUI_BACKEND=$val
						GUI_BACKEND_SRC="$layer:$file"
					;;
				esac
				continue
				;;
		esac
		# Strict numeric shape: digits with at most one dot (e.g. 15, 0.4).
		# The old loose class [!0-9.] accepted "15.5.5"/"." and relied on
		# awk's prefix coercion; reject such values outright instead.
		case "$val" in
			''|*[^0-9.]*|*.*.*|.*|*.) continue ;;
		esac
		case "$key" in
			BASE_MINUTES) BASE_MINUTES=$val; BASE_MINUTES_SRC="$layer:$file" ;;
			MAX_MINUTES) MAX_MINUTES=$val; MAX_MINUTES_SRC="$layer:$file" ;;
			DIALOG_TIMEOUT) DIALOG_TIMEOUT=$val; DIALOG_TIMEOUT_SRC="$layer:$file" ;;
			REQUEST_TTL) REQUEST_TTL=$val; REQUEST_TTL_SRC="$layer:$file" ;;
		esac
	done < "$file"
}

# se_report_layer LABEL [user] -- print "KEY<TAB>value" for one layer only,
# resolved against the built-in defaults. Mutates the config globals, so callers
# must use it in a command substitution (subshell). It exists so the installer
# can tell "the host set this" from "an account currently overrides it": without
# it, writing the resolved value would freeze one account's temporary override
# into the machine file, and skipping the key would drop the host's own policy.
se_report_layer() { # label [user]
	local label=$1 layer file
	BASE_MINUTES=15
	MAX_MINUTES=525600
	DIALOG_TIMEOUT=300
	REQUEST_TTL=300
	GUI_BACKEND=auto
	while IFS=$'\t' read -r layer file; do
		[ -n "$file" ] || continue
		[ "$layer" = "$label" ] || continue
		se_load_config_file "$file" "$layer"
	done < <(se_config_layers "${2-}")
	printf 'BASE\t%s\nMAX\t%s\nDIALOG\t%s\nTTL\t%s\nGUI\t%s\n' \
		"$BASE_MINUTES" "$MAX_MINUTES" "$DIALOG_TIMEOUT" "$REQUEST_TTL" "$GUI_BACKEND"
}

# se_load_config [user] -- resolve every key through the layers. Later layers
# overwrite earlier ones, so a user's own file narrows or widens host policy
# without anyone editing the host-wide file. Process substitution (not a pipe)
# keeps the assignments in this shell.
se_load_config() {
	local layer file
	while IFS=$'\t' read -r layer file; do
		[ -n "$file" ] || continue
		se_load_config_file "$file" "$layer"
	done < <(se_config_layers "${1-}")
}

# WSLg's Wayland compositor mishandles GTK4 popup/menu input; XWayland works.
# auto: X11 on WSL, toolkit default elsewhere. Override with GUI_BACKEND in
# /etc/sudo-elevation.conf (auto|x11|wayland).
se_apply_gui_backend() {
	local backend=${1:-auto} is_wsl=0
	if grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
		is_wsl=1
	fi
	case "$backend" in
		x11) [ -n "${DISPLAY:-}" ] && export GDK_BACKEND=x11 ;;
		wayland) [ -n "${WAYLAND_DISPLAY:-}" ] && export GDK_BACKEND=wayland ;;
		auto) [ "$is_wsl" = 1 ] && [ -n "${DISPLAY:-}" ] && export GDK_BACKEND=x11 ;;
	esac
	return 0
}

# se_parse_minutes SPEC -> minutes on stdout; supports:
#   -1|until-lock|lock|infinite   never expires until manual lock/reboot
#   90s  45m  2h  1d              seconds/minutes/hours/days
#   45                            bare number = minutes (sudo's native unit)
# Note: extremely small second values (e.g. 0.0000001s) format via %.10g
# into scientific notation (1.66667e-09), which se_valid_minutes rejects
# on purpose (fail-closed). Callers surface this as "out of range".
se_parse_minutes() {
	local spec=${1-} num unit
	case "$spec" in
		-1|until-lock|lock|infinite) printf '%s' -1; return 0 ;;
	esac
	if [[ $spec =~ ^([0-9]+(\.[0-9]+)?)([smhd]?)$ ]]; then
		num=${BASH_REMATCH[1]}
		unit=${BASH_REMATCH[3]}
		case "$unit" in
			s) awk -v n="$num" 'BEGIN{printf "%.10g", n/60}' ;;
			h) awk -v n="$num" 'BEGIN{printf "%.10g", n*60}' ;;
			d) awk -v n="$num" 'BEGIN{printf "%.10g", n*1440}' ;;
			*) printf '%s' "$num" ;;
		esac
		return 0
	fi
	return 1
}

se_valid_minutes() {
	local m=${1-}
	[ "$m" = "-1" ] && return 0
	case "$m" in ''|*[!0-9.]*) return 1 ;; esac
	awk -v m="$m" -v max="$MAX_MINUTES" 'BEGIN{exit !(m+0 >= 0 && m+0 <= max+0)}'
}

# Hard ceiling for MAX_MINUTES, deliberately independent of the resolved max:
# se_valid_minutes compares against $MAX_MINUTES, so validating the max against
# itself can never fail. Without an absolute cap a typo'd MAX_MINUTES (or a
# hand-edited config) would authorise a window measured in decades.
SE_MAX_MINUTES_CAP=525600

se_valid_max() { # minutes
	local m=${1-}
	case "$m" in ''|*[!0-9.]*) return 1 ;; esac
	awk -v m="$m" -v cap="$SE_MAX_MINUTES_CAP" \
		'BEGIN{exit !(m+0 >= 0 && m+0 <= cap+0)}'
}

# Duration spec is single value + single unit only (90s/45m/2h/1d/bare/until-lock);
# composites like 1m30s are rejected by se_parse_minutes. Anything unparseable
# reaching display (e.g. a hand-edited lease) is treated as 0 so it fails
# closed immediately instead of looking like a valid window.
se_human_minutes() {
	local m=${1:-0}
	if [ "$m" = "-1" ]; then printf '直到手动 lock'; return 0; fi
	case "$m" in
		''|*[^0-9.]*|*.*.*|.*|*.) printf '0 秒'; return 0 ;;
	esac
	awk -v m="$m" 'BEGIN{
		s = m * 60
		if (s < 90) printf "%.0f 秒", s
		else if (m < 60) { if (m == int(m)) printf "%d 分钟", m; else printf "%.1f 分钟", m }
		else if (m < 1440) { h = m/60; if (h == int(h)) printf "%d 小时", h; else printf "%.1f 小时", h }
		else { d = m/1440; if (d == int(d)) printf "%d 天", d; else printf "%.1f 天", d }
	}'
}

# English variant for the agent-facing SKILL (keeps CLI/README Chinese intact).
# 0 renders as strict-mode hint so "0 seconds" never confuses agents.
se_human_minutes_en() {
	local m=${1:-0}
	if [ "$m" = "-1" ]; then printf 'until-lock'; return 0; fi
	case "$m" in
		''|*[^0-9.]*|*.*.*|.*|*.) printf '0 seconds'; return 0 ;;
	esac
	if [ "$m" = "0" ]; then printf '0 (strict: password every time)'; return 0; fi
	awk -v m="$m" 'BEGIN{
		s = m * 60
		if (s < 90) printf "%.0f seconds", s
		else if (m < 60) { if (m == int(m)) printf "%d minutes", m; else printf "%.1f minutes", m }
		else if (m < 1440) { h = m/60; if (h == int(h)) printf "%d hours", h; else printf "%.1f hours", h }
		else { d = m/1440; if (d == int(d)) printf "%d days", d; else printf "%.1f days", d }
	}'
}

se_sanitize_reason() {
	local s=${1-}
	s=${s//$'\n'/ }
	s=${s//$'\r'/ }
	s=${s//$'\t'/ }
	s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037' | cut -c1-200)
	printf '%s' "$s"
}

# se_read_kv FILE KEY -> value on stdout. Strict line parser, no eval.
se_read_kv() {
	local file=${1-} want=${2-} line
	[ -n "$file" ] && [ -n "$want" ] && [ -f "$file" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		line=${line%$'\r'}
		case "$line" in
			"$want="*) printf '%s' "${line#"$want="}"; return 0 ;;
		esac
	done < "$file"
	return 1
}

se_valid_user() {
	case "${1-}" in
		''|*[!A-Za-z0-9_.-]*) return 1 ;;
		*) return 0 ;;
	esac
}

# Multi-user boundary for the root-side helpers. Reached through sudo by an
# unprivileged account, a helper may act ONLY on that account. Without this
# check anyone able to run `sudo .../grant` could rewrite another account's
# sudo window and lease by passing `--user someone-else`.
# Two cases stay allowed because no privilege boundary was crossed: the helper
# invoked directly by root (no SUDO_USER), and root running it through sudo
# (SUDO_USER=root, i.e. root already had the power in the first place).
se_assert_target_user() { # tool user
	local tool=$1 user=$2 caller=${SUDO_USER:-}
	[ -n "$caller" ] || return 0
	if [ "$caller" = root ] || [ "$user" = "$caller" ]; then
		return 0
	fi
	printf '%s: refusing --user %s: invoked via sudo by %s, so it may only act on itself\n' \
		"$tool" "$user" "$caller" >&2
	printf '%s: (run this helper as root to act on another account)\n' "$tool" >&2
	return 1
}

# Root parses the config file, so a caller must not be able to point
# --config-file at policy it controls. Trusted = owned by root and not
# writable by group/other, or owned by the target user (their own layer).
# Rejected means: someone other than the owner can rewrite the approval
# ceiling, the dialog timeout or the GUI backend underneath root's feet.
se_config_trusted() { # file user
	local f=${1-} user=${2-} syms owner
	[ -n "$f" ] && [ -f "$f" ] || return 1
	# Symbolic mode beats octal here: the group/other write bits are two
	# named characters, so there is no octal arithmetic to get wrong.
	syms=$(stat -c %A "$f" 2>/dev/null) || return 1
	[ "${#syms}" -ge 10 ] || return 1
	case "${syms:5:1}" in w) return 1 ;; esac   # group-write
	case "${syms:8:1}" in w) return 1 ;; esac   # other-write
	owner=$(stat -c %U "$f" 2>/dev/null) || return 1
	[ "$owner" = root ] && return 0
	[ -n "$user" ] && [ "$owner" = "$user" ] && return 0
	return 1
}

# se_version_ge "version line" MIN -> 0 when version >= MIN.
# Accepts full `sudo -V` first lines ("Sudo version 1.9.15p5",
# "sudo version 1.8.16"); a trailing pN patch level is ignored.
se_version_ge() {
	local got want
	got=$(printf '%s' "${1-}" | grep -oE '[0-9]+(\.[0-9]+)*' | head -n 1)
	want=$(printf '%s' "${2-}" | grep -oE '[0-9]+(\.[0-9]+)*' | head -n 1)
	[ -n "$got" ] && [ -n "$want" ] || return 1
	awk -v a="$got" -v b="$want" 'BEGIN{
		split(a, pa, "."); split(b, pb, ".")
		for (i = 1; i <= 3; i++) {
			if ((pa[i] + 0) > (pb[i] + 0)) exit 0
			if ((pa[i] + 0) < (pb[i] + 0)) exit 1
		}
		exit 0
	}'
}

# Filename slug for per-user sudoers/lease files. Dots are intentionally
# mapped to '_' too (e.g. first.last -> first_last) so names stay portable.
se_user_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }

se_home_of() { getent passwd "$1" 2>/dev/null | cut -d: -f6; }

se_install_file() { # src dest mode
	local src=$1 dest=$2 mode=$3
	if [ "$(id -u)" = 0 ]; then
		install -m "$mode" -o root -g root "$src" "$dest"
	else
		install -m "$mode" "$src" "$dest"
	fi
}

se_render_sudoers() { # user minutes dest
	local user=$1 minutes=$2 dest=$3
	{
		printf '# Managed by sudo-elevation %s -- do not edit.\n' "$SE_VERSION"
		printf '# Regenerated on every lease change.\n'
		printf 'Defaults:%s timestamp_type=global\n' "$user"
		printf 'Defaults:%s timestamp_timeout=%s\n' "$user" "$minutes"
	} > "$dest"
}

se_install_sudoers() { # src dest
	local src=$1 dest=$2
	visudo -cf "$src" >/dev/null 2>&1 || return 1
	se_install_file "$src" "$dest" 0440
}

se_lease_file() { printf '%s/%s.lease' "$SE_RUNTIME_DIR" "$(se_user_slug "${1-}")"; }

se_write_lease() { # file owner "key=value"...
	local file=$1 owner=$2
	shift 2
	mkdir -p "$SE_RUNTIME_DIR" 2>/dev/null || true
	chmod 0755 "$SE_RUNTIME_DIR" 2>/dev/null || true
	: > "$file"
	local kv
	for kv in "$@"; do printf '%s\n' "$kv" >> "$file"; done
	# Owner-only: the lease user must still read it via `status`, but other
	# users on the same host must not see the reason/audit metadata.
	chmod 0600 "$file" 2>/dev/null || true
	[ -n "$owner" ] && chown "$owner" "$file" 2>/dev/null || true
}

se_audit() {
	local msg=${1-}
	local dir
	dir=$(dirname "$SE_LOG")
	mkdir -p "$dir" 2>/dev/null || true
	printf '%s actor=%s %s\n' "$(date -Is)" "${SUDO_USER:-$(id -un)}" "$msg" >> "$SE_LOG" 2>/dev/null || true
	chmod 0600 "$SE_LOG" 2>/dev/null || true
}

se_parent_cmd() {
	local out
	[ -r "/proc/$PPID/cmdline" ] || return 0
	out=$(tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null | cut -c1-160)
	printf '%s' "$out"
}

# Best-effort restore scheduling. Echoes the mechanism used.
# systemd systems use a transient timer; otherwise a detached root sleeper.
# $4 (optional) is the config file the scheduled restore must load: root-side
# helpers cannot see the user's env/receipt, so the caller passes the resolved
# path explicitly (user-install correctness).
se_schedule_restore() { # user epoch minutes [config]
	local user=$1 epoch=$2 minutes=$3 cfg=${4:-$SE_CONFIG} secs
	[ "$minutes" = "-1" ] && { printf 'none'; return 0; }
	secs=$(awk -v m="$minutes" 'BEGIN{printf "%d", (m*60)+0.5}')
	if [ -z "$SE_PREFIX" ] && [ -d /run/systemd/system ] && command -v systemd-run >/dev/null 2>&1 \
	   && systemctl is-system-running >/dev/null 2>&1; then
		if systemd-run --collect --quiet --on-active="${secs}s" \
			--unit="sudo-elevation-${user}-${epoch}" \
			"$SE_LIBEXEC/restore" --user "$user" --epoch "$epoch" \
			--config-file "$cfg" >/dev/null 2>&1; then
			printf 'systemd-run:%.0fs' "$secs"
			return 0
		fi
	fi
	if command -v setsid >/dev/null 2>&1; then
		setsid sh -c "sleep $secs; exec \"$SE_LIBEXEC/restore\" --user \"$user\" --epoch \"$epoch\" --config-file \"$cfg\"" \
			</dev/null >/dev/null 2>&1 &
		printf 'setsid:pid=%s:%.0fs' "$!" "$secs"
		return 0
	fi
	printf 'failed'
	return 1
}
