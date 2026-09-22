#!/bin/bash
# Shared helpers for docker scenarios (run inside the container as root).
set -euo pipefail

REPO=${REPO:-/src}
ASKPASS="$REPO/tests/docker/fake-askpass"

# Marker so the driver can tell "scenario finished, docker CLI hung afterwards"
# apart from "scenario itself is stuck".
# shellcheck disable=SC2154  # rc is assigned within this very trap
trap 'rc=$?; echo "SCENARIO-DONE rc=$rc"' EXIT

log() { printf '\n== %s ==\n' "$*"; }
ok() { printf '  ok: %s\n' "$*"; }
die() {
	printf '  FAIL: %s\n' "$*" >&2
	exit 1
}

assert_ok() { "$@" >/dev/null 2>&1 || die "expected success: $*"; ok "success: $*"; }
assert_fail() { if "$@" >/dev/null 2>&1; then die "expected failure: $*"; fi; ok "failed as expected: $*"; }
assert_eq() { [ "$1" = "$2" ] || die "expected [$2], got [$1]${3:+ ($3)}"; ok "${3:-assert_eq}: $2"; }
assert_file() { [ -f "$1" ] || die "missing file: $1"; ok "file: $1"; }
assert_no_file() { [ ! -e "$1" ] || die "should not exist: $1"; ok "absent: $1"; }
assert_mode() {
	local m
	m=$(stat -c %a "$1" 2>/dev/null) || die "stat failed: $1"
	[ "$m" = "$2" ] || die "mode $1=$m want $2"
	ok "mode $1=$2"
}
assert_contains() { grep -qF -- "$2" "$1" || die "$1 does not contain: $2"; ok "contains: $2"; }
assert_not_contains() { ! grep -qF -- "$2" "$1" || die "$1 unexpectedly contains: $2"; ok "not contains: $2"; }

setup_user() {
	id tester >/dev/null 2>&1 || {
		useradd -m -s /bin/bash tester
		echo 'tester:testpass' | chpasswd
		usermod -aG sudo tester
	}
}

# Test-suite installs keep the fake/print askpass hooks; production strips them.
install_se() { "$REPO/install.sh" --user tester --test-hooks "$@"; }
install_se_plain() { "$REPO/install.sh" --user tester "$@"; }

# set_ui CHOICE [PASSWORD]
set_ui() {
	printf '%s\n' "$1" > /tmp/se-test-choice
	printf '%s\n' "${2:-testpass}" > /tmp/se-test-password
	chmod 0644 /tmp/se-test-choice /tmp/se-test-password
}

as_tester() { runuser -u tester -- env SUDO_ASKPASS="$ASKPASS" "$@"; }

wait_for_contains() { # file needle timeout
	local file=$1 needle=$2 timeout=${3:-20} i
	for ((i = 0; i < timeout; i++)); do
		grep -qF -- "$needle" "$file" 2>/dev/null && return 0
		sleep 1
	done
	return 1
}
