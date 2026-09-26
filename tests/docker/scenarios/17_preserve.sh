#!/bin/bash
# P1-P5 preservation: purge/install must not delete foreign files.
# - ghost sudoers: only Managed-by header goes, handmade prefix stays
# - leases: only epoch+minutes/restore keys go, foreign .lease stays
# - sudo.conf: unclosed block fails closed; foreign lines stay
# - CONFIG/LOG: foreign redirected paths stay
# - SKILL: only the 'Managed by sudo-elevation' marker goes -- including when a
#   third-party file carries the old 'sudo-elevation request' signature
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
# skill: own (has marker) vs third-party files. The second one is the case the
# old guard got wrong -- it carries the exact substring the guard used to key
# on, so a substring-based check would have deleted it.
printf '# third party mentions sudo-elevation but no command\n' > /tmp/other-skill.md
mkdir -p /home/tester/.config/opencode/skill/other-skill
cp /tmp/other-skill.md /home/tester/.config/opencode/skill/other-skill/SKILL.md
printf -- '---\nname: deploy-helper\ndescription: third party that happens to say sudo-elevation request\n---\n\nbody\n' \
	> /tmp/collide-skill.md
mkdir -p /home/tester/.config/opencode/skill/deploy-helper
cp /tmp/collide-skill.md /home/tester/.config/opencode/skill/deploy-helper/SKILL.md
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
assert_file /home/tester/.config/opencode/skill/deploy-helper/SKILL.md
rm -rf /home/tester/.config/opencode/skill/other-skill /home/tester/.config/opencode/skill/deploy-helper
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

log "bare --no-system as root still uses target XDG homes, touches no system dir"
# reset leftovers from the redirect test above (its purge intentionally
# skipped the default tree to prove foreign preservation)
"$REPO/install.sh" --user tester --uninstall --purge >/dev/null
"$REPO/install.sh" --user tester --no-system --skill-dir /tmp/se-nsskill >/dev/null
grep -q '^INSTALL_MODE=user$' /home/tester/.local/share/sudo-elevation/manifest \
	|| die "bare no-system not user mode"
grep -q '^SYSTEM=0$' /home/tester/.local/share/sudo-elevation/manifest || die "bare no-system SYSTEM!=0"
assert_file /home/tester/.local/bin/sudo-elevation
assert_file /home/tester/.config/sudo-elevation/config
assert_no_file /usr/local/bin/sudo-elevation
assert_no_file /etc/sudo-elevation.conf
assert_no_file /etc/sudoers.d/90-sudo-elevation-tester
assert_not_contains /etc/sudo.conf "# >>> sudo-elevation >>>"
# same flags the CLI forwards from the manifest (INSTALL_MODE=user, SYSTEM=0)
"$REPO/install.sh" --user-install --user tester --no-system --uninstall --purge >/dev/null
assert_no_file /home/tester/.local/bin/sudo-elevation
assert_no_file /home/tester/.local/share/sudo-elevation/manifest
assert_no_file /usr/local/bin/sudo-elevation
assert_no_file /etc/sudo-elevation.conf
ok "bare no-system stays in user dirs"

log "pre-marker skill survives purge, and the repo tool clears it on demand"
# The marker guard has no backward-compat fallback on purpose, so a skill
# rendered before the marker stays behind. Two things must hold: the uninstall
# says what happened and where the tool is, and the tool removes it without
# touching a third party's file that carries the same old signature.
install_se >/dev/null
SKILL=/home/tester/.config/opencode/skill/sudo-elevation/SKILL.md
assert_contains "$SKILL" "Managed by sudo-elevation"
cp "$SKILL" /tmp/skill-new
# rewind it to the pre-marker shape: old signature, right name, no marker
printf -- '---\nname: sudo-elevation\ndescription: old render\n---\n\nRule: use sudo-elevation request.\n' > "$SKILL"
out=$("$REPO/install.sh" --user tester --uninstall --purge 2>&1)
printf '%s\n' "$out" > /tmp/se-purge.log
assert_file "$SKILL"
assert_contains /tmp/se-purge.log "predates the ownership marker"
assert_contains /tmp/se-purge.log "purge-legacy-skill.sh"
# third party that also carries the old signature: the tool must not take it
mkdir -p /home/tester/.config/opencode/skill/deploy-helper
printf -- '---\nname: deploy-helper\ndescription: says sudo-elevation request\n---\n\nbody\n' \
	> /home/tester/.config/opencode/skill/deploy-helper/SKILL.md
chown -R tester /home/tester/.config
"$REPO/tools/purge-legacy-skill.sh" --user tester > /tmp/se-legacy.log 2>&1
assert_contains /tmp/se-legacy.log "$SKILL"
assert_not_contains /tmp/se-legacy.log "deploy-helper"
assert_file "$SKILL"
"$REPO/tools/purge-legacy-skill.sh" --user tester --yes >/dev/null
assert_no_file "$SKILL"
assert_file /home/tester/.config/opencode/skill/deploy-helper/SKILL.md
rm -rf /home/tester/.config/opencode/skill/deploy-helper /tmp/skill-new /tmp/se-purge.log /tmp/se-legacy.log
ok "pre-marker skill kept, named, then cleared by tools/purge-legacy-skill.sh"

assert_ok visudo -c
assert_ok sudo -V
ok "preserve all"
