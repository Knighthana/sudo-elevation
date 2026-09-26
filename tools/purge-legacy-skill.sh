#!/bin/bash
# tools/purge-legacy-skill.sh — clear SKILL.md files left by installs that
# predate the ownership marker. Repo-only maintenance; NOT installed and NOT
# part of install/uninstall. See tools/README.md for why it exists.
#
# Background: se_safe_rm_skill() used to decide "is this SKILL.md ours?" by the
# substring 'sudo-elevation request'. That was wrong in one direction -- a
# third-party skill could contain the phrase by accident and be deleted. It now
# requires the marker 'Managed by sudo-elevation' instead, which leaves the
# skills rendered by those older installs behind on purge (the uninstall says so
# and points here). This script removes exactly those.
#
# "Legacy" is defined by the file, not by history: no marker, but the old
# signature AND `name: sudo-elevation` in the frontmatter. Requiring both the
# signature and the name is what keeps a third-party file out of scope -- the
# signature alone is too weak to delete on, the name alone is too weak to trust
# without it.
#
# Deliberately NOT covered, because they are not knowable from here: custom
# --skill-dir paths from an install whose manifest is already gone, and any
# layout older than the manifest. Point it at such a directory with --dir.
#
# Usage:
#   tools/purge-legacy-skill.sh                    # report only, current user
#   tools/purge-legacy-skill.sh --user bob         # report for one account
#   tools/purge-legacy-skill.sh --all-users        # report for every account in
#                                                 #   the manifest (needs root)
#   tools/purge-legacy-skill.sh --dir /path/to/dir   # one extra directory
#   tools/purge-legacy-skill.sh --yes              # actually delete
#
# Reports first, deletes only with --yes. Deletes SKILL.md and then the
# directory, but only while the directory is empty, so it can never take a
# neighbouring file with it.
set -euo pipefail

SKILL_MARKER='Managed by sudo-elevation'
LEGACY_SIG='sudo-elevation request'

all_users=0
yes=0
target_user=""
extra_dirs=()

usage() {
	sed -n '2,32p' "$0" | sed -e 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
	case "$1" in
		--all-users) all_users=1; shift ;;
		--user) target_user=${2-}; shift 2 ;;
		--dir) extra_dirs+=("${2-}"); shift 2 ;;
		--yes) yes=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "purge-legacy-skill: unknown argument: $1" >&2; exit 2 ;;
	esac
done

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SELF_DIR/.." && pwd)

if [ -r "$REPO_DIR/libexec/sudo-elevation/common.sh" ]; then
	# shellcheck source=../libexec/sudo-elevation/common.sh
	. "$REPO_DIR/libexec/sudo-elevation/common.sh"
else
	echo "purge-legacy-skill: cannot read libexec/sudo-elevation/common.sh" >&2
	exit 1
fi

manifest_users() {
	local mf=${SE_SHARE:-/usr/local/share/sudo-elevation}/manifest
	[ -r "$mf" ] || return 0
	se_read_kv "$mf" USERS 2>/dev/null || true
}

# One candidate skill directory -> print it, or nothing.
skill_dir_for() {
	local u=$1 home sk
	[ -n "$u" ] || return 0
	se_valid_user "$u" || return 0
	sk=$(se_read_kv "${SE_SHARE:-/usr/local/share/sudo-elevation}/manifest" SKILL_DIR 2>/dev/null || true)
	if [ -n "$sk" ]; then
		printf '%s\n' "$sk"
		return 0
	fi
	home=$(se_home_of "$u")
	[ -n "$home" ] || return 0
	printf '%s\n' "$home/.config/opencode/skill/sudo-elevation"
}

# Is this SKILL.md one of ours from before the marker? Signature + frontmatter
# name, both required.
is_legacy_skill() {
	local f=$1
	[ -f "$f" ] || return 1
	grep -q "$SKILL_MARKER" "$f" 2>/dev/null && return 1
	grep -q "$LEGACY_SIG" "$f" 2>/dev/null || return 1
	grep -qx 'name: sudo-elevation' "$f" 2>/dev/null
}

candidates=()
if [ "$all_users" = 1 ]; then
	[ "$(id -u)" = 0 ] || {
		echo "purge-legacy-skill: --all-users needs root" >&2
		exit 1
	}
	IFS=',' read -r -a _users <<< "$(manifest_users),$(id -un)"
else
	_users=("${target_user:-$(id -un)}")
fi
for u in ${_users+"${_users[@]}"}; do
	d=$(skill_dir_for "$u")
	[ -n "$d" ] && candidates+=("$d")
done
for d in ${extra_dirs+"${extra_dirs[@]}"}; do
	candidates+=("$d")
done

[ ${#candidates[@]} -gt 0 ] || {
	echo "purge-legacy-skill: no skill directory to check; nothing found."
	exit 0
}

hits=()
seen=""
for d in "${candidates[@]}"; do
	# Same guard rails as se_safe_rm_skill: absolute, never the filesystem root.
	case "$d" in
		/*) ;;
		*) echo "skip (not absolute): $d" >&2; continue ;;
	esac
	[ "$d" = "/" ] && continue
	case "$seen" in
		*"$d "*) continue ;;
	esac
	seen="$seen$d "
	f=$d/SKILL.md
	is_legacy_skill "$f" || continue
	hits+=("$f")
done

if [ ${#hits[@]} -eq 0 ]; then
	echo "purge-legacy-skill: no pre-marker sudo-elevation skill found (${#candidates[@]} location(s) checked)."
	echo "  Legacy skills are the ones purge deliberately leaves behind; current installs carry the marker."
	exit 0
fi

if [ "$yes" != 1 ]; then
	echo "purge-legacy-skill: ${#hits[@]} pre-marker skill(s) would be removed:"
	printf '  %s\n' "${hits[@]}"
	echo
	echo "  Re-run with --yes to remove them. Report-only run, nothing changed."
	exit 0
fi

for f in "${hits[@]}"; do
	rm -f -- "$f"
	echo "removed: $f"
	d=${f%/*}
	# Only while empty, so a neighbouring file can never be taken along.
	rmdir "$d" 2>/dev/null || true
done
echo "purge-legacy-skill: done (${#hits[@]} removed)."
