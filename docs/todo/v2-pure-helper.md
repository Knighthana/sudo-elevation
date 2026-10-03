# v2 纯 helper 计划（零 `/etc/` 写入）

## 背景

v1 用持久 `sudoers drop-in` 装临时租约，回收靠易失物
（`setsid sleep` + `/run/*.lease` tmpfs），重启必残留；
且 `timestamp_timeout` 是滑动续期，不是绝对到期。
v2 改为时间戳保活，不碰任何持久配置。

## 约束

* 只授权单个 agent，会话内有效，不跨 tty（用 sudo 默认 per-tty 时间戳）。
* 重启/挂起后无权限（保活进程死 + `/run/sudo/ts` 失效，自然掉线）。
* `BASE=0`（strict：每次 sudo 都要密码）时不起保活，回退逐条 `sudo -A` 弹窗。

## 决定

* keeper 续期间隔可配置：`KEEPALIVE_INTERVAL`（默认 `min(BASE/2,60s)`），
  键走现有账户层/机器层配置，非法值回落默认。
* `BASE` 默认保持 15m 不变。

## 变更

1. 删除：`grant`/`restore` root helper、`se_render_sudoers`、
   `se_schedule_restore`、`/etc/sudoers.d/` 写入、`sudo.conf Path askpass`
   marker、`visudo` 依赖、`/var/log` 机器审计、
   `se_assert_target_user`/`se_config_trusted`（无 root 面后不再需要）。
2. 安装：只装 `~/.local/bin/{sudo-elevation,sudo-askpass}` + skill；
   卸载即删文件，无需 sudo。
3. 新增用户态 `lease-keeper`：
   - `request --for <dur>`：`sudo -A -v` 认证一次（`SUDO_ASKPASS` 环境变量
     兜底），起 keeper 至 deadline，每 `KEEPALIVE_INTERVAL`
     （默认 `min(BASE/2,60s)`）执行 `sudo -n -v`。
   - `status` 读 `~/.cache/sudo-elevation/lease` 的 deadline。
   - `lock`/到期：`kill keeper + sudo -k`。keeper 死或续期失败即掉线
    （fail-closed）。
4. 审计只写 `~/.local/state/sudo-elevation/audit.log`。
5. 存量迁移：旧机器先 `restore --force` + `uninstall --purge` 清
   `90-sudo-elevation-*` 与 `sudo.conf` 块，再装 v2。

## 测试

* `sudo -n true` 在 keeper 存活时通过，`kill keeper + sudo -k` 后失败。
* 模拟重启（杀 keeper + 清时间戳）后必失败。
* `BASE=0` 回退逐条弹窗用例。
* `run-host.sh` 加“安装过程无 `/etc` 写入”断言。
* 更新 `03_lease_expiry` 等场景的 sudoers 断言为 keeper 断言。

## 不做

* 不支持跨 tty 租约、不支持 `BASE=0` 保活、不做开机任务。
