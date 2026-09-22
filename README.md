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
git clone <repo-url> sudo-elevation
cd sudo-elevation
sudo ./install.sh                 # 默认用户 $SUDO_USER，基础窗口 15m
```

常用参数：

```text
--user USER          目标用户（默认 $SUDO_USER）
--base-timeout SPEC  基础窗口，默认 15m（strict 可设 0）
--max-timeout SPEC   单次可批准的最大时长，默认 365d
--dry-run            只打印将要执行的操作
--force              接管已存在的其他 Path askpass 配置
--uninstall [--purge] 卸载（--purge 连审计日志一起删）
```

依赖：`bash`、`sudo` >= **1.8.21**（安装时强制校验——租约模型依赖 1.8.21 引入的
`timestamp_type`，更早版本会明确报错拒绝安装）、`awk`/`grep`/`coreutils`/`util-linux`；
图形弹窗需要 `zenity`（GNOME/Mint）或 `kdialog`（KDE 自动降级），**两者皆无时安装仅警告并继续**
（`request` 不可用，改用终端 `grant` 审批）；WSL2 需要 WSLg。

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

时长格式：`90s` / `45m` / `2h` / `1d`，裸数字=分钟，`until-lock`=直到手动撤销。
弹窗分两步，zenity 与 kdialog 均为**同窗 radio 单选**：先在单选列表里选时长
（agent 请求值默认选中，含“手动输入…”与“仅本次”），再输密码；密码框内**回车即提交**
（选时长窗点“继续”）。

## 行为细节

- **仅本次**：窗口设为 0，授权后立即清理缓存，下一条 sudo 仍会询问。
- **直到手动 lock**：`timestamp_timeout=-1`，重启或 `sudo-elevation lock` 前有效。
- **租约结束一律清理 sudo 缓存**，避免短租约“漏”出基础窗口的剩余时间。
- **裸 `sudo -A`**（不走 request）：简单密码弹窗，按基础窗口授权。
- **审计**：`/var/log/sudo-elevation.log` 记录请求者/原因/请求与批准时长/恢复方式。
- **无 GUI/无 tty**：弹窗失败会快速报错而不是挂起；请改用终端 `grant`。

## 安全模型

- 批准的是**时间窗口**，不是具体命令；窗口内同用户任意进程都可提权。
- 弹窗中的“原因”来自 agent，可能被同用户进程伪造（弹窗会标注）。
- 不保存密码；不修改系统 sudoers 语义之外的任何授权；卸载后完全还原。
- 撤销：`sudo-elevation lock`、`sudo -k`、重启。
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
epoch 守卫、无 GUI 快速失败。

推送/PR 时 GitHub Actions（`.github/workflows/ci.yml`）自动执行
shellcheck + host 沙箱 + Docker 矩阵。

**自动化覆盖不到、发布前真机手测**：zenity/kdialog 真实弹窗点击交互、
WSL2/WSLg 下 `GDK_BACKEND=x11` 的输入行为。

## 卸载

```bash
sudo-elevation uninstall              # 无需仓库；--purge 连审计日志一起删
# 或在仓库目录: sudo ./install.sh --uninstall [--purge]
```

卸载会：终止进行中的恢复任务并撤销租约、按 manifest 清理**所有**曾安装用户的
sudoers/skill、从 `sudo.conf` 只摘除标记块（外来内容原样保留）、删除全部安装文件
（含 `sudo.conf.bak.*` 备份与 `/run/sudo-elevation`），最后 `visudo -c` 自检；
审计日志默认保留，`--purge` 才删除。

## 故障排查

- **弹窗不出现**：确认 `DISPLAY`/`WAYLAND_DISPLAY` 存在；WSL2 需要 WSLg（Win10 需 Store 版 WSL）。
- **WSLg 下下拉菜单/鼠标交互异常**：WSLg 的 Wayland 合成器对 GTK4 弹窗输入处理有缺陷，
  默认已在 WSL 下强制 `GDK_BACKEND=x11`（走 XWayland）；仍异常时可在
  `/etc/sudo-elevation.conf` 调整 `GUI_BACKEND=auto|x11|wayland`（改完重装生效）。
- `libEGL warning ... ZINK ...`：WSLg 无 GPU 直通的软件渲染提示，可忽略。
- **`request` 报“没有可用的图形界面”**：用终端 `sudo -v` 或 `sudo-elevation grant --for N`。
- **恢复任务**：systemd 用 `systemd-run`；WSL/容器用后台 `setsid` 进程；
  `status` 会显示当前机制，`lock`/重装会自动清理残留配置。

## License

MIT
