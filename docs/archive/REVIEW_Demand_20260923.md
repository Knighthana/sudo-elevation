# Demand Review（需求评审）— sudo-elevation 0.1.3

日期：2026-09-23（UTC+8）｜ 模式：无人值守 ｜ 结论：**需求成立、边界清晰，P0 无，P1 两项需 doc-fix，P2 多项体验/可观测性建议**
测试基线：`shellcheck -S warning` 通过；`tests/run-host.sh` 通过；Docker 矩阵 `ubuntu:24.04 + debian:12 × 14 场景 = 28/28 通过`；补充单元 70/70；补充 Docker 29×2 通过；确证实验 3 项（见 Code 报告）。

> 本报告只评估、不改代码。所有整改建议待你回來决定是否做、如何做。

## 1. 需求一句话

让 coding agent 在**不存密码、不配 NOPASSWD** 前提下用 sudo：agent 申请时间租约 → 人在图形弹窗选时长并输一次密码 → 窗口内 `sudo -n` 免确认 → 到期 sudo 原生强制失效（`timestamp_timeout` + epoch 守卫恢复任务）。

该模型在 README:3-6、36-40、SKILL 模板中表述一致，CHANGELOG 0.1.0-0.1.3 演进可追溯，未发现需求漂移。

## 2. 需求成立性：通过

* 痛点真实：agent 长任务（安装/构建/重启服务）逐条输密码不可行；`NOPASSWD` 过宽；存密码（keyring/加密文件）引入新秘密管理负担。
* 方案取舍明确：用 sudo 自身 `timestamp_timeout` 做强制到期（README:36-40），不自建 daemon 鉴权，不解析/代理命令，攻击面小。
* 竞品对比表（README:27-34）经抽查无虚假陈述：sudoplz（每条弹窗+存盘）、harness-root-hook（固定2h+keyring）、sido-askpass（每条弹窗）、opencode-sudo-popup（每条弹窗+gjs/GTK4）——“租约+不存密码+免逐条弹窗”差异点成立。
* 安全责任前置：README:100-115 明确“批准的是时间窗口”“reason 可伪造”“个人工作站/不适合共享或生产”，并引用 sudo 三准则，诚实而非夸大。

## 3. 范围与一致性：通过，附 2 个 P1 doc-fix

| 检查项 | 结果 |
|---|---|
| 功能范围 request/grant/status/lock/uninstall/parse、时长格式、仅本次/until-lock | README:67-98 与 `bin/sudo-elevation` usage、`templates/SKILL.md.in` 一致 |
| 基础窗口 15m、MAX 365d、dry-run/--force/--purge | `install.sh` 默认与 README:50-59 一致 |
| 审计、卸载还原、无 GUI 转 grant | README:97-98,143-153 与实现一致，Docker 06/07/08/11 已覆盖 |
| 真机手测声明 | README:135-141 用 ✅/⏳ 区分已测/待测（WSLg 通过；kdialog 真机/systemd-run/wayland 待测），诚实 |
| SKILL 时长估算（在场短、无人值守宁长勿短） | 与无人值守痛点匹配，本次即按此申请 4h |

### P1-D1：`sudo -k`/重启的撤销语义夸大（已实证）

* 现状：README:115 写“撤销：`sudo-elevation lock`、`sudo -k`、重启”。
* 实证（容器内确证 C1）：`until-lock` 租约（`timestamp_timeout=-1`）下执行 `sudo -k` 后，sudoers 仍为 `-1`、lease 文件仍在；此时 `sudo-elevation lock` 因内部 `sudo -n restore` 无有效 timestamp 而走 fallback 分支，**sudoers 继续残留 `-1`**。
* 影响：用户以为已撤销，实则下一次任意密码认证（`sudo -v`）会直接获得**无限期**免密（`-1` 永不过期），无需再次审批。对限时租约影响小（有定时恢复兜底），对 `until-lock` 是真实残留风险。
* 建议（仅 doc-fix，二选一，待你定）：
  * A. 文档改为“完全撤销必须 `lock`；`sudo -k` 仅清本次缓存（until-lock 配置仍在，需补一次 `lock`）”，并在 `lock` fallback 提示中对 `-1` 特别告警；或
  * B. `lock` 在 `-n` 失败时尝试一次需密码的 `sudo restore`（交互式兜底），headless 则明确报错而非“仍会保护”。

### P1-D2：`lock` fallback 文案对 `-1` 误导

* 现状：`bin/sudo-elevation:164` fallback 提示“配置将在下次授权/安装时恢复（sudo 超时仍会保护）”。
* 问题：`-1` 没有超时保护，上述文案在 until-lock 失败路径下不成立。
* 建议：按 lease 类型区分文案（限时租约可保留原句；`-1` 必须提示“配置仍为直到手动 lock，下次输密码即无限，需尽快在有 tty 时补 `lock`”）。

## 4. 非功能需求

* 到期强制性：三层（sudo 自身超时 + 定时 restore + lease 结束清缓存 README:95）设计合理；Docker 03/12/13 已验证到期拒绝与恢复。
* 最小权限与还原：sudoers `0440`+`visudo -c`、lease `0600` 属主用户、审计 `0600`、卸载 manifest 全量清理（含备份与 `/run`），本次实测权限位全对（runtime 755 root / lease 600 tester / sudoers 440 / audit 600 root / conf 644）。
* 降级路径：无 GUI 快速失败转 `grant`（README:98,161-164；场景 11 通过）；zenity/kdialog 缺失安装警告继续（`install.sh:228-231`），headless 可用，合理。
* 可用性细节：弹窗两步（时长 radio 同窗 + 密码回车提交）、WSL 强制 `GDK_BACKEND=x11` 可被 `GUI_BACKEND` 覆盖（README:158-161），与 WSLg 缺陷说明匹配。

## 5. P2 需求建议（不影响本次放行，按需排期）

1. **机器可读 status**：当前 `status` 为中文人读文本（`bin/sudo-elevation:114-153`），agent 解析“剩余/已到期”脆弱。建议加 `status --porcelain`（如 `active=1 minutes=120 remaining_s=… epoch=…`），人不强求改现有文案。
2. **request 阻塞语义文档化**：`DIALOG_TIMEOUT=300`（`common.sh:31`）意味着无人值守无响应时 agent 卡 5 分钟才失败。SKILL/故障排查建议注明“无人值守务必估足时长；用户若 5 分钟不响应本次申请作废，需重申”。
3. **审计止于租约**：审计日志只记 grant/restore（`common.sh:210-217`），不记窗口内实际 sudo 命令。个人工作站可接受；若未来要溯源，建议文档明确“窗口内命令不在本项目审计范围，如需请配 sudo log_input/output”，避免误解。
4. **strict base=0 的 SKILL 文案**：`--base-timeout 0`（`install.sh` 允许）时 SKILL 渲染为“0 秒”，简单弹窗标题“窗口 0 秒”略怪但准确。可考虑 0 值特判为“每次都需密码（严格模式）”。
5. **MAX 默认 365d 的风险提示**：技术上允许 single approval 长达一年，文档已有“个人工作站”限定，建议在 `--max-timeout` help/文档加一句“若非长期构建机，建议设小（如 12h/7d）”。
6. **卸载 headless 鸡蛋问题**：无 timestamp、无 GUI、无 tty 时 `sudo-elevation uninstall`（经 `sudo -A`）必然失败，需终端 `sudo` 密码。现状可接受，建议故障排查加一行说明即可。

## 6. 需求覆盖率映射（抽查）

* 安装/幂等/权限 → 场景 01 + host 沙箱 ✅
* 认证对错密码 → 02 ✅；租约到期/恢复 → 03/12 ✅；仅本次 → 04 ✅；until-lock+lock → 05 ✅
* 卸载/冲突/headless/UI 参数/epoch/无 GUI/循环/重叠/kdialog → 06/07/08/09/10/11/12/13/14 ✅
* 本次补充：非法时长、reason 消毒、lock 空租约、status 三态、缩进外来 askpass、生产 fail-closed、TTL 过期、取消保缓存、多用户、purge、外来 SKILL 守卫 → 29×2 ✅
* 缺口（诚实声明）：kdialog 真弹窗、systemd-run 分支、`GDK_BACKEND=wayland` 真机仍待手测，与 README ⏳ 一致。
