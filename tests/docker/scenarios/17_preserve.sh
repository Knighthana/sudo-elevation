#!/bin/bash
# P1-P5 preservation: purge/install must not delete foreign files.
# - ghost sudoers: only Managed-by header goes, handmade prefix stays
# - leases: only epoch+minutes/restore keys go, foreign .lease stays
# - sudo.conf: unclosed block fails closed; foreign lines stay
# - CONFIG/LOG: foreign redirected paths stay
# - SKILL: only "sudo-elevation request" marker goes
set -euo pipefail
. /src/tests/docker/lib.sh

setup_user
install_se >/dev/null

log "ghost sudoers content check"
printf '# Managed by sudo-elevation test\nDefaults:ghost timestamp_timeout=15\n' > /etc/sudoers.d/90-sudo-elevation-ghost
chmod 0440 /etc/sudoers.d/90-sudo-elevation-ghost
printf 'Defaults:handmade timestamp_timeout=10\n' > /etc/sudoers.d/90-sudo-elevation-handmade
chmod 0440 /etc/sudoers.d/90-sudo-elevation-handmade
mkdir -p /run/sudo-elevation
printf 'epoch=1-1-1\nminutes=5\nrestore=none\n' > /run/sudo-elevation/ghost.lease
printf 'foreign-body\n' > /run/sudo-elevation/foreign.lease
printf 'x' > /run/sudo-elevation/notes.txt
# skill: own (has marker) vs third-party mention without request command
printf '# third party mentions sudo-elevation but no command\n' > /tmp/other-skill.md
mkdir -p /home/tester/.config/opencode/skill/other-skill
cp /tmp/other-skill.md /home/tester/.config/opencode/skill/other-skill/SKILL.md
chown -R tester /home/tester/.config
"$REPO/install.sh" --user tester --uninstall --purge >/dev/null
assert_no_file /etc/sudoers.d/90-sudo-elevation-ghost
assert_file /etc/sudoers.d/90-sudo-elevation-handmade
rm -f /etc/sudoers.d/90-sudo-elevation-handmade
assert_no_file /run/sudo-elevation/ghost.lease
assert_file /run/sudo-elevation/foreign.lease
assert_file /run/sudo-elevation/notes.txt
rm -f /run/sudo-elevation/foreign.lease /run/sudo-elevation/notes.txt
rmdir /run/sudo-elevation 2>/dev/null || true
assert_file /home/tester/.config/opencode/skill/other-skill/SKILL.md
rm -rf /home/tester/.config/opencode/skill/other-skill
ok "ghost/lease/skill guards"

log "sudo.conf unclosed block fails closed"
install_se >/dev/null
printf '# >>> sudo-elevation >>>\nPath askpass /usr/local/bin/sudo-askpass\n' >> /etc/sudo.conf
if "$REPO/install.sh" --user tester --uninstall --purge >/dev/null 2>&1; then
	die "purge should fail on unclosed block"
fi
assert_contains /etc/sudo.conf "# >>> sudo-elevation >>>"
# repair: close the block, then purge must succeed
printf '# <<< sudo-elevation <<<\n' >> /etc/sudo.conf
"$REPO/install.sh" --user tester --uninstall --purge >/dev/null
assert_not_contains /etc/sudo.conf "# >>> sudo-elevation >>>"
ok "strip_block fail-closed"

log "CONFIG/LOG foreign redirect preserved"
install_se >/dev/null
printf 'FOREIGN=1\n' > /tmp/foreign.conf
printf 'foreign log\n' > /tmp/foreign.log
SUDO_ELEVATION_CONFIG=/tmp/foreign.conf SUDO_ELEVATION_LOG=/tmp/foreign.log \
	"$REPO/install.sh" --user tester --uninstall --purge >/dev/null
assert_file /tmp/foreign.conf
assert_file /tmp/foreign.log
assert_contains /tmp/foreign.conf "FOREIGN=1"
rm -f /tmp/foreign.conf /tmp/foreign.log /tmp/other-skill.md
ok "config/log guards"

assert_ok visudo -c
assert_ok sudo -V
ok "preserve all"
