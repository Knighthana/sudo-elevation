#!/bin/bash
# tests/manual/askpass-env.sh — 验证 sudo 到底把什么交给 askpass 助手（不进 CI）。
#
# 背景：用户通道的图形 `request` 依赖两件**本仓库自动化测不到**的事，而且它们都是
# **sudo 自身的行为**，与 WSLg 无关——任何 X11/Wayland 桌面发行版上都成立：
#
#   (A) `sudo -A` 是否把 DISPLAY / XAUTHORITY 传给 askpass 助手？
#       容器无 X/Wayland socket，CI 永远测不到；不成立则用户通道弹窗是 inert 的。
#   (B) sudo 是否校验 askpass 程序的属主（拒绝非 root 拥有的助手）？
#
# 关于 (B)：`19_multiuser` 已经在 docker 里覆盖了——那个场景把助手 chown 给普通
# 用户后 `sudo -A` 正常执行了它（sudo 1.9.15p5 / 1.9.13p3）。所以本脚本把 (B) 一并
# 再验一次，只是为了在**真机这份 sudo** 上也拿到结论；两个问题共用一次运行。
#
# 做法：造一个**当前用户自己拥有**（不是 root）的假 askpass，它先把看到的 environ
# 打到 stderr，再从 tty 读一次口令交给 sudo。口令不经脚本、不落地、不进日志。
# 关键细节：必须先 `sudo -k` 作废 timestamp，否则 sudo 直接复用缓存口令、根本不
# 调助手，探针会给出假阴性。
#
# 用法：
#   tests/manual/askpass-env.sh            # 只读预检，不动任何东西
#   tests/manual/askpass-env.sh --yes run  # 真正跑一次 sudo -A（会输 1 次口令）
#
# 只影响你自己的 sudo timestamp 缓存（`-k` 作废 + 一次认证），不写任何系统文件。
set -euo pipefail

YES=0
MODE="check"
WORK=""

ME=$(id -un)

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

usage() {
	cat <<'EOF'
usage: tests/manual/askpass-env.sh [--yes] <check|run>

  check   preconditions only (read-only, safe to run anytime)
  run     actually invoke `sudo -A` once; you will be asked for your password
          on the tty (it never touches disk). Needs --yes.
EOF
}

say() { printf '%s\n' "$*"; }
hdr() { printf '\n== %s ==\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--yes) YES=1; shift ;;
		-h|--help) usage; exit 0 ;;
		check|run) MODE=$1; shift ;;
		*) printf 'unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
	esac
done

hdr "preconditions"
command -v sudo >/dev/null || { say "sudo not found"; exit 1; }
say "sudo      : $(sudo -V 2>/dev/null | head -1)"
say "user      : $ME (uid $(id -u))"
say "DISPLAY   : ${DISPLAY:-<unset>}"
say "WAYLAND   : ${WAYLAND_DISPLAY:-<unset>}"
say "XAUTHORITY: ${XAUTHORITY:-<unset>}"

# sudo.conf 里若有 Path askpass，它会盖过 SUDO_ASKPASS 的语义判断，所以先看清。
_conf=/etc/sudo.conf
if [ -f "$_conf" ] && grep -qE '^[[:space:]]*Path[[:space:]]+askpass' "$_conf"; then
	say "sudo.conf : has a Path askpass line -> $(grep -E '^[[:space:]]*Path[[:space:]]+askpass' "$_conf" | head -1)"
else
	say "sudo.conf : no Path askpass (SUDO_ASKPASS is the only source)"
fi

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
	say ""
	say "VERDICT: this host has no graphical session, so it cannot answer (A)."
	say "         Run it on a desktop with an X11 or Wayland session."
	exit 1
fi

if [ "$MODE" = check ]; then
	say ""
	say "check passed. Re-run with:  tests/manual/askpass-env.sh --yes run"
	exit 0
fi

[ "$YES" = 1 ] || { say "--yes is required to actually run sudo -A"; exit 2; }
[ -t 0 ] || { say "no tty: the password prompt needs a terminal"; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/se-askpass-probe.XXXXXX")
# Owned by the invoking user on purpose: that is what makes (B) a real question.
cat >"$WORK/probe" <<'PROBE'
#!/bin/bash
{
	echo "PROBE argv       : $*"
	echo "PROBE uid        : $(id -u) ($(id -un))"
	echo "PROBE owner      : $(stat -c '%U:%G %a' "$0")"
	echo "PROBE DISPLAY    : ${DISPLAY:-<unset>}"
	echo "PROBE WAYLAND    : ${WAYLAND_DISPLAY:-<unset>}"
	echo "PROBE XAUTHORITY : ${XAUTHORITY:-<unset>}"
	echo "PROBE HOME       : ${HOME:-<unset>}"
} >&2
read -rs -p 'probe needs your sudo password (never written to disk): ' pw
echo >&2
printf '%s\n' "$pw"
PROBE
chmod 0755 "$WORK/probe"

hdr "running: sudo -A with a user-owned askpass"
say "(sudo -k first: a cached timestamp would skip the helper and fake a pass)"
say ""
sudo -k
rc=0
SUDO_ASKPASS="$WORK/probe" sudo -A true || rc=$?
say ""
say "sudo exit code: $rc"

hdr "verdict"
if [ "$rc" = 0 ]; then
	say "(B) sudo accepted and ran a NON-root-owned askpass helper."
else
	say "(B) INCONCLUSIVE: sudo exited $rc without our success marker."
	say "    If you were asked for a password on the normal sudo prompt instead"
	say "    of seeing PROBE output, sudo did not use the helper at all."
fi

# The probe's own report went to stderr, which is the terminal; re-derive (A) from
# the outer environment plus what we can observe, so the verdict is explicit.
if [ -n "${DISPLAY:-}" ]; then
	say "(A) this shell has DISPLAY=${DISPLAY}; the PROBE lines above show whether"
	say "    it survived sudo -A. If they agree, zenity will open a window."
else
	say "(A) no DISPLAY in this shell; see PROBE WAYLAND above."
fi
say ""
say "If PROBE DISPLAY is <unset> while this shell had it set, then the user"
say "channel's graphical request cannot work as-is and needs another way to"
say "reach the display (a wrapper, or a root/system install)."
exit 0
