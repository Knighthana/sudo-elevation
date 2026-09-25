# Changelog

## Unreleased (breaking: bare uninstall is now interactive)

- change: 不带参数的 `uninstall`（CLI 与 `install.sh`）改为互动模式——列出 receipt/manifest/
  系统痕迹三层发现的每一棵安装，逐棵确认 keep/purge/skip（5 分钟无应答按跳过）；
  无 tty 时只列出精确命令并以非零退出，不删任何东西。脚本请改用显式参数。
- feat: 带参 `uninstall` 即自动模式（无人值守）：零提示、fail-fast（`sudo -n`，无有效
  时间戳直接报错，不挂起）；CLI 放开 `--keep/--user-install/--no-system/--prefix/--user/--skill-dir/--dry-run`，
  显式优先、manifest 补齐；新增 `--keep` 显式档。
- fix: `manifest` 记录 `PREFIX`（卸载请求不符告警）；用户安装优先 receipt 布局，
  不再被残留 `SUDO_ELEVATION_PREFIX` 带偏卸错树；`keep` 后打印按 manifest 配好的二次
  purge 仓库命令（CLI 自删后仍可继续）；交互子调用带显式 flag，不会二次弹提示。
- tests: 新增 `18_autouninstall`（list-only/fail-fast/自动 keep/pty 交互/回放 purge）；
  `06/16` 改用 `--keep`；host 增 list-only 与 pty 交互用例。

## 0.1.6 - 2026-09-24

- feat: XDG 用户目录安装（`--user-install`）：payload 进 `~/.local`、配置进 `~/.config`，
  `env` receipt 自举（显式 env 优先，严格白名单、无 eval）；root 代装 payload 属主归用户；
  `grant`/`restore` 新增 `--config-file`（env 过不了 sudo 边界，CLI 显式透传，定时任务携带）；
  `--no-system` 降级安装/卸载（跳系统文件并打印管理员 snippet）。
- feat: 包管理器式卸载——默认卸软件留配置（租约先落回基窗再删程序，`sudo -A` 在重装前不可用，
  普通 sudo 不受影响）；`--purge` 删干净（含 manifest 外的 ghost sudoers/lease）。
- fix: `sudo.conf` 备份精确删除（manifest 记录自建名；旧版残留只删严格自有格式，管理员备份保留）。
- fix: 重装/卸载不再把租约卡在半空（phase 1 先 restore 到基窗）；systemd transient 注释说明。
- docs: 卸载双模式 + 用户安装章节；CLI `uninstall` 按 manifest 自动转发安装模式。
- tests: `06_uninstall` 拆 keep/purge（含 ghost 与备份精度）；新增 `16_user_install`
  （布局/属主/receipt/真实租约/CLI 转发/keep/purge）；host 增 user dry-run 与 keep/purge 断言。

## 0.1.5 - 2026-09-24

- fix: `lock` tty 回退包 `timeout 15`——无人的 pty 不再挂在口令提示上，15s 超时即报错走人
  （认证超时有专属提示）；`lock -1` 报错中的 `$USER` 改为真实用户名展开。
- fix: kdialog 超时——kdialog 原生无 `--timeout`，改由 shell 层 `timeout(1)` 按 `DIALOG_TIMEOUT`
  强制（与 zenity 对齐，fail-closed）；`DIALOG_TIMEOUT=0` 表不限制。
- change: 非法时长显示按 0 处理（立即过期失败），中英人文案 `未知/unknown` 改为 `0 秒/0 seconds`；
  duration 严格定义为单值单单位，`1m30s` 复合直接报错并给换算提示。
- hardening: `grant requested` 回退校验收紧（与配置同形）。
- docs: reason 双阈值（建议 60 字/硬截断 200）；SKILL 离场预案（无人响应停手汇总）；
  README“何时可以离开”+ KDE 正告（stub 测试、无真机）+ 重装前 `lock` 建议；porcelain 首 `=` 切分约定。
- docs: 9 月 Demand/Code 三份评审报告归档至 `docs/archive/`（精神均已合入）。
- tests: `15_extra` 增复合时长/非法租约/reason 81-201 字/kdialog 慢 stub 超时/重装自愈；
  host 增 skill 60 字+离场规则/1m30s 断言；CI 覆盖新增 stub/wrapper。

## 0.1.4 - 2026-09-24

- P1: `lock` 在无有效 timestamp 时不再假装成功——`until-lock`（`-1`）残留则非零退出并指引
  tty 补 `lock`/`restore`；tty 下自动回退一次交互式 `sudo restore` 真删配置；fallback 文案按
  `-1`/限时区分；README 撤销语义拆分为缓存 vs 配置两层。
- feat: `status --porcelain` 机器可读 KV（`active/minutes/remaining_s/epoch/reason/restore/base_minutes/current_timeout`，
  `remaining_s=-1` 表无限）；人类中文输出不动。
- feat: agent SKILL 全英文精简（~50 行，`status --porcelain`、5 分钟弹窗超时、无人值守时长、
  `until-lock must lock`），人类 README 保持中文详细；`SKILL.md.in` 占位符改为
  `@@BASE_HUMAN_EN@@`/`@@VERSION@@`，`0` 渲染为 strict 提示。
- fix: 卸载 `--dry-run` 真 dry-run（`rmdir`/备份清理全包 `run`，按 glob 逐个删）。
- hardening: `sudo.conf` 备份名加 PID 防同秒碰撞，剪枝改 shell 循环；SKILL `sed` 换 `|` 分隔并转义；
  配置数字校验收紧（拒 `15.5.5`/`.`）；损坏 lease 显示“未知”；`grant -1` 文案去 `sudo -k` 误导；
  超长 reason 截断 stderr 提示；无 GUI 报错附 `grant` 示例；`install.sh --help` 补 MAX/strict 提示。
- docs: 审计范围（只记 grant/restore）、申请阻塞 5 分钟、卸载 headless、MAX 风险提示。
- tests: 新增 `15_extra.sh`（非法时长/reason 截断/porcelain/fail-closed/取消保缓存/C1/C2）；
  host 新增 skill 英文/porcelain/strict/dry-run 断言。

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
