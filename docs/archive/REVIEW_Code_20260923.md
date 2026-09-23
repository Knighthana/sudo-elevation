# Code Review（代码评审）— sudo-elevation 0.1.3

日期：2026-09-23 ｜ 范围：`install.sh`、`bin/sudo-elevation`、`bin/sudo-askpass`、`libexec/.../common.sh|grant|restore`、`templates/SKILL.md.in`、测试与 CI ｜ 结论：**高质量 shell 工程，P0 无；P1 两项（D1/D2 的代码侧 + 下述 C1），P2 若干**
验证：`bash -n` 全过；`shellcheck -S warning`（CI 同参数）0 告警；host 通过；Docker 28/28；补充单元 70/70；补充集成 29×2；确证实验 C1-C4。

> 只评估、不改代码。行号为当前 `master`（`ac96751`）。

## 0. 总体评价

* 贯穿的好习惯：`set -euo pipefail`、小函数、`se_read_kv` 无 eval 解析外部文件、`se_valid_user` 白名单 + `se_user_slug` 文件名化、`visudo -cf` 后原子安装、敏感文件 `0600/0440`、目录 `0755 root` 防 symlink 替换（已实测 runtime 755 root / lease 600 tester）。
* root 读用户可控文件（choice/request）是**设计使然**，但读后均经 `se_valid_minutes` 数字校验 + `se_sanitize_reason` 截断消毒，无 eval/命令拼接，fail-closed。
* 本次实测未发现：密码落盘、sudoers 注入、提权绕过、缓存泄露（04/12/13 均验证无泄漏）。

## 1. P1-C1：`lock` 无 timestamp 时 until-lock 残留（与 D1 同根，代码侧）

* 位置：`bin/sudo-elevation:155-165`（`lock` 用 `sudo -n restore --force`，失败即 fallback，不再尝试）。
* 实证：until-lock 生效后 `sudo -k` → sudoers 仍 `-1`、lease 仍在 → `lock` 走 fallback → sudoers **继续 `-1`**（容器确证）。
* 为什么 P1：限时租约有定时恢复兜底，影响窗口有限；`-1` 无定时任务，残留是无限期配置，下次密码认证即无限免密。
* 整改选项（待你选，不在本报告实施）：
  * C1-A（最小）：`lock` 检测到 lease `minutes=-1` 且 `sudo -n restore` 失败时，以非零退出 + 明确报错“until-lock 配置仍在，需在 tty 执行 `sudo restore --force`”，不打印“仍会保护”；
  * C1-B（体验）：`lock` 先 `sudo -n` 试，失败则回退到 `sudo restore`（允许输密码），headless 才报错；
  * C1-C（文档）：至少按 D2 区分文案。推荐 A 起步，B 按需。

## 2. P2 代码问题（按文件）

### `install.sh`

* **P2-I1 uninstall `--dry-run` 非纯 dry-run**（已实证 C2）：`do_uninstall` 中 `rm -f "$SE_SUDO_CONF".bak.*`（:363）、`rmdir "$SE_LIBEXEC"/"$SE_SHARE"/"$SE_RUNTIME_DIR"`（:359,361,364）及 skill `rmdir` 未包 `run`，dry-run 仍删除备份与空目录（本次确证 bak 被删，二进制因 `run` 包裹得以保留）。建议：全部包 `run` 或 dry-run 提前 return；host 测试建议加“uninstall dry-run 不碰沙箱”断言。
* **P2-I2 备份剪枝 `xargs` 分词**（:169）：`ls -1t … | tail | xargs -r rm -f --` 对含空格/换行文件名不安全。现实备份名时间戳无空格，风险极低；建议换 `find … -printf` 或循环删除，或加注释说明命名受控。
* **P2-I3 SKILL `sed` 替换脆弱**（:202-203）：`s/@@BASE_HUMAN@@/$base_human/` 若未来人文案含 `&`/`/` 会坏。现文案仅数字+`分钟/小时/天/秒`，安全；建议换 `|` 分隔或先转义，并注释约束。
* **P2-I4 同秒重装备份同名覆盖**（:167）：`bak.$(date +%Y%m%d%H%M%S)` 秒级，1s 内两次安装后一次覆盖前一次。仍只剩 1 份、语义可接受；建议注释或加 `$$` 后缀。
* 多用户 manifest 追加（:175-187）与卸载循环 `se_valid_user` 跳过非法（:313）正确，本次 X09 验证双用户 sudoers + manifest 共存 ✅。

### `libexec/sudo-elevation/common.sh`

* **P2-C2 配置数字校验偏松**（:51）：`*[!0-9.]*` 放行 `15.5.5`/`.`，后靠 `awk m+0` 截断解析（本次确证 `BASE=15.5.5` 被接受）。无提权（仍数字），但建议正则收紧为 `^[0-9]+(\.[0-9]+)?$`，非法即忽略并告警。
* **P2-C3 极小秒值科学计数法**（:81-105）：`se_parse_minutes` 对 `0.0000001s` 经 `%.10g` 得 `1.66667e-09`，`se_valid_minutes` 因含 `e/-/＋` 拒收。行为 fail-closed，可接受；建议注释或对 `<0.01` 直接按 0 处理并文档化。
* **P2-C4 `se_human_minutes` 损坏 lease 兜底**（:107-117）：`minutes="?"` 经 awk 得 0 → “0 秒”，不崩但易误解。建议显式 `?`/`空` 显示“未知”，`status`（`bin/sudo-elevation:123`）透传前先校验。
* `se_user_slug`（:165）把 `.` 也转 `_`（`tr -c 'A-Za-z0-9_-'`）：`first.last`→`first_last`，无碰撞风险（同目录唯一），但建议注释说明“点号亦转义”，避免运维按用户名找文件困惑。
* `se_apply_gui_backend`（:64-75）、`se_schedule_restore`（:228-249 systemd 检测 `is-system-running` + `setsid` 回退 + `failed` 明示）正确；`se_write_lease` 先建目录 0755 再文件 0600+chown（:196-208）配合目录非写防替换，好评。

### `bin/sudo-elevation`

* `request`（:40-89）：`--for` 必填、`se_valid_minutes` 上限、`requester` 取 PPID comm、`cache 0700`/`req 0600`、`trap EXIT` 清理、`sudo -n true` 判缓存 → `-k -A`/`-A` 双分支（0.1.3 取消保缓存 fix）正确，本次 X08 在容器复验“取消后 `sudo -n` 仍可用且无 lease” ✅。
* `grant`（:91-113）：tty 判 `sudo` vs `sudo -A` 合理；`status`（:114-153）`epoch%%-*` 取前导时间戳（0.1.2 fix）+ `sudo -n grep` 读窗口不触发密码，正确，本次 X04 三态 ✅。
* `uninstall`（:167-188）：`purge=()` + `${purge[@]+…}` 避 `set -u` 空数组，正确；本次 X10 验证“默认保留审计、`--purge` 才删” ✅。

### `libexec/sudo-elevation/grant`、`restore`

* `grant`（:41-56）：root 校验、用户存在校验、choice/request 双源、`se_valid_minutes` 服务端二次校验、`visudo` 原子安装、`epoch=now-$$-RANDOM` 唯一、`restore` 调度失败明示（:104-106），正确。`TMPDIR` 经 sudo 默认 env_reset，`mktemp` 0600 + trap，风险低。
* `restore`（:29-62）：epoch 守卫 + `--force` 旁路、`restore-skip` 审计、失败 `exit 4`、成功清缓存+删 lease，正确；10/13 场景验证 ✅。`restore` 未重复 `id user` 存在校验但 `runuser … || true` 容错，可接受。
* 建议（P2）：`grant --reason` 超长经 `se_sanitize_reason` 200 截断（本次 X02 ✅），建议在 grant 成功回显中若被截断加“（已截断）”提示，避免用户误以为全量记录。

### `bin/sudo-askpass`

* `exec 3>&1; exec 1>/dev/null` 密码独占 fd3 好评；`REQUEST_TTL` 过期按 `fresh=0` 走简单密码窗（本次 X07 ✅）；`write_choice 0600`/`reset_choice` 防复用；zenity/kdialog 两步 radio（:116-226）预选 agent 请求值、手动输入二次 `se_parse_minutes`+上限校验，fail-closed。
* 生产剥离 test hooks（`install.sh:241-244` + 场景 01 断言）与本次 X06 “`UI=fake` 在生产 fail-closed” ✅，杜绝测试后门进生产。
* 建议（P2）：`ui=none` 报错“没有可用的图形界面…”（:111）建议附带 `grant` 示例一行（README 有，此处没有），headless 用户少翻一次文档。

## 3. 安全专项（结论：未发现可利用提权）

* sudoers 注入：`se_render_sudoers`（`common.sh:178-186`）仅写入 `user`（白名单）+ `minutes`（数字/-1），`visudo -cf`  gate，已用 over-MAX/abc/注入字符验证拒绝 ✅。
* 口令面：全程经 sudo/askpass，无 `sudo -S`/`echo|sudo`/`expect`，`SKILL.md.in:37-40` 禁止事项与实现一致；`grep` 未见 `SUDO_ELEVATION_FAKE_PASSWORD` 进生产 ✅。
* 文件面：见权限实测；`/run` 目录 root 755 防用户替换 lease 为 symlink 后 root 截断 ✅；`choice/request` 在用户 `~/.cache 0700`，root 读后严格校验 ✅。
* 残留面：除 P1-C1 的 `-1` 残留外，限时租约到期/取消/lock/卸载均无缓存或配置残留（03/04/05/06/12/13 + X03/X08/X10）。

## 4. 测试与 CI

* CI（`.github/workflows/ci.yml`）：shellcheck + host + Docker 双镜像，`timeout 30m`，与本次本地复跑一致，好评。
* 现有 14 场景分工清晰，命名与断言可读（`lib.sh` 的 assert_* + `SCENARIO-DONE` 抗 docker CLI 挂起）。
* 本次补充未进仓库（在 `/tmp/opencode/review/`，仓库 `git status` 干净）：`extra_unit.sh`（解析/校验/人文/版本/slug/消毒/kv/配置/后端）、`extra_docker.sh`（X01-X11）、`extra_confirm.sh`（C1-C4）。若你决定固化，建议挑 X01/X02/X04/X06/X08/C1/C2 迁入 `scenarios/15_*.sh` + host 断言（工作量小，价值高）。

## 5. 整改优先级（待你拍板）

* P1：C1（lock `-1` 残留，代码+文档联动，见 D1/D2）。
* P2：I1（uninstall dry-run）、C2（配置数字正则）、I3（SKILL sed 分隔）、askpass 无 GUI 报错附 grant 示例、grant 截断提示、`status --porcelain`（需求侧已列）。
* 均不阻塞当前个人工作站/WSL 使用；P1 建议在下个补丁版本处理，P2 按需排期。
