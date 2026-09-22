#!/bin/bash
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
log "install (plain: production strips test hooks)"
install_se_plain

assert_file /usr/local/bin/sudo-askpass
assert_mode /usr/local/bin/sudo-askpass 755
assert_not_contains /usr/local/bin/sudo-askpass "# >>> test hooks >>>"
assert_not_contains /usr/local/bin/sudo-askpass "SUDO_ELEVATION_FAKE_PASSWORD"
assert_file /usr/local/bin/sudo-elevation
assert_mode /usr/local/bin/sudo-elevation 755
assert_file /usr/local/libexec/sudo-elevation/grant
assert_mode /usr/local/libexec/sudo-elevation/grant 755
assert_file /usr/local/libexec/sudo-elevation/restore
assert_mode /usr/local/libexec/sudo-elevation/restore 755
assert_file /usr/local/libexec/sudo-elevation/install.sh
assert_mode /usr/local/libexec/sudo-elevation/install.sh 755
assert_file /usr/local/libexec/sudo-elevation/common.sh
assert_mode /usr/local/libexec/sudo-elevation/common.sh 644

assert_file /etc/sudo-elevation.conf
assert_contains /etc/sudo-elevation.conf "BASE_MINUTES=15"
assert_contains /etc/sudo-elevation.conf "MAX_MINUTES=525600"

assert_contains /etc/sudo.conf "# >>> sudo-elevation >>>"
assert_contains /etc/sudo.conf "Path askpass /usr/local/bin/sudo-askpass"
assert_contains /etc/sudo.conf "# <<< sudo-elevation <<<"

assert_file /etc/sudoers.d/90-sudo-elevation-tester
assert_mode /etc/sudoers.d/90-sudo-elevation-tester 440
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_type=global"
assert_contains /etc/sudoers.d/90-sudo-elevation-tester "timestamp_timeout=15"

assert_file /home/tester/.config/opencode/skill/sudo-elevation/SKILL.md
assert_contains /home/tester/.config/opencode/skill/sudo-elevation/SKILL.md "sudo-elevation request"
assert_eq "$(stat -c %U /home/tester/.config/opencode/skill/sudo-elevation/SKILL.md)" tester "skill owned by user"

assert_file /usr/local/share/sudo-elevation/manifest
assert_contains /usr/local/share/sudo-elevation/manifest "USERS=tester"
assert_ok visudo -c
assert_ok sudo -V

log "idempotent re-install"
install_se_plain
assert_eq "$(grep -c '^Path askpass' /etc/sudo.conf)" 1 "no duplicate Path askpass"
assert_eq "$(grep -c '# >>> sudo-elevation >>>' /etc/sudo.conf)" 1 "single marker block"

log "--test-hooks keeps the fake/print hooks"
install_se >/dev/null
assert_contains /usr/local/bin/sudo-askpass "SUDO_ELEVATION_FAKE_PASSWORD"

log "duration parsing"
assert_eq "$(/usr/local/bin/sudo-elevation parse 90s)" 1.5
assert_eq "$(/usr/local/bin/sudo-elevation parse 45m)" 45
assert_eq "$(/usr/local/bin/sudo-elevation parse 2h)" 120
assert_eq "$(/usr/local/bin/sudo-elevation parse 1d)" 1440
assert_eq "$(/usr/local/bin/sudo-elevation parse 45)" 45
assert_eq "$(/usr/local/bin/sudo-elevation parse until-lock)" -1
