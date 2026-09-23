# 评审总结 — sudo-elevation 0.1.3（无人值守 Demand + Code Review）

日期：2026-09-23 ｜ 租约：4h（`sudo-elevation request --for 4h` 已批准，报告时剩余约 3.7h）｜ 仓库：`master ac96751`，评审全程**未改原代码**（`git status` 干净），新增测试仅在 `/tmp/opencode/review/`，报告三文件为本次唯一落盘。

报告：`REVIEW_Demand_20260923.md`（需求）｜ `REVIEW_Code_20260923.md`（代码）｜ 本文件（总结与行动清单）

## 1. 一句话结论

**项目高质量、可继续用；无 P0；P1 两项（同一根因：until-lock + `sudo -k`/无 timestamp 时 `lock` 残留 `-1`，需文档+代码联动）；P2 若干体验/校验收紧。Docker 全量与补充测试全部通过。**

## 2. 实测结果

| 项 | 结果 |
|---|---|
| `bash -n`（6 脚本） | 通过 |
| `shellcheck -S warning`（CI 同参数，含测试） | 0 告警通过（本地 apt 装 0.9.0 复跑） |
| `tests/run-host.sh` | 通过（10 组） |
| Docker 矩阵 `tests/docker/run.sh`（ubuntu:24.04 + debian:12 × 14 场景） | **28/28 通过**（03/12/13 涉时场景约 29s+41s+17s） |
| 补充单元 `/tmp/opencode/review/extra_unit.sh` | **70/70**（解析/校验/人文/版本/slug/消毒/kv/配置/后端；初跑 2 个系测试期望笔误，已修正并重过） |
| 补充集成 `/tmp/opencode/review/extra_docker.sh`（X01-X11） | **29×2 通过**（非法时长、reason 消毒、空 lock、status 三态、缩进外来 askpass、生产 fail-closed、TTL 过期、取消保缓存、多用户、purge、外来 SKILL） |
| 确证实验 `/tmp/opencode/review/extra_confirm.sh` | C1 确证（`-1` 残留）、C2 确证（uninstall dry-run 删 bak）、C3 权限实测、C4 确证（`15.5.5` 被接受） |
| 权限位实测 | runtime 755 root / lease 600 tester / sudoers 440 / audit 600 root / conf 644，符合预期 |
| 真机缺口 | 与 README ⏳ 一致：kdialog 真弹窗、systemd-run、wayland 未在本机验证（本机 WSL init 走 setsid，已覆盖） |

Docker 守护进程系本次用已批租约 `sudo -n service docker start` 拉起，用户在 docker 组，`docker ps` 正常。

## 3. 行动清单（待你决定）

### P1（建议下个补丁做）

1. **until-lock 撤销语义**：README“撤销：lock/`sudo -k`/重启”改为“完全撤销必须 `lock`；`sudo -k` 仅清缓存，`-1` 配置仍在”。`lock` fallback 对 `-1` 单独告警；代码侧 `lock` 在 `-n` 失败且 lease 为 `-1` 时非零退出并指引 tty 重试（详见 Demand D1/D2、Code C1）。
2. 同上联动：`sudo -k` 后 lease 文件仍在是否应一起清？目前 `sudo -k` 不碰 lease（合理，lease 是配置），但文档需讲清“缓存 vs 配置”两层。

### P2（按需排期）

* uninstall `--dry-run` 包全 `run`（I1）+ host 加断言。
* `se_load_config` 数字正则收紧（C2）；SKILL `sed` 换分隔符（I3）；备份剪枝 `xargs` 改循环（I2）；同秒备份同名注释（I4）。
* `status --porcelain` 机器可读；`DIALOG_TIMEOUT` 阻塞语义进 SKILL；审计范围声明；strict base 文案；MAX 默认风险提示；askpass 无 GUI 报错附 grant 示例；grant 截断提示。

### 测试固化（可选，小成本高价值）

若认可补充测试，建议将 X01/X02/X04/X06/X08/C1/C2 迁入 `tests/docker/scenarios/15_extra.sh` + host 相关断言；本次 `/tmp` 脚本可直接作为初稿。

## 4. 使用建议（当前版本）

* 个人 WSL/桌面继续用无妨；`until-lock` 慎用，用后务必 `sudo-elevation lock` 确认 `status` 回到“无活动租约”再离开；无人值守任务按 SKILL “宁长勿短”估足。
* 生产/共享主机仍不适用（文档已有声明，本次认可）。

## 5. 文件清单

* 本次落盘（仓库新文件，未改旧文件）：`REVIEW_Demand_20260923.md`、`REVIEW_Code_20260923.md`、`REVIEW_Summary_20260923.md`。
* 本次测试（未进仓库，`git status` 干净）：`/tmp/opencode/review/extra_unit.sh`、`extra_docker.sh`、`extra_docker_run.sh`、`extra_confirm.sh`。
* 环境变更（非项目代码）：apt 装 `shellcheck`、`service docker start`。
