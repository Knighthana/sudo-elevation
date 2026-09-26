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
--uninstall [--purge] 卸载：裸命令是互动发现（列出并逐棵确认），带参进自动模式；
  详见“卸载”节（`--keep/--user-install/--no-system/--prefix/--user/--skill-dir/--dry-run`）
```

依赖：`bash`、`sudo` >= **1.8.21**（安装时强制校验——租约模型依赖 1.8.21 引入的
`timestamp_type`，更早版本会明确报错拒绝安装）、`awk`/`grep`/`coreutils`/`util-linux`；
图形弹窗需要 `zenity`（GNOME/Mint）或 `kdialog`（KDE 自动降级），**两者皆无时安装仅警告并继续**
（`request` 不可用，改用终端 `grant` 审批）；WSL2 需要 WSLg。
> **KDE 用户注意**：kdialog 分支仅做过参数 stub 测试，无 KDE 真机验证；弹窗超时由 `timeout(1)`
> 按 `DIALOG_TIMEOUT` 强制（与 zenity 对齐），渲染效果未经眼看，长时间无响应请直接关闭窗口或改用终端 `grant`。

## 配置

两个配置层，后者覆盖前者：

| 层 | 路径 | 属主 | 作用范围 |
|---|---|---|---|
| 机器层 | `/etc/sudo-elevation.conf` | root | 整台机器的默认策略 |
| 账户层 | `~/.config/sudo-elevation/config` | 该用户 | 只影响该账户，**与用哪棵树无关** |

优先级：**命令行参数 > 账户层 > 机器层 > 内置默认值**。

```bash
# 机器级（root）
printf 'MAX_MINUTES=720\nGUI_BACKEND=wayland\n' | sudo tee /etc/sudo-elevation.conf

# 账户级：自己收紧审批上限，不必动 root 的文件
mkdir -p ~/.config/sudo-elevation
printf 'MAX_MINUTES=60\n' > ~/.config/sudo-elevation/config
```

可配置键（数值单位为分钟，允许小数）：

| 键 | 默认 | 含义 |
|---|---|---|
| `BASE_MINUTES` | 15 | 基础窗口（无活动租约时每次 `sudo` 仍要密码，超时后回到此窗口） |
| `MAX_MINUTES` | 525600 | 单次可批准的最大时长；上限硬性封顶 525600（一年） |
| `DIALOG_TIMEOUT` | 300 | 弹窗无响应超时（0 表示不限） |
| `REQUEST_TTL` | 300 | `request` 缓存文件有效期 |
| `GUI_BACKEND` | auto | `auto\|x11\|wayland`，即 `GDK_BACKEND` |

要点：

- **重装不会丢配置。** 不带 `--base-timeout/--max-timeout` 重装时，已有值原样保留；
  显式传 flag 才覆盖对应键。根目录的 `BASE_MINUTES` 还会同步到 sudoers drop-in，
  不会出现「配置写 25m、sudoers 还是 15m」的不一致。
- **每次弹窗实时读取**，改完无需重装，也不会被写回覆盖。
- 手写错的数值（非数字、超范围、`BASE > MAX`）会被拒绝安装并报错；只是「不像数字」的
  值按内置默认回落（fail-safe）。
- 装用户通道时，账户层就是被安装器管理的那个文件，不存在“机器层”。

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
- **审计**：只记录租约的 grant/restore（请求者/原因/请求与批准时长/恢复方式），写两处：
  机器级 `/var/log/sudo-elevation.log`（root 0600，混记所有账户、带 `actor=`）与账户级
  `~/.local/state/sudo-elevation/audit.log`（同一行，账户自有 0600，用户可自己看）。
  两者都**不自动轮转**，长期运行请自行配 logrotate。
  窗口内实际执行的 sudo 命令不在本项目审计范围，如需溯源请另配 sudo `log_input`/`log_output`。
- **并发**：同一账户同时只允许一个 `request` 等待审批（`~/.cache/sudo-elevation/.request.lock`）；
  第二个会直接报错退出，不会覆盖第一个的请求内容。陈旧锁（超过弹窗超时 +120s）自动接管。
- **原因长度**：`--reason` 建议 60 字以内（弹窗可读），超 200 字必截断并告警。
- **何时可以离开**：`request` 批准成功即可离开（唯一阻塞点≤5 分钟）；`lock` 成功即可离开；
  `lock` 报错失败必须留下处理，`until-lock` 尤其如此。
- **重装建议**：重装会重置 sudoers 到基础窗口，但活动租约的显示要等旧恢复任务自愈；重装前建议先 `lock`。
  重装**不会**覆盖已有配置（除非显式传 `--base-timeout/--max-timeout`），也不会动账户层。
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
epoch 守卫、无 GUI 快速失败、15_extra（非法时长/reason 截断/porcelain/fail-closed/取消保缓存/P1 回归/strict 配置）、
16_user_install（XDG 布局/属主/receipt/keep-purge）、17_preserve（不误删：ghost 内容认定/备份精度/外来保留）、
18_autouninstall（裸 list-only/fail-fast/自动 keep/pty 交互/回放 purge）。

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
- ⏳ **用户通道的 askpass 兜底路径**（本次新增，CI 只能证明变量送到了 sudo）：
  还需在任一 X11/Wayland 真机上确认两件 **sudo 自身**的行为——(1) `sudo -A`
  是否把 `DISPLAY`/`XAUTHORITY` 传给 askpass；(2) sudo 是否校验 askpass 程序属主
  （用户属主的 `~/.local/bin/sudo-askpass` 是否被接受）。这两条与 WSLg 无关，
  任何桌面发行版上都成立；任一条不成立，用户通道的图形 `request` 就是不可用。
- ⏳ `lock` tty 回退真机半自动：`tests/manual/lock-tty.sh check` 只读预检；
  空闲时 `--yes timeout-only`（全自动约 40s）或有 tty `--yes all`（输 1 次口令约 1min）。不进 CI。

## 用户目录安装（XDG）

```bash
sudo ./install.sh --user-install --user alice     # payload 进 ~/.local，配置进 ~/.config
./install.sh --no-system                       # 免 root 降级安装（自动进目标用户 XDG，同上）
```

- 布局：可执行文件 `~/.local/bin`、libexec `~/.local/libexec`、数据 `~/.local/share`、
  配置 `~/.config/sudo-elevation/config`、skill 照常、`~/.config/sudo-elevation/env` 记录路径。
- CLI 靠该 receipt 自动定位，无需 export；root 侧 helper 由 CLI 显式传递 `--config-file`。
- **askpass 由 CLI 自己解决**：sudo 只能从 `SUDO_ASKPASS` 环境变量或 sudo.conf 的
  `Path askpass` 找弹窗程序，而后者是**机器级、每台机器只有一个、对所有账户生效**。
  所以用户安装**不写** `Path askpass`（否则等于把全机 `sudo -A` 交给某个用户的家目录）；
  改为 `sudo-elevation` 在调用 `sudo -A` 前自行导出 `SUDO_ASKPASS` 指向本树。
  这只影响 CLI 自己的调用——**裸 `sudo -A <cmd>` 仍需 root 装系统通道**。
  显式设置过 `SUDO_ASKPASS` 的用户不会被覆盖。
- sudoers drop-in 仍是系统文件（按用户切片，`/etc/sudoers.d/90-sudo-elevation-<user>`）：
  要么 root 装，要么 `--no-system` 跳过并打印管理员 snippet（未应用前工具 inert）。
- `--no-system` 的含义就是不动任何系统目录（`/usr/local`、`/etc`、`/run`、
  `/var/log` 都不碰）：不带 `--prefix` 时自动采用目标用户的 XDG 布局，
  root 执行则装进 root 自己的家目录；卸载时按 manifest 记录的布局清理。
- 卸载：CLI（`sudo-elevation uninstall`）按 manifest 自动补齐缺失 flags；
  直接调 `install.sh --uninstall` 则布局 flags 需显式给全（`--user-install/--no-system/--prefix/--user/--skill-dir`），
  只告警不自动补（`PREFIX` 不符会明确警告）。

## 多用户 / 服务器

同一台机器上多个账户各自使用时，边界如下（均已在代码里强制，不只是文档约定）：

- **root helper 只作用于调用者自己**。`grant`/`restore` 经 sudo 被调用时，
  `--user` 必须等于 `$SUDO_USER`；否则拒绝（防止 `sudo .../grant --user 别人` 改写他人窗口）。
  root **直接**运行（不经 sudo，或 root 自己 `sudo`）时可指定其他账户。
- **root 只加载可信配置**。`--config-file` 指向的文件必须 root 拥有且非组/全局可写，
  或属于目标用户；否则拒绝。避免调用者自选 `MAX_MINUTES` 绕过机器策略。
- **root 运行的代码永远 root 属主**。`grant`/`restore`/`common.sh` 即使用户安装也
  保持 `root:root`——CLI 只需要可读可执行。旧版本 `chown -R` 留下的非 root 属主
  会在下次安装时收回并告警。
- **sudoers drop-in 按用户切片**，租约文件 `/run/sudo-elevation/<user>.lease` 为 0600
  属该用户；A 的租约与 `lock` 不影响 B。
- **审批上限 `MAX_MINUTES` 默认是机器级的**（`/etc/sudo-elevation.conf`）：一户调整会影响全机。
  要按账户收紧，让该用户写自己的 `~/.config/sudo-elevation/config`（账户层优先，
  且与他人的配置互不影响）。
- **`timestamp_type=global`**：租约会同时授权该用户的所有会话（含 tmux/screen），
  这是设计意图，但共享会话的服务器上要知道这一点。
- **卸载只作用于自己**。默认只处理 `--user` 指定的账户；只要 manifest 里还有别的账户在用，
  共享的 payload / `sudo.conf` marker / 机器配置就**保留不动**，以免把别人的 `sudo -A` 弄坏。
  确认整机下线时才用 `--all-users`。账户被移除后 manifest 的 `USERS` 会同步更新，
  否则机器永远清不干净。
- **审计**：机器级 `/var/log/sudo-elevation.log`（root 0600，混记所有账户、带 `actor=`）
  + 账户级 `~/.local/state/sudo-elevation/audit.log`（同一行、账户自有 0600，用户可自己读）。
  两者均无自动轮转。
- **用户名里的 `.` 和 `_` 曾共用文件**。旧的 slug 映射把 `a.b` 和 `a_b` 都变成 `a_b`，
  两个账户共用一份 sudoers drop-in 和一份租约，可以互相结束窗口、覆盖时长。
  现已改为单射编码（`a.b` → `a__2e__b`）；不含 `.`/`_` 的普通用户名不变，
  旧名残留文件在下次授权时自动清理。
- **`/run` 是 tmpfs**：租约文件与自动恢复任务重启即失，`until-lock` 也不例外。
- **未覆盖**：`grant`/`restore` 需要调用者**已有宽权限 sudo**（项目只写 `Defaults:`，
  从不写命令规则、不碰 `NOPASSWD`）。给账户限定 `apt, systemctl` 之类时，
  图形 `request` 不可用——见下方故障排查。

## 卸载（包管理器式两档）

```bash
sudo-elevation uninstall              # 互动：列出所有安装并逐棵确认（keep/purge/skip），无 tty 时只列出
sudo-elevation uninstall --purge      # 自动：无人值守，要求有效 sudo 时间戳（先 sudo -v），无提示
sudo-elevation uninstall --keep       # 自动：显式 keep，供脚本使用（裸命令已改为互动）
# 或在仓库目录: sudo ./install.sh --uninstall [--keep|--purge] [--user-install] [--no-system] [--prefix DIR] [--user U] [--skill-dir D] [--dry-run]
# （布局 flags 需显式，见上）
```

- 带参即自动模式：零提示、失败即停（fail-fast，无密码提示挂起）；`--user-install/--no-system/--prefix/--user/--skill-dir/--dry-run`
  可钉死单棵树，CLI 未给的按 manifest 自动补齐（直接调 `install.sh` 需给全）；`--dry-run` 即预览，
  无 timestamp 时降级为尽力预览并警告。
- 不带参即互动模式：receipt + manifest + 系统痕迹三层发现，每棵展示模式/用户/租约/skill/备份与精确命令，
  当场确认；提示 5 分钟无应答按跳过；无 tty 时只列出并退出（需处理时返回码非零）。
- `keep` 会删掉 CLI 与自带卸载器（manifest 保留），二次 purge 用当时打印的仓库命令
  （如 `sudo ./install.sh --user-install --uninstall --purge`，flags 已按 manifest 配好）。
- 默认档结束所有活动租约（`--no-system` 除外，只打印管理员 snippet；sudoers 回基窗、清缓存）后再删程序；
  `sudo -A` 在重装前不可用（askpass 已删），普通 sudo 不受影响。
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
  `/etc/sudo-elevation.conf` 调整 `GUI_BACKEND=auto|x11|wayland`。
  该文件**每次弹窗实时读取，改完无需重装**；若租约/时间戳仍有效，sudo 压根不会调
  askpass，先 `sudo -k`（或 `sudo-elevation lock`）再试。
- `libEGL warning ... ZINK ...`：WSLg 无 GPU 直通的软件渲染提示，可忽略。
- **`request` 报“不在 sudoers 允许范围内 / not allowed to execute”**：本项目只写
  `Defaults:`（时间窗），**从不写命令规则、不碰 `NOPASSWD`**，所以它要求你**已有宽权限
  sudo**。sudoers 被限定到少数命令的账户无法运行 `grant`/`request`，请改用已有的
  宽权限账户，或由管理员放宽（放宽时请注意 `grant` 必须保持 root 属主不可写）。
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
