#!/bin/bash
# sudo-elevation - shared shell library.
#
# Sourced by grant, restore, sudo-elevation and sudo-askpass.
# NEVER source untrusted files. All user-supplied files are parsed with
# se_read_kv and validated; no eval is ever used on external data.
#
# SUDO_ELEVATION_PREFIX may be set to relocate every system path (used by
# the test-suite to run the installer inside a sandbox).

SE_PREFIX="${SUDO_ELEVATION_PREFIX:-}"

se_path() { printf '%s%s' "$SE_PREFIX" "$1"; }

SE_BIN_DIR="$(se_path /usr/local/bin)"
SE_LIBEXEC="$(se_path /usr/local/libexec/sudo-elevation)"
SE_SHARE="$(se_path /usr/local/share/sudo-elevation)"
SE_CONFIG="$(se_path /etc/sudo-elevation.conf)"
SE_SUDO_CONF="$(se_path /etc/sudo.conf)"
SE_SUDOERS_DIR="$(se_path /etc/sudoers.d)"
SE_RUNTIME_DIR="$(se_path /run/sudo-elevation)"
SE_LOG="$(se_path /var/log/sudo-elevation.log)"

SE_VERSION="$(cat "$SE_SHARE/VERSION" 2>/dev/null || printf 'dev')"

# Defaults; overridden by SE_CONFIG (see se_load_config).
BASE_MINUTES=15
MAX_MINUTES=525600
DIALOG_TIMEOUT=300
REQUEST_TTL=300

se_load_config() {
	local file="${SUDO_ELEVATION_CONFIG:-$SE_CONFIG}"
	[ -r "$file" ] || return 0
	local line key val
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in ''|'#'*) continue ;; esac
		key=${line%%=*}
		val=${line#*=}
		case "$val" in ''|*[!0-9.]*) continue ;; esac
		case "$key" in
			BASE_MINUTES) BASE_MINUTES=$val ;;
			MAX_MINUTES) MAX_MINUTES=$val ;;
			DIALOG_TIMEOUT) DIALOG_TIMEOUT=$val ;;
			REQUEST_TTL) REQUEST_TTL=$val ;;
		esac
	done < "$file"
}

# se_parse_minutes SPEC -> minutes on stdout; supports:
#   -1|until-lock|lock|infinite   never expires until manual lock/reboot
#   90s  45m  2h  1d              seconds/minutes/hours/days
#   45                            bare number = minutes (sudo's native unit)
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

se_human_minutes() {
	local m=${1:-0}
	if [ "$m" = "-1" ]; then printf '直到手动 lock'; return 0; fi
	awk -v m="$m" 'BEGIN{
		s = m * 60
		if (s < 90) printf "%.0f 秒", s
		else if (m < 60) { if (m == int(m)) printf "%d 分钟", m; else printf "%.1f 分钟", m }
		else if (m < 1440) { h = m/60; if (h == int(h)) printf "%d 小时", h; else printf "%.1f 小时", h }
		else { d = m/1440; if (d == int(d)) printf "%d 天", d; else printf "%.1f 天", d }
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

se_write_lease() { # file "key=value"...
	local file=$1
	shift
	mkdir -p "$SE_RUNTIME_DIR" 2>/dev/null || true
	chmod 0755 "$SE_RUNTIME_DIR" 2>/dev/null || true
	: > "$file"
	local kv
	for kv in "$@"; do printf '%s\n' "$kv" >> "$file"; done
	chmod 0644 "$file" 2>/dev/null || true
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
se_schedule_restore() { # user epoch minutes
	local user=$1 epoch=$2 minutes=$3 secs
	[ "$minutes" = "-1" ] && { printf 'none'; return 0; }
	secs=$(awk -v m="$minutes" 'BEGIN{printf "%d", (m*60)+0.5}')
	if [ -z "$SE_PREFIX" ] && [ -d /run/systemd/system ] && command -v systemd-run >/dev/null 2>&1 \
	   && systemctl is-system-running >/dev/null 2>&1; then
		if systemd-run --collect --quiet --on-active="${secs}s" \
			--unit="sudo-elevation-${user}-${epoch}" \
			"$SE_LIBEXEC/restore" --user "$user" --epoch "$epoch" >/dev/null 2>&1; then
			printf 'systemd-run:%.0fs' "$secs"
			return 0
		fi
	fi
	if command -v setsid >/dev/null 2>&1; then
		setsid sh -c "sleep $secs; exec \"$SE_LIBEXEC/restore\" --user \"$user\" --epoch \"$epoch\"" \
			</dev/null >/dev/null 2>&1 &
		printf 'setsid:pid=%s:%.0fs' "$!" "$secs"
		return 0
	fi
	printf 'failed'
	return 1
}
