#!/bin/bash
# tests/manual/lock-tty.sh — lock tty 回退的真机半自动回归（不进 CI）。
#
# 背景：`sudo-elevation lock` 在无有效 timestamp 时，若有 tty 会尝试一次交互式
# `sudo restore`（`timeout 15` 包裹）。docker/CI 里没有真 tty + 真口令，所以这条
# 路径只能在真机验证。本脚本把“机器能做的”全部自动化，人只负责输口令：
#
#   无 tty（agent/无人值守）: T1 短限时租约版——全自动，定时恢复自愈，结束干净。
#   有 tty（人类终端）      : T1 until-lock 版（断言 fail-loud）+ T2（输一次口令跑通），结束干净。
#
# 口令只进 sudo 的 pty 口令提示，不经脚本、不落地、不进日志：
# T1 用 python-pty 采输出（无口令可录），T2 人直接在自己终端跑 lock（不录制）。
#
# 用法：
#   tests/manual/lock-tty.sh check                       # 预检（只读，可随便跑）
#   tests/manual/lock-tty.sh --yes timeout-only          # 无 tty 全自动（约 40s）
#   tests/manual/lock-tty.sh --yes all                   # 有 tty 半自动（约 1min，人输 1 次口令）
#   tests/manual/lock-tty.sh --yes success-only          # 仅 T2（已有 -1 残留态时）
#
# 要求：空闲机器（会临时改 sudoers 窗口并清 timestamp）、起始有有效 timestamp
# （setup 需免口令 grant，否则先 `sudo -v` 一次）。
set -euo pipefail

MODE=""
YES=0
CLI=""
GRANT_BIN=""
RESTORE_BIN=""
ME=$(id -un)
WORK=""

usage() {
	cat <<'EOF'
usage: tests/manual/lock-tty.sh [--yes] <check|timeout-only|all|success-only>

  check          preconditions only (read-only)
  timeout-only   T1 with a short timed lease (fully automatic, self-healing)
  all            T1 with until-lock (asserts fail-loud) + T2 (one password entry)
  success-only   T2 only (requires an existing until-lock residual state)

--yes is required for every mutating mode. Never runs in CI (needs a real
host, real sudo, and for T2 a human password typed into sudo's own prompt).
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--yes) YES=1; shift ;;
		--mode=*) MODE=${1#--mode=}; shift ;;
		-h|--help) usage; exit 0 ;;
		check|timeout-only|all|success-only)
			[ -z "$MODE" ] || { echo "mode given twice" >&2; exit 2; }
			MODE=$1; shift ;;
		*) echo "unknown argument: $1" >&2; usage; exit 2 ;;
	esac
done
[ -n "$MODE" ] || { usage; exit 2; }

log() { printf '\n== %s ==\n' "$*"; }
ok() { printf '  ok: %s\n' "$*"; }
die() {
	printf '  FAIL: %s\n' "$*" >&2
	printf '  恢复参考: sudo -v 输密码拿回 timestamp，再 sudo-elevation lock\n' >&2
	exit 1
}

need_yes() {
	if [ "$YES" != 1 ]; then
		echo "mutating mode needs --yes (idle machine: sudoers window + timestamp will change briefly)" >&2
		exit 2
	fi
}

probe_files() {
	# NOTE: [ -x name ] does NOT search PATH; resolve to an absolute path.
	CLI=$(command -v sudo-elevation 2>/dev/null || true)
	[ -n "$CLI" ] || CLI=/usr/local/bin/sudo-elevation
	GRANT_BIN=/usr/local/libexec/sudo-elevation/grant
	RESTORE_BIN=/usr/local/libexec/sudo-elevation/restore
	[ -x "$CLI" ] || die "CLI not installed: $CLI"
	[ -x "$GRANT_BIN" ] || die "grant helper missing: $GRANT_BIN"
	[ -x "$RESTORE_BIN" ] || die "restore helper missing: $RESTORE_BIN"
}

porc() { "$CLI" status --porcelain 2>/dev/null; }
kv() { sed -n "s/^$2=//p" <<<"$1"; }

# pty runner: runs "$@" with stdio on a pty that IS the controlling terminal
# (sudo reads its password from /dev/tty; a bare pipe/slave without ctty
# would make sudo fail fast instead of exercising the timeout path).
# Nobody writes to the master side, so no human is behind it. Prints child
# output, then a marker line: [ptyrun: rc=N elapsed=Ss]
write_ptyrun() {
	cat > "$WORK/ptyrun.py" <<'PY'
import fcntl, os, pty, select, subprocess, sys, termios, time

def make_ctty():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)

m, s = pty.openpty()
t0 = time.time()
p = subprocess.Popen(sys.argv[1:], stdin=s, stdout=s, stderr=s,
                     close_fds=True, preexec_fn=make_ctty)
os.close(s)
out = b""
deadline = t0 + 120
while True:
    if p.poll() is not None:
        try:
            while True:
                chunk = os.read(m, 65536)
                if not chunk:
                    break
                out += chunk
        except OSError:
            pass
        break
    if time.time() > deadline:
        p.kill()
        out += b"\n[ptyrun: deadline exceeded, killed]\n"
        break
    r, _, _ = select.select([m], [], [], 1.0)
    if r:
        try:
            chunk = os.read(m, 65536)
        except OSError:
            continue
        if chunk:
            out += chunk
elapsed = time.time() - t0
os.close(m)
sys.stdout.buffer.write(out)
print(f"\n[ptyrun: rc={p.returncode} elapsed={elapsed:.1f}s]", flush=True)
PY
}

# run "$@" on a pty with no input; sets PTY_OUT/PTY_RC/PTY_ELAPSED.
pty_run() {
	local outf=$WORK/pty-out.log
	python3 "$WORK/ptyrun.py" "$@" > "$outf" 2>&1
	PTY_OUT=$(cat "$outf")
	PTY_RC=$(tail -n 1 "$outf" | sed 's/.*rc=\(-\?[0-9]*\).*/\1/')
	PTY_ELAPSED=$(tail -n 1 "$outf" | sed 's/.*elapsed=\([0-9.]*\)s.*/\\1/')
	[ -n "$PTY_RC" ] && [ -n "$PTY_ELAPSED" ] || die "pty runner broke: $(tail -n 1 "$outf")"
}

in_range() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v+0 >= lo && v+0 <= hi)}'; }

check_ts() {
	sudo -n true 2>/dev/null || die "no valid timestamp: run sudo -v once first (human types password into sudo)"
}

do_check() {
	log "preconditions (read-only)"
	command -v python3 >/dev/null || die "python3 missing"
	python3 -c "import pty, select" || die "python pty/select missing"
	probe_files
	ok "installed: $CLI"
	if [ -t 0 ] || [ -t 1 ]; then
		ok "tty detected: T2 possible"
	else
		ok "no tty: only timeout-only possible"
	fi
	if sudo -n true 2>/dev/null; then
		ok "cached timestamp present (setup can be non-interactive)"
	else
		printf '  note: no cached timestamp (run sudo -v first before mutating modes)\n'
	fi
	printf '\nCHECK DONE\n'
}

# --- T1 with a short timed lease: fully automatic, self-healing ------------
t1_timed() {
	log "T1-timeout: short timed lease, pty, zero input"
	check_ts
	sudo -n "$GRANT_BIN" --user "$ME" --minutes 0.1 --reason "lock-tty manual" >/dev/null \
		|| die "setup grant failed"
	[ "$(kv "$(porc)" active)" = 1 ] || die "lease not active after grant"
	ok "timed lease active"
	sudo -k || true
	write_ptyrun
	pty_run "$CLI" lock
	[ "$PTY_RC" = 0 ] || die "lock rc=$PTY_RC, want 0 (output: $PTY_OUT)"
	in_range "$PTY_ELAPSED" 13 25 || die "elapsed=$PTY_ELAPSED, want ~15s (timeout kill?)"
	grep -qF '15s' <<<"$PTY_OUT" || die "timeout message missing: $PTY_OUT"
	ok "timeout kill in ${PTY_ELAPSED}s, rc=0"
	log "waiting for scheduled restore to self-heal"
	for _i in $(seq 1 40); do
		[ "$(kv "$(porc)" active)" = 0 ] && break
		sleep 1
	done
	[ "$(kv "$(porc)" active)" = 0 ] || die "lease did not self-heal"
	sudo -n true 2>/dev/null && die "cache should be cleared" || true
	ok "self-healed: no lease, no cache"
}

# --- T1 with until-lock on a pty: asserts fail-loud, leaves residual --------
t1_until() {
	log "T1-fail-loud: until-lock lease, pty, zero input"
	check_ts
	sudo -n "$GRANT_BIN" --user "$ME" --minutes -1 --reason "lock-tty manual" >/dev/null \
		|| die "setup grant failed"
	sudo -k || true
	write_ptyrun
	pty_run "$CLI" lock
	[ "$PTY_RC" != 0 ] || die "lock should fail on -1 residual without tty"
	grep -qF '15s' <<<"$PTY_OUT" || die "timeout message missing: $PTY_OUT"
	grep -qF 'until-lock' <<<"$PTY_OUT" || die "until-lock hint missing: $PTY_OUT"
	out=$(porc)
	[ "$(kv "$out" active)" = 1 ] && [ "$(kv "$out" minutes)" = "-1" ] \
		|| die "residual -1 not preserved: $out"
	ok "fail-loud with residual preserved (this dirt is T2's setup)"
}

# --- T2: human types one password into the real tty --------------------------
t2_success() {
	log "T2-success: type YOUR sudo password once at the prompt (<=15s)"
	out=$(porc)
	[ "$(kv "$out" active)" = 1 ] && [ "$(kv "$out" minutes)" = "-1" ] \
		|| die "need until-lock residual state first"
	base=$(kv "$out" base_minutes)
	[ -n "$base" ] || die "cannot read base window"
	# Inherits this terminal: the password goes to sudo, never to the script.
	"$CLI" lock || die "lock failed even with tty"
	ok "lock rc=0"
	out=$(porc)
	[ "$(kv "$out" active)" = 0 ] || die "lease still active: $out"
	[ "$(kv "$out" current_timeout)" = "$base" ] || die "window not restored: $out"
	ok "base window restored, lease gone"
	sudo -n true 2>/dev/null || die "fresh timestamp missing after password auth"
	ok "fresh timestamp present"
}

MODE_TTY=0
if [ -t 0 ] || [ -t 1 ]; then MODE_TTY=1; fi

case "$MODE" in
	check)
		do_check
		;;
	timeout-only)
		need_yes
		[ "$MODE_TTY" = 0 ] || printf '  note: tty present but timeout-only requested; no password needed\n'
		WORK=$(mktemp -d /tmp/se-locktty.XXXXXX)
		trap 'rm -rf "$WORK"' EXIT
		probe_files
		t1_timed
		out=$(porc)
		[ "$(kv "$out" active)" = 0 ] || die "not clean at end: $out"
		printf '\nTIMEOUT-ONLY PASSED (machine clean)\n'
		;;
	all)
		need_yes
		[ "$MODE_TTY" = 1 ] || die "all needs a human tty for T2; use timeout-only instead"
		WORK=$(mktemp -d /tmp/se-locktty.XXXXXX)
		trap 'rm -rf "$WORK"' EXIT
		probe_files
		t1_until
		t2_success
		printf '\nALL PASSED (machine clean)\n'
		;;
	success-only)
		need_yes
		[ "$MODE_TTY" = 1 ] || die "success-only needs a human tty"
		probe_files
		t2_success
		printf '\nSUCCESS-ONLY PASSED (machine clean)\n'
		;;
	*)
		echo "unknown mode: $MODE" >&2
		exit 2
		;;
esac
