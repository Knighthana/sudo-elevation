# Changelog

## 0.1.2 - 2026-09-22

- fix: `status` 剩余时间按租约 ID 的前导时间戳换算；0.1.1 起 epoch 为唯一 ID
  （`时间-$$-RANDOM`），旧代码 `$((epoch + secs))` 会把 pid/random 一并做算术，
  导致剩余时间偏小、短租约提前显示“已到期”。
- 测试: host 沙箱新增合成租约的剩余时间换算断言；headless grant 场景校验
  活动租约期间 `status` 不显示“已到期”。

## 0.1.1 - 2026-09-20

- fix: 租约 ID 改为唯一值（`时间-$$-RANDOM`）；此前 `date +%s` 在同一秒内连续
  授权会得到相同 epoch，导致旧恢复任务误判并提前恢复新租约。
- UI: WSLg 下默认强制 `GDK_BACKEND=x11`（可用 `/etc/sudo-elevation.conf` 的
  `GUI_BACKEND=auto|x11|wayland` 覆盖），修复 GTK4 弹出层输入异常。
- UI: 时长选择改为同窗 radio 列表（不再使用 GTK combo 弹出层，避免 WSLg
  合成器延迟导致的残留）；密码单独弹窗，输入后回车即可提交。
- CLI: `status` 人性化显示当前 sudoers 窗口（`20 秒` 而不是 `0.333... 分钟`）。
- 测试: 新增租约循环与重叠租约场景；Docker 驱动实时输出、每场景计时与超时，
  可区分“docker CLI 退出挂起”与“场景真卡住”。

## 0.1.0 - 2026-09-20

首个版本。

- 时间租约模型：agent `sudo-elevation request` → 用户图形弹窗选时长 + 输密码 →
  sudo 原生 `timestamp_timeout` 窗口内 `sudo -n` 免确认。
- 不保存密码；`timestamp_type=global`；到期由 sudo 强制失效。
- 弹窗（zenity，kdialog 降级）：时长选择、手动输入、仅本次、until-lock。
- root 侧 `grant`/`restore`：visudo 校验后原子写入
  `/etc/sudoers.d/90-sudo-elevation-<user>`，epoch 守卫的自动恢复
  （systemd-run 或后台进程），租约结束清理 sudo 缓存。
- `/etc/sudo.conf` 标记块管理的 `Path askpass`，支持外来配置冲突检测与 `--force`。
- CLI：`request` / `grant` / `status` / `lock` / `parse`。
- opencode skill 按需加载（不占用常驻上下文）。
- 审计日志、卸载、dry-run、`--prefix` 沙箱。
- 测试：host 沙箱 + Docker 矩阵（Ubuntu 24.04 / Debian 12）。
