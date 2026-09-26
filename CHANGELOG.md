# Changelog

## Unreleased (breaking: bare uninstall is now interactive)

- security: **卸载只作用于目标账户**。过去 `do_uninstall` 会遍历 manifest 里所有账户，
  于是共享主机上任意一户执行 `uninstall --purge` 就会结束其他所有户的租约、把他们的
  sudoers 打回基窗、删掉他们的 skill。现在默认只处理 `--user`；只要还有别的账户在用，
  共享的 payload / `sudo.conf` marker / 机器配置 / 备份 / ghost sweep 全部保留。
  整机下线用新增的 `--all-users` 显式声明。账户被移除后同步更新 manifest 的 `USERS`，
  否则机器永远清不干净。
- security: `se_user_slug` 改为**单射**。旧的 `tr -c 'A-Za-z0-9_-' _` 把 `a.b` 和 `a_b`
  都映射成 `a_b`，两个合法账户共用一份 sudoers drop-in 与一份租约——可以互相结束窗口、
  读取对方原因、覆盖对方时长（AD/Domuan 等带点用户名必然踩到）。现转义 `.` 与 `_`
  （`a.b` → `a__2e__b`），普通用户名不变，旧名残留文件在下次授权时自动清理。
- fix: `--config-file` 指向的配置文件**不存在时不再报错**。CLI 无条件传该路径，因此过去
  用户一删配置，`request` 就以 “config file not found” 全面失败；现在按默认值回落。
  文件存在但属主不可信时仍然拒绝。
- feat: **审计两级**。root 侧 `se_audit` 在写完机器日志后，用 `runuser` 以目标账户身份
  把**同一行**追加到 `~/.local/state/sudo-elevation/audit.log`（账户自有 0600）。
  由账户自己创建而非 chown 进家目录，写失败绝不影响授权；机器日志仍为 root 0600。
- feat: `sudo-elevation status` 暴露来源：`cli=`（本次生效的树）、`askpass=`、
  参与解析的 `config[层]=路径`、以及每个键的 `src_*`（`default` / `machine:` / `user:`）。
  解决“同一台机器装了系统通道和用户通道时，`$PATH` 决定谁应答却毫无提示”的盲区。
- fix: `status` 不再靠 `sudo -n grep` 读 0440 的 sudoers drop-in（无有效时间戳时必然失败，
  恰好在无租约时 `current_timeout` 为空）。改为读用户本就可读的租约文件 `minutes` 键。
- feat: `request` 加每账户互斥锁（`~/.cache/sudo-elevation/.request.lock`，基于 `mkdir`）。
  过去两个 agent 并发请求会互相覆盖 request 文件，弹窗描述的可能不是正在回答的那个请求。
  陈旧锁（> 弹窗超时 +120s，下限 300s+120s）自动接管，`DIALOG_TIMEOUT=0` 不会误抢。
- feat: 授权失败时给出可执行提示：本项目只写 `Defaults`、从不写命令规则与 `NOPASSWD`，
  因此 scoped-sudo 账户不可用属预期行为，并说明放宽权限时必须保持 `grant` 为 root 属主。
- tests: 新增 `20_lifecycle`（双账户独立卸载、共享 payload 保留到最后一人、
  `--all-users`、带点用户名不再共用文件）；`19_multiuser` 增补配置分层、status 去 sudo
  依赖与来源、并发锁、陈旧锁接管、删配置后仍可用、两级审计落位与属主。

- feat: **配置分层**——机器层 `/etc/sudo-elevation.conf` 与账户层
  `~/.config/sudo-elevation/config`，后者优先且**与用哪棵树无关**（系统通道的 CLI 同样
  遵守账户层）。优先级：命令行 flag > 账户层 > 机器层 > 内置默认。两侧路径都是既有路径，
  零迁移。root 侧 helper 按 `SUDO_USER` 解析账户层（非 root 侧直接用 `$HOME`，
  在 `--prefix` 沙箱下整个账户层停用以保持测试封闭）。
- fix: **重装不再清空配置**。`write_config` 过去无条件重写整个文件，把手改的
  `GUI_BACKEND`/`DIALOG_TIMEOUT`/`REQUEST_TTL`/`BASE_MINUTES`/`MAX_MINUTES` 全部打回
  flag 默认值。现在不传 `--base-timeout/--max-timeout` 时原样保留，显式传 flag 才覆盖
  对应键；新键仍会补全，文件保持自解释。README 里“改完重装生效”的说法是错的
  （该文件每次弹窗实时读取），已删除。
- fix: 基础窗口的解析提前到 `do_install` 第一句。此前 `BASE_MINUTES` 只在写配置文件时
  生效，sudoers drop-in / manifest / 摘要 / SKILL.md 用的仍可能是 flag 默认值，
  会出现“配置写 25m、sudoers 还是 15m”。现在解析结果贯穿所有消费点。
- fix: 账户层的值不会被写进机器文件（否则把一户偏好固化成全机策略），同时机器层自己的
  值也不会因为恰好有账户覆盖而被删掉——需要区分“本文件管理的键”和“别人的键”。
- fix: 手写配置现在会校验：超出硬上限（`MAX_MINUTES` 封顶一年，此前
  `se_valid_minutes` 拿 max 校验 max 等于没校验）、`BASE > MAX` 一律拒绝安装并报错，
  且拒绝时不留下半改写的配置。
- docs: README 新增「配置」章节（分层表、优先级、可配置键、重装不丢配置）。

- security: `grant`/`restore` 只作用于调用者自己——经 sudo 时 `--user` 必须等于
  `$SUDO_USER`，否则拒绝。修掉 `sudo .../grant --user <别人> --minutes <任意>`
  即可改写他人 sudo 窗口与租约的跨用户提权。root **直接**运行（不经 sudo，或
  root 自己 sudo）仍可指定其他账户，因为那条路径没有跨越权限边界。
- security: root 侧 helper 加载 `--config-file` 前校验属主——必须 root 拥有且非
  组/全局可写，或属于目标用户，否则拒绝。调用者不能再自选 `MAX_MINUTES`
  绕过机器策略。符号模式位判定（`stat -c %A`），不做八进制运算。
- security: **用户安装不再写全局 `Path askpass`**。该指令每台机器只有一个且对
  所有账户生效，`--user-install` 曾把全机 `sudo -A` 指向某个用户的 `~/.local`；
  `print_system_snippet` 甚至把它印成推荐做法。现改为 `sudo-elevation` 在调用
  `sudo -A` 前自行导出 `SUDO_ASKPASS` 指向本树（仅在调用方未设置时，纯兜底，
  不覆盖显式值），因此用户通道图形路径可用而裸 `sudo -A` 仍需系统通道。
  旧版留下的、指向目标用户家目录的 marker 块会被清理并备份；指向系统路径的
  块（属于系统安装）不动。
- security: `grant`/`restore`/`common.sh`/`$SE_SHARE` 在**所有**布局下保持
  `root:root`——删掉了 `chown -R "$SE_LIBEXEC"`。这两个 helper 经 sudo 以 root
  执行，交给目标用户就等于交出 root 代码注入点。CLI 只需可读可执行。
  旧安装残留的非 root 属主文件在下次安装时收回并告警。
- docs: README 新增「多用户 / 服务器」小节（边界、机器级 `MAX_MINUTES`、
  `timestamp_type=global` 的会话扩散、审计日志归属）；故障排查补 scoped-sudo
  不兼容（项目只写 `Defaults:`，从不写命令规则）与 `GUI_BACKEND` 改完**无需重装**
  （每次弹窗实时读取；租约有效时 sudo 不调 askpass，需先 `sudo -k`/`lock`）。
- tests: 新增 `19_multiuser`（跨用户 grant/restore 被拒、root 直跑仍可用、
  第三方/全局可写配置被拒、用户安装不劫持 askpass、旧块清理、libexec 属主、
  CLI 兜底 `SUDO_ASKPASS` 生效且不覆盖显式值）；host 增 `se_config_trusted`
  权限位真值表与 `se_assert_target_user` 边界单测；`16_user_install` 改为断言
  修复后的行为（不再出现 `Path askpass ~/.local/...`）。

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
- fix: 仅删自有（`3c8d0bf` 起）：安装剪枝只留最新自有 `bak.YYYYMMDDHHMMSS[.PID]`，
  管理员备份永留；purge 按内容认定（sudoers `Managed by` 头、lease `epoch+minutes/restore` 键、
  skill `sudo-elevation request` 标记、异形 `CONFIG/LOG` 与未闭合 marker 块保留并告警）。
- fix: 裸 `--no-system` 安装时自动采用目标用户 XDG 布局（root 进 root 家），卸载按 manifest
  清理；CLI 用户布局优先于残留 `SUDO_ELEVATION_PREFIX`。
- fix(tests): host 沙箱统一经 `se`/`se_user` 包装器剥离 `XDG_CONFIG_HOME/XDG_DATA_HOME/XDG_STATE_HOME`
  ——CI 上 `actions/checkout` 会导出 XDG 覆盖，导致 config/receipt 写到沙箱外
  （`FAIL: no-system config missing`）；新增 XDG 优先级真实覆盖（config/receipt/manifest 跟随
  `XDG_*`，CLI 免 export 自定位）。
- ci: Host/Docker 步骤失败时输出 `::error::` 注解 + 日志尾部 40 行，并在 run 页直接可见，
  无需下载 job logs（此前排查需拉 zip）。
- fix: 交互发现每棵树透传 `--user/--skill-dir`，回放命令可粘贴；`--keep/--purge` 互斥报错；
  缺值 flags 友好报错；`manifest`/`receipt` 补记 `SUDO_CONF/SUDOERS_DIR/RUNTIME_DIR/LOG`（漂移仅告警）；
  家目录属主链安装即修正（root 代建不再毒化后续 user 安装）；`run.sh` 超时后要求 `SCENARIO-DONE rc=0`。
- ci: `actions/checkout` 升 v5（消 Node 20 弃用告警；该运行时属于 action 自身，本项目仍是纯 shell）；
  `run.sh` 输出计时台账（每镜像 `---> BUILD (Ns)` + 结尾汇总场景数/场景耗时/build 耗时/墙钟/最慢 Top8），
  补上 step 视图给不出的那层：冷 build 原本藏在 `##########` 与首个场景之间的空隙里（实测占 job 约 13%），
  要人工按时间戳相减才看得见；同时去掉各 step 的 `::notice::` 耗时回显——Actions API 本就返回 step
  起止时间，重复输出只是噪音。
  **经实测后明确不做**的 CI 优化（防后人重复走弯路）：按 CI 实测 290s 拆分，80% 是 36 个场景实跑，
  其中 `12/03/13` 的固定 sleep 约占全 job 57%，主体是租约时长（物理时间，压不动）；sleep 边界可省的
  余量两镜像合计约 34s，但按 1s 轮询粒度与 18 个等待点折算，期望收益仅 ~16s（5.5%），换来慢机更易
  flaky，不划算；容器往返 0.24s/次、warm build 0s，Docker 缓存/并行无可省 IO（并行是更快而非更省）；
  `CYCLES` 不下调以免牺牲覆盖。`ubuntu-latest` 保持浮动，便于上游迁移（如 Ubuntu 26）时早暴露漂移——
  这是**验证策略**而非产品支持矩阵，产品只校验 `sudo >= 1.8.21`、与发行版无关。
- tests: `lib.sh` 新增 `wait_gone`（等路径消失，1s 间隔、与 `wait_for_contains` 对称），
  收掉 `15_extra` 里手写的同款轮询循环——纯去重，不改变耗时。

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
