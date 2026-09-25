# sudo-elevation

让 coding agent（opencode 等）在**不保存密码、不配置 NOPASSWD** 的前提下使用 `sudo`：
agent 申请一个**时间租约**，你在图形弹窗里选择批准时长并输入一次密码，
窗口内 agent 的 `sudo -n` 全部免确认；到期后由 sudo 自身强制失效。

面向 **WSL2（Windows 10/11，WSLg）与 Linux 桌面（Debian/Ubuntu/Mint）**，
无图形环境时提供终端审批路径。

```text
agent: sudo-elevation request --for 2h --reason "下载/构建大型依赖"
  [1/2] ┌────────────────────────────────────────────┐
        │ sudo 授权请求 — 选择时长                    │
        │ 请求者: opencode  原因: 下载/构建大型依赖    │
        │ (•) 2 小时（agent 请求）   ( ) 15 分钟       │
        │ ( ) 1 小时   ( ) 4 小时   ( ) 12 小时       │
        │ ( ) 手动输入…  ( ) 仅本次  ( ) 直到 lock    │
        └────────────────── 继续 ────────────────────┘
  [2/2] ┌────────────────────────────────────────────┐
        │ sudo 密码 — 批准 2 小时       [********]    │
        └────────────────── 确定 ────────────────────┘
agent: sudo -n apt-get install ...        # 窗口内免确认
到期：sudo 自动失效，配置回到基础窗口
```

## 与同类项目的差异

| 项目 | 形态 | 密码 | 授权粒度 | 我们的不同 |
| --- | --- | --- | --- | --- |
| **sudo-elevation** | shell + sudoers | **不保存** | **时间租约（agent 请求/用户选时长）**，用 sudo 原生 `timestamp_timeout` 强制到期 | — |
| [sudoplz](https://github.com/crypdick/sudoplz) | Python | SSH key 加密存盘 | 每条命令弹窗 | 我们不存密码；不依赖 SSH key/age/uv |
| [harness-root-hook](https://github.com/MikeRzDev/harness-root-hook) | Claude Code/Codex hook | OS keyring | 固定 2h 缓存 | 不依赖 Secret Service；支持 opencode skill |
| [sido-askpass](https://github.com/patdx/sido-askpass) | Go / npm | 不保存 | 每条命令弹窗 | 我们有租约与时长选择，避免逐条弹窗 |
| [opencode-sudo-popup](https://github.com/uvindusl/opencode-sudo-popup) | opencode 插件 | 不保存 | 每条命令弹窗 | 不依赖 gjs/GTK4；有卸载、审计、headless 路径 |

核心设计：**不保存任何密码**。用户批准一次后，唯一生效的是 sudo 自己的
`timestamp_timeout`（写成租约时长），到期由 sudo 强制执行；一个带 epoch
守卫的恢复任务把配置改回基础窗口（systemd-run，或 WSL 下的后台守护进程；
即使恢复任务失败，最坏结果也只是配置停留在**你所选的**时长，到期后 sudo
照样要求认证）。

## 安装

```bash
git clone git@github.com:Knighthana/sudo-elevation.git sudo-elevation
cd sudo-elevation
sudo ./install.sh                 # 默认用户 $SUDO_USER，基础窗口 15m
```

常用参数：

```text
--user USER          目标用户（默认 $SUDO_USER）
--base-timeout SPEC  基础窗口，默认 15m（strict 可设 0，0 表示每次 sudo 都需密码）
--max-timeout SPEC   单次可批准的最大时长，默认 365d（非长期构建机建议设小，如 12h/7d）
--dry-run            只打印将要执行的操作，不改动系统
--force              接管已存在的其他 Path askpass 配置
--uninstall [--purge] 卸载（--purge 连审计日志一起删）
```

依赖：`bash`、`sudo` >= **1.8.21**（安装时强制校验——租约模型依赖 1.8.21 引入的
`timestamp_type`，更早版本会明确报错拒绝安装）、`awk`/`grep`/`coreutils`/`util-linux`；
图形弹窗需要 `zenity`（GNOME/Mint）或 `kdialog`（KDE 自动降级），**两者皆无时安装仅警告并继续**
（`request` 不可用，改用终端 `grant` 审批）；WSL2 需要 WSLg。
> **KDE 用户注意**：kdialog 分支仅做过参数 stub 测试，无 KDE 真机验证；弹窗超时由 `timeout(1)`
> 按 `DIALOG_TIMEOUT` 强制（与 zenity 对齐），渲染效果未经眼看，长时间无响应请直接关闭窗口或改用终端 `grant`。

## 使用

### agent（通过 skill 指引）

```bash
sudo -n <command>                                  # 平时
sudo-elevation request --for 2h --reason "..."     # 失败或长任务时申请租约
sudo-elevation status                              # 查看剩余租约
sudo-elevation lock                                # 立即撤销
```

### 人类（终端/无头）

```bash
sudo -v                                    # 基础窗口，终端输入密码
sudo-elevation grant --for 12h --reason "通宵构建"   # 终端审批任意时长
sudo-elevation status
sudo-elevation lock
```

时长格式（单值单单位）：`90s` / `45m` / `2h` / `1d`，裸数字=分钟，`until-lock`=直到手动撤销；
不支持 `1m30s` 这类复合写法（请换算，如 `90s`），无法解析的时长会直接报错失败。
弹窗分两步，zenity 与 kdialog 均为**同窗 radio 单选**：先在单选列表里选时长
（agent 请求值默认选中，含“手动输入…”与“仅本次”），再输密码；密码框内**回车即提交**
（选时长窗点“继续”）。kdialog 无真机验证（见上），超时同样按 `DIALOG_TIMEOUT` 强制关闭。

## 行为细节

- **仅本次**：窗口设为 0，授权后立即清理缓存，下一条 sudo 仍会询问。
- **直到手动 lock**：`timestamp_timeout=-1`，`sudo-elevation lock` 前有效；注意 `sudo -k`
  只清本次缓存，**配置仍为 `-1`**，下次任意密码认证会直接获得无限期免密，必须补一次 `lock`。
- **租约结束一律清理 sudo 缓存**，避免短租约“漏”出基础窗口的剩余时间。
- **裸 `sudo -A`**（不走 request）：简单密码弹窗，按基础窗口授权。
- **审计**：`/var/log/sudo-elevation.log` 只记录租约的 grant/restore（请求者/原因/请求与批准时长/恢复方式），
  窗口内实际执行的 sudo 命令不在本项目审计范围，如需溯源请另配 sudo `log_input`/`log_output`。
- **原因长度**：`--reason` 建议 60 字以内（弹窗可读），超 200 字必截断并告警。
- **何时可以离开**：`request` 批准成功即可离开（唯一阻塞点≤5 分钟）；`lock` 成功即可离开；
  `lock` 报错失败必须留下处理，`until-lock` 尤其如此。
- **重装建议**：重装会重置 sudoers 到基础窗口，但活动租约的显示要等旧恢复任务自愈；重装前建议先 `lock`。
- **无 GUI/无 tty**：弹窗失败会快速报错而不是挂起；请改用终端 `grant`。
- **申请阻塞**：图形时长+密码弹窗总超时约 5 分钟（`DIALOG_TIMEOUT`），无人值守请按最长可能时间估足，
  用户 5 分钟不响应则本次申请作废，需重新 `request`。

## 安全模型

> **sudo 的三条经典准则：**
>
> - Respect the privacy of others.（尊重他人的隐私。）
> - Think before you type.（三思而后行。）
> - With great power comes great responsibility.（能力越大，责任越大。）

使用本项目时，默认你已经充分了解了将管理员权限授权给**任何其他人**所带来的风险——**Agent 也不例外**，
且你作为授权者始终需要对被授权者后续所有的行为负责，因此再谨慎也不为过。

- 批准的是**时间窗口**，不是具体命令；窗口内同用户任意进程都可提权。
- 弹窗中的“原因”来自 agent，可能被同用户进程伪造（弹窗会标注）。
- 不保存密码；不修改系统 sudoers 语义之外的任何授权；卸载后完全还原。
- 撤销分两层：**缓存**（`sudo -k` 只清本次 timestamp）与**配置**（`sudo-elevation lock` 恢复基础窗口并删租约）。
  完全撤销必须 `lock`；`until-lock`（`-1`）下仅 `sudo -k`/重启不够，配置仍为无限，必须补 `lock`。
  `lock` 无有效 timestamp 时会明确报错而非假装成功，此时请在有 tty 的终端补一次 `sudo .../restore --force` 或重 `lock`。
- 适用场景：个人工作站/开发用 WSL 发行版；不适合共享或生产主机。

## 测试

```bash
./tests/run-host.sh                  # 非 root 沙箱：安装/卸载/冲突/幂等/钩子剥离/版本比较
tests/docker/run.sh                  # Ubuntu 24.04 + Debian 12 容器矩阵
SE_TEST_IMAGES="debian:12" tests/docker/run.sh 03_lease_expiry.sh
```

Docker 场景覆盖：安装/幂等/权限位、askpass 认证与错误密码、租约到期与自动恢复、
仅本次、until-lock + lock、CLI 卸载（含备份/运行时目录清理）、卸载保留第三方配置、
外来 `Path askpass` 冲突、headless grant、弹窗参数（zenity 与 kdialog）、
epoch 守卫、无 GUI 快速失败、15_extra（非法时长/reason 截断/porcelain/fail-closed/取消保缓存/P1 回归/strict 配置）。

推送/PR 时 GitHub Actions（`.github/workflows/ci.yml`）自动执行
shellcheck + host 沙箱 + Docker 矩阵。

**真机手测**（自动化覆盖不到的部分）：

- ✅ **WSL2/WSLg 已通过**（2026-09-23，Ubuntu 24.04.5 + zenity 4.0.1 +
  kernel 6.18 microsoft-standard-WSL2）：radio 列表时长预选、
  `GDK_BACKEND=x11`（XWayland）、密码框回车提交、`until-lock` 标签非空、
  取消授权弹窗不破坏进行中的租约与 `sudo -n`、跨终端 global timestamp。
- ⏳ 仍待手测：kdialog 真实弹窗（需 KDE 环境）、`systemd-run` 恢复分支
  （本机 PID1 为 WSL `init`，走 `setsid`；需启用 systemd 的 Ubuntu 桌面）、
  `GUI_BACKEND=wayland` 覆盖。
- ⏳ `lock` tty 回退真机半自动：`tests/manual/lock-tty.sh check` 只读预检；
  空闲时 `--yes timeout-only`（全自动约 40s）或有 tty `--yes all`（输 1 次口令约 1min）。不进 CI。

## 用户目录安装（XDG）

```bash
sudo ./install.sh --user-install --user alice     # payload 进 ~/.local，配置进 ~/.config
./install.sh --user-install --no-system           # 免 root 降级安装（仅用户文件，见下）
```

- 布局：可执行文件 `~/.local/bin`、libexec `~/.local/libexec`、数据 `~/.local/share`、
  配置 `~/.config/sudo-elevation/config`、skill 照常、`~/.config/sudo-elevation/env` 记录路径。
- CLI 靠该 receipt 自动定位，无需 export；root 侧 helper 由 CLI 显式传递 `--config-file`。
- sudoers drop-in 与 `sudo.conf` marker 仍是系统文件：要么 root 装，要么 `--no-system`
  跳过并打印管理员 snippet（未应用前工具 inert）。root 代装时 payload 属主归目标用户。
- 卸载同样加 `--user-install`（CLI `uninstall` 按 manifest 自动转发）。

## 卸载（包管理器式两档）

```bash
sudo-elevation uninstall              # 卸软件留配置：租约先落回基窗，sudoers 基窗/marker/配置/manifest/skill/审计保留
sudo-elevation uninstall --purge      # 删干净：配置全删，自有残留按内容认定清除（见下），手建异形文件保留
# 或在仓库目录: sudo ./install.sh --uninstall [--purge]（用户安装加 --user-install）
```

- 默认档结束所有活动租约（sudoers 回基窗、清缓存）后再删程序；`sudo -A` 在重装前不可用
  （askpass 已删），普通 sudo 不受影响。
- `--purge` 不保留自有旧数据（怀疑旧数据有害时用）：自建 `sudo.conf` 备份按 manifest 精确删除，
  旧版残留备份只删严格自有格式（`bak.YYYYMMDDHHMMSS[.PID]`），管理员自有备份保留；
  `sudoers.d/90-sudo-elevation-*` 只删含 `Managed by sudo-elevation` 的自有渲染，手建同前缀文件保留并告警；
  `*.lease` 只删含 `epoch=` + `minutes=/restore=` 的自有租约，外来 `.lease` 保留；
  `SKILL.md` 只删含 `sudo-elevation request` 的自有渲染；`CONFIG/LOG` 异形重定向不删。
  安装剪枝同样只删自有严格形备份，管理员备份永留。
- `--no-system` 装/卸只动用户文件，系统部分打印 snippet 请管理员动手。

## 故障排查

- **弹窗不出现**：确认 `DISPLAY`/`WAYLAND_DISPLAY` 存在；WSL2 需要 WSLg（Win10 需 Store 版 WSL）。
- **WSLg 下下拉菜单/鼠标交互异常**：WSLg 的 Wayland 合成器对 GTK4 弹窗输入处理有缺陷，
  默认已在 WSL 下强制 `GDK_BACKEND=x11`（走 XWayland）；仍异常时可在
  `/etc/sudo-elevation.conf` 调整 `GUI_BACKEND=auto|x11|wayland`（改完重装生效）。
- `libEGL warning ... ZINK ...`：WSLg 无 GPU 直通的软件渲染提示，可忽略。
- **`request` 报“没有可用的图形界面”**：用终端 `sudo -v`（仅基础窗口）或
  `sudo-elevation grant --for N --reason "..."`（终端审批任意时长，见 `grant --help`）。
- **恢复任务**：systemd 用 `systemd-run`；WSL/容器用后台 `setsid` 进程；
  `status` 会显示当前机制，`lock`/重装会自动清理残留配置。
- **卸载 headless 注意**：无有效 timestamp、无 GUI、无 tty 时，`sudo-elevation uninstall`（经 `sudo -A`）
  必然失败，请在有 tty 的终端用 `sudo` 密码执行卸载。
- **`lock` 报恢复失败**：多为无有效 timestamp（如刚 `sudo -k`）；限时租约可等定时恢复或重授权覆盖，
  `until-lock`（`-1`）必须在 tty 补 `lock`，否则配置一直是无限。
  tty 下 `lock` 会尝试一次交互式恢复（15s 输密码超时即报错走人，不会挂起）。

## License

MIT
