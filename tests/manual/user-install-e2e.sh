#!/bin/bash
# tests/manual/user-install-e2e.sh — 用户通道的端到端真机回归（不进 CI）。
#
# 覆盖 askpass-env.sh 覆盖不到的那一步：把「用户通道安装 → CLI 兜底导出
# SUDO_ASKPASS → sudo -A 调起真 askpass → 真 zenity 弹窗 → grant 写 sudoers/租约」
# 整条链在一台真机上跑通。前面每一环都已分别验证（docker 19 证管道、askpass-env.sh
# 证 DISPLAY/XAUTHORITY 与属主、WSLg 那轮证弹窗本身），这里是唯一把它们接起来的测试。
#
# 与其它手动测试不同，这个脚本**故意不传 --test-hooks**：要的就是真弹窗，因此
# 必须有 tty、必须有人点。它会真的改系统状态（/etc/sudoers.d 下一个 drop-in、
# ~/.local、~/.config），结束时用 --purge 收干净。
#
# 用法：
#   tests/manual/user-install-e2e.sh check          # 只读预检，随便跑
#   tests/manual/user-install-e2e.sh --yes run      # 端到端（会弹窗，输 1 次口令）
#   tests/manual/user-install-e2e.sh --yes run --keep   # 跑完保留安装，不清理
#
# 失败时**不自动清理**：现场（status / 文件清单 / cleanup 命令）会打出来，由人决定。
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
ME=$(id -un)
YES=0
KEEP=0
MODE="check"
FAILED=0

# 会被本脚本创建/改动的路径，用于预检"是否已装过"和收尾核对。
P_TREE_BIN="$HOME/.local/bin"
P_LIBEXEC="$HOME/.local/libexec/sudo-elevation"
P_CONFIG_DIR="$HOME/.config/sudo-elevation"
P_RECEIPT="$P_CONFIG_DIR/env"
P_USERCFG="$P_CONFIG_DIR/config"
P_STATE="$HOME/.local/state/sudo-elevation"
P_SUDOERS="/etc/sudoers.d/90-sudo-elevation-$ME"
P_MACHINE_CFG="/etc/sudo-elevation.conf"

hdr() { printf '\n== %s ==\n' "$*"; }
say() { printf '%s\n' "$*"; }
ok() { printf '  ok: %s\n' "$*"; }
bad() { printf '  FAIL: %s\n' "$*" >&2; FAILED=1; }

usage() {
	cat <<'EOF'
usage: tests/manual/user-install-e2e.sh [--yes] [--keep] <check|run>

  check   preconditions only (read-only)
  run     full end-to-end: installs the user channel, opens a real dialog,
          asserts the result, then purges unless --keep
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--yes) YES=1; shift ;;
		--keep) KEEP=1; shift ;;
		-h|--help) usage; exit 0 ;;
		check|run) MODE=$1; shift ;;
		*) printf 'unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
	esac
done

hdr "preconditions"
[ "$(id -u)" != 0 ] || { say "run this as your normal account, not root"; exit 1; }
command -v sudo >/dev/null || { say "sudo not found"; exit 1; }
id -nG "$ME" | tr ' ' '\n' | grep -qx sudo || { say "$ME is not in the sudo group"; exit 1; }
command -v zenity >/dev/null || command -v kdialog >/dev/null \
	|| { say "no zenity and no kdialog: the dialog cannot open"; exit 1; }
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { say "no graphical session (DISPLAY/WAYLAND_DISPLAY unset)"; exit 1; }
if command -v zenity >/dev/null; then say "ui: zenity $(zenity --version 2>/dev/null)"; else say "ui: kdialog"; fi
say "sudo: $(sudo -V 2>/dev/null | head -1)  (will prompt for your password)"
say "DISPLAY=${DISPLAY:-<unset>} XAUTHORITY=${XAUTHORITY:-<unset>}"

hdr "clean slate"
# 绝不覆盖已有安装：那是用户的资产，不是测试的靶子。
existing=""
for p in /usr/local/bin/sudo-elevation /usr/local/bin/sudo-askpass \
	/usr/local/libexec/sudo-elevation/grant "$P_MACHINE_CFG" "$P_SUDOERS" \
	"$P_TREE_BIN/sudo-elevation" "$P_RECEIPT" "$P_USERCFG"; do
	[ -e "$p" ] && existing="$existing $p"
done
if [ -n "$existing" ]; then
	say "refusing to run: something is already installed:$existing"
	say "  this test installs and purges; it must not clobber a real install."
	exit 1
fi
ok "nothing installed, no sudoers drop-in, no sudo.conf marker"

if [ "$MODE" = check ]; then
	say ""
	say "check passed. Re-run with:  tests/manual/user-install-e2e.sh --yes run"
	exit 0
fi

[ "$YES" = 1 ] || { say "--yes is required for run"; exit 2; }
[ -t 0 ] || { say "no tty: the dialog and the password prompt both need a terminal"; exit 2; }

cleanup_hint() {
	say ""
	say "--- to clean up by hand ---"
	say "  sudo $REPO/install.sh --user-install --user $ME --uninstall --purge"
	say "  sudo rm -f $P_SUDOERS"
}

on_fail() {
	[ "$FAILED" = 1 ] || return 0
	printf '\n!! FAILED -- leaving the state in place for inspection\n' >&2
	say "--- sudo-elevation status ---"
	"$P_TREE_BIN/sudo-elevation" status 2>&1 | sed 's/^/  /' || true
	say "--- installed files ---"
	for p in "$P_TREE_BIN/sudo-elevation" "$P_TREE_BIN/sudo-askpass" \
		"$P_LIBEXEC/grant" "$P_LIBEXEC/restore" "$P_RECEIPT" "$P_USERCFG" "$P_SUDOERS"; do
		[ -e "$p" ] && say "  present: $p ($(stat -c '%U:%G %a' "$p"))"
	done
	cleanup_hint
}
trap on_fail EXIT

hdr "install (user channel, real askpass: no --test-hooks)"
sudo "$REPO/install.sh" --user-install --user "$ME" --no-skill
ok "installer exited 0"

hdr "install invariants"
for p in "$P_TREE_BIN/sudo-elevation" "$P_TREE_BIN/sudo-askpass" \
	"$P_LIBEXEC/grant" "$P_LIBEXEC/restore" "$P_RECEIPT" "$P_USERCFG"; do
	[ -e "$p" ] && ok "present: $p" || bad "missing: $p"
done
[ -e "$P_SUDOERS" ] && ok "sudoers drop-in: $P_SUDOERS" || bad "no sudoers drop-in"
# P0-3: a user install must NOT take the machine-global Path askpass.
if grep -q "sudo-elevation" /etc/sudo.conf 2>/dev/null; then
	bad "/etc/sudo.conf has a sudo-elevation block (user install must not write it)"
else
	ok "/etc/sudo.conf untouched by the user install"
fi
# P0-4: the root-run helpers must not be owned by the account.
for p in "$P_LIBEXEC/grant" "$P_LIBEXEC/restore"; do
	[ "$(stat -c %U "$p")" = root ] && ok "root-owned: $p" || bad "$p is owned by $(stat -c %U "$p")"
done
# ...while the two user-space entry points belong to the account.
for p in "$P_TREE_BIN/sudo-elevation" "$P_TREE_BIN/sudo-askpass"; do
	[ "$(stat -c %U "$p")" = "$ME" ] && ok "user-owned: $p" || bad "$p is owned by $(stat -c %U "$p")"
done
sudo visudo -c >/dev/null 2>&1 && ok "visudo -c clean" || bad "visudo -c failed"

hdr "per-account config layer is honoured"
cat >"$P_USERCFG" <<'EOF'
BASE_MINUTES=7
GUI_BACKEND=auto
EOF
chmod 0644 "$P_USERCFG"
prov=$("$P_TREE_BIN/sudo-elevation" status --porcelain)
grep -qx "cli=$P_TREE_BIN" <<<"$prov" && ok "cli resolved to the user tree" \
	|| bad "cli did not resolve to the user tree: $(grep '^cli=' <<<"$prov")"
grep -q "config\[user\]=$P_USERCFG" <<<"$prov" && ok "user config layer listed" \
	|| bad "user config layer not listed: $(grep 'config\[' <<<"$prov")"
grep -qx "base_minutes=7" <<<"$prov" && ok "base window 7m came from the account layer" \
	|| bad "account layer ignored: $(grep '^base_minutes=' <<<"$prov")"
grep -qF "src_base_minutes=user:$P_USERCFG" <<<"$prov" && ok "source attributed to the account layer" \
	|| bad "no per-key source: $(grep '^src_base_minutes=' <<<"$prov")"

hdr "THE TEST: real dialog through the CLI's own SUDO_ASKPASS"
say "A duration dialog then a password dialog will appear."
say "Pick 15 minutes. Cancelling is a valid outcome and is reported as such."
say "Note: no SUDO_ASKPASS is set below -- the CLI must supply its own."
say ""
rc=0
env -u SUDO_ASKPASS "$P_TREE_BIN/sudo-elevation" request --for 15m --reason "e2e real machine" \
	|| rc=$?
if [ "$rc" = 0 ]; then
	ok "request approved (rc=0)"
else
	say ""
	say "  request exited rc=$rc"
	say "  rc=1 with no dialog usually means the dialog was cancelled or could not open."
	say "  rc=2 would mean a config/sudoers problem; rc=3 a stale request lock."
	FAILED=1
fi

if [ "$rc" = 0 ]; then
	hdr "post-approval state"
	lease="/run/sudo-elevation/$ME.lease"
	[ -f "$lease" ] && ok "lease: $lease" || bad "no lease file"
	grep -q "reason=e2e real machine" "$lease" 2>/dev/null \
		&& ok "reason recorded" || bad "reason not recorded in the lease"
	sudo -n true 2>/dev/null && ok "sudo -n works inside the lease" || bad "sudo -n refused inside the lease"
	# Read the 0440 drop-in once and assert on the copy: every `sudo ...` here
	# would otherwise re-authenticate on its own, which is both noisy and (see
	# the lock section below) capable of invalidating the very thing under test.
	SD=$(sudo cat "$P_SUDOERS")
	grep -qE "^Defaults:.* timestamp_timeout=15$" <<<"$SD" \
		&& ok "sudoers window is 15m" || bad "sudoers window wrong: $SD"
	[ "$(stat -c %U "$lease")" = "$ME" ] && ok "lease owned by the account" \
		|| bad "lease owned by $(stat -c %U "$lease")"
	sudo grep -q "grant user=$ME" /var/log/sudo-elevation.log 2>/dev/null \
		&& ok "machine audit log has the grant" || bad "no machine audit line"
	[ -f "$P_STATE/audit.log" ] && ok "per-account audit log exists" || bad "no per-account audit log"
	[ "$(stat -c %U "$P_STATE/audit.log" 2>/dev/null)" = "$ME" ] \
		&& ok "per-account audit log owned by the account" || bad "per-account audit log wrong owner"
fi

hdr "lock ends the lease and restores the base window"
"$P_TREE_BIN/sudo-elevation" lock
# This check MUST come before any other sudo call: `sudo grep`/`sudo cat` on the
# drop-in authenticates when the cache is empty, and that fresh timestamp would
# make the very next `sudo -n true` succeed -- i.e. the assertion would report
# the failure it just caused.
sudo -n true 2>/dev/null && bad "sudo cache survived lock" || ok "sudo cache cleared"
SD=$(sudo cat "$P_SUDOERS")
grep -qE "^Defaults:.* timestamp_timeout=7$" <<<"$SD" \
	&& ok "sudoers back to the 7m base window from the account layer" \
	|| bad "base window not restored: $SD"

if [ "$KEEP" = 1 ]; then
	say ""
	say "--keep given: leaving the install in place."
	cleanup_hint
	trap - EXIT
	exit "$FAILED"
fi

hdr "purge"
sudo "$REPO/install.sh" --user-install --user "$ME" --uninstall --purge
for p in "$P_TREE_BIN/sudo-elevation" "$P_TREE_BIN/sudo-askpass" \
	"$P_LIBEXEC/grant" "$P_RECEIPT" "$P_USERCFG" "$P_SUDOERS" \
	"$P_STATE/audit.log" "/run/sudo-elevation/$ME.lease"; do
	[ -e "$p" ] && bad "still present: $p"
done
ok "tree, config, receipt, sudoers, lease and audit log all gone"
sudo visudo -c >/dev/null 2>&1 && ok "visudo -c clean after purge" || bad "visudo -c failed after purge"
# NOT asserted: whether `sudo -n` still works. The uninstaller authenticates
# with sudo itself (visudo -c, runuser sudo -k), so a fresh timestamp necessarily
# exists by the time it exits; clearing one from inside is impossible, and it is
# sudo's own cache rather than anything this project owns. The drop-in is gone, so
# the account is back to sudo's own default window.
sudo -n true 2>/dev/null && say "sudo still has a fresh timestamp from the uninstall itself (expected)"

trap - EXIT
say ""
[ "$FAILED" = 1 ] && { say "RESULT: FAILURES ABOVE"; exit 1; }
say "RESULT: user channel works end to end on this machine."
exit 0
