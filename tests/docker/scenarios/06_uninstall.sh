#!/bin/bash
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user

log "pre-existing sudo.conf content"
printf '# container-custom-marker\n' >> /etc/sudo.conf
install_se
assert_contains /etc/sudo.conf "# container-custom-marker"
assert_contains /etc/sudo.conf "# >>> sudo-elevation >>>"

log "uninstall preserves foreign lines and removes our files"
"$REPO/install.sh" --uninstall --user tester
assert_contains /etc/sudo.conf "# container-custom-marker"
assert_not_contains /etc/sudo.conf "# >>> sudo-elevation >>>"
assert_not_contains /etc/sudo.conf "Path askpass /usr/local/bin/sudo-askpass"
assert_no_file /usr/local/bin/sudo-askpass
assert_no_file /usr/local/bin/sudo-elevation
assert_no_file /usr/local/libexec/sudo-elevation/grant
assert_no_file /usr/local/libexec/sudo-elevation/restore
assert_no_file /usr/local/libexec/sudo-elevation/common.sh
assert_no_file /etc/sudo-elevation.conf
assert_no_file /etc/sudoers.d/90-sudo-elevation-tester
assert_no_file /home/tester/.config/opencode/skill/sudo-elevation/SKILL.md
assert_ok visudo -c
assert_ok sudo -V
