# Changelog

## 0.1.0 - 2026-09-20

首个版本。

- 时间租约模型：agent `sudo-elevation request` → 用户图形弹窗选时长 + 输密码 →
  sudo 原生 `timestamp_timeout` 窗口内 `sudo -n` 免确认。
- 不保存密码；`timestamp_type=global`；到期由 sudo 强制失效。
- 弹窗（zenity forms，kdialog 降级）：时长下拉（含 agent 请求值预选、手动输入
  `90s/45m/2h/1d`、仅本次、until-lock）+ 密码。
- root 侧 `grant`/`restore`：visudo 校验后原子写入
  `/etc/sudoers.d/90-sudo-elevation-<user>`，epoch 守卫的自动恢复
  （systemd-run 或后台进程），租约结束清理 sudo 缓存。
- `/etc/sudo.conf` 标记块管理的 `Path askpass`，支持外来配置冲突检测与 `--force`。
- CLI：`request` / `grant` / `status` / `lock` / `parse`。
- opencode skill 按需加载（不占用常驻上下文）。
- 审计日志、卸载、dry-run、`--prefix` 沙箱。
- 测试：host 沙箱 + Docker 矩阵（Ubuntu 24.04 / Debian 12，11 个场景）。
