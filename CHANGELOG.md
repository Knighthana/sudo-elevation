# Changelog

## 0.1.3 - 2026-09-22

- install: 强制校验 `sudo >= 1.8.21`（租约模型依赖该版本引入的 `timestamp_type`，
  解析兼容新旧 `sudo -V` 首行格式）；zenity/kdialog 皆无时警告并继续安装
  （GUI request 不可用，可走终端 `grant`），不再静默。
- feat: `sudo-elevation uninstall [--purge]` CLI 子命令——`install.sh` 随安装部署到
  libexec，卸载无需再 clone 仓库。
- fix: 卸载清理 `sudo.conf.bak.*` 备份与 `/run/sudo-elevation` 运行时目录残留；
  安装时备份 prune 只保留最新一份。
- security: 租约文件改为 `0600` 且属主为租约用户（同机其他用户不可读 reason，
  `status` 本人仍可读）。
- change: 生产安装默认剥离 askpass 的 fake/print 测试钩子，测试套件用
  `--test-hooks` 保留。
- UI: kdialog 分支由 combobox 改为同窗 `--radiolist`，与 zenity 两步流程对齐；
  修复 agent 请求 `until-lock` 时时长行显示为空的问题。
- docs: SKILL 时长估算改为场景化规则（用户在场申请短时长；无人值守按任务
  最长可能时间估足，避免中途到期无人可批）。
- ci: 新增 GitHub Actions（shellcheck + host 沙箱 + Docker 矩阵）；
  测试新增 kdialog stub 场景与 CLI 卸载场景。
- fix: `request` 在已有有效 timestamp 时改为 `sudo -k -A`（仅本次命令忽略缓存
  以强制弹窗，取消时不清除缓存）；timestamp 无效时仍用 `sudo -A`（成功后正常
  刷新缓存）。此前无条件 `sudo -k` 会在用户取消授权弹窗后清掉全局 timestamp，
  导致租约仍有效但 `sudo -n` 立即失败、需重新输一次密码。
- docs: 标记 WSL2/WSLg 真机手测通过（Ubuntu 24.04.5 + zenity 4.0.1）。

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
