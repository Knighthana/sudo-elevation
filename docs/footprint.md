# 落盘足迹（footprint）

这个项目会往机器上写东西。写在哪，是**故障排查成本**的主要来源：足迹越散，
出问题时越难判断"哪些是我留下的、哪些不是我留下的"。所以下面这条原则约束所有
新增的落盘位置。

## 原则

**新增的落盘位置必须在自有目录内。**

- 自有目录 = 项目自己建的、只有项目往里写的目录。
- `/etc` 只允许两类东西：**sudo 强制要求的集成点**（`/etc/sudoers.d/90-sudo-elevation-*`）
  和**单个具名文件**。不得新增散落文件、不得新增无固定命名的残留。
- 每个落盘位置要么自带可识别的标记（`Managed by sudo-elevation`），
  要么落在自有目录里让"属主即归属"成立。两者都不满足的新增位置要先改设计。
- 卸载必须能把它删干净。删不干净又不能自证归属的，宁可留下并明确报出来，
  也不要在删除判定里做模糊匹配（见 `se_safe_rm_skill` 的注释）。

## 一条 grep 列出系统目录里我们的全部足迹

```sh
sudo grep -rl 'Managed by sudo-elevation' /etc /usr/local
```

sudoers 备份、skill、以及任何未来带同一标记的文件都会命中。`/etc/sudo.conf`
里我们插入的块用的是 `# >>> sudo-elevation >>>`，单独查：

```sh
sudo grep -n '>>> sudo-elevation' /etc/sudo.conf
sudo ls -1 /etc/sudo.conf.bak.*        # 我们自己的备份（se_own_backup 认形状）
```

## 基线

**自有目录内**（符合原则）

| 路径 | 内容 |
|---|---|
| `/usr/local/libexec/sudo-elevation/` | `grant`、`restore`、`common.sh`、`install.sh` |
| `/usr/local/share/sudo-elevation/` | `VERSION`、`LICENSE`、`manifest` |
| `/run/sudo-elevation/` | 租约（tmpfs，重启即失） |
| `~/.config/sudo-elevation/` | 账户层配置 + 安装 receipt |
| `~/.config/opencode/skill/sudo-elevation/` | 渲染出的 `SKILL.md` |
| `~/.local/state/sudo-elevation/` | 账户级审计日志 |
| `~/.cache/sudo-elevation/` | `request` 互斥锁 |
| `~/.local/share/sudo-elevation/` | 用户通道 manifest |

**自有目录外**

| 路径 | 性质 | 与原则 |
|---|---|---|
| `/etc/sudoers.d/90-sudo-elevation-<slug>` | sudo 必经集成点，每账户一个 | 符合（sudo 要求） |
| `/usr/local/bin/{sudo-elevation,sudo-askpass}` | 两个具名文件，PATH 需要 | 符合（单个具名） |
| `/var/log/sudo-elevation.log` | 单个具名文件 | 符合（单个具名） |
| `/etc/sudo-elevation.conf` | 散落文件，不在自有目录里 | 弱冲突：可迁到 `/etc/sudo-elevation/config` |
| `/etc/sudo.conf` | 外科式改写他人文件，插入 `# >>> sudo-elevation >>>` 块 | **冲突**，见下 |
| `/etc/sudo.conf.bak.<时间戳>.<pid>` | 在 `/etc` 里散落备份 | **冲突**，见下 |

## 已知冲突（已接受，待独立工作）

这两项**故意没在别的手上顺手改**，因为都会让那一笔提交无法审：

1. **`/etc/sudo.conf`** —— 机器上管全局 sudo 的文件，我们往里插一段自己的块。
   那段块的边界只有我们自己的 `strip_block` 认得。已有 fail-closed 保护
   （块未闭合时 purge 拒绝执行，`17_preserve` 覆盖），但"万一"落在这里：
   文件里混着我们的一段，而识别它需要运行我们的代码。
   可能的收敛方向：系统通道也不写它——用户通道已经不写了（`Path askpass` 由 CLI
   兜底），系统通道保留它是为了给全机 `sudo -A`。取消它等于取消这个能力，
   属功能取舍，要单独讨论。

2. **`/etc/sudo.conf.bak.*`** —— 每次改 sudoers 就往 `/etc` 丢一个备份。有轮转
   （`install.sh` 的 `.bak.*` 循环 + `se_own_backup` 只认自己的严格命名形状），
   purge 也按 manifest 精确删除。但正是"万一"的场景：一旦 manifest 对不上或
   有人手动动过，`/etc` 里就留下几个看不出归属的 `.bak`。
   可能的收敛方向：备份放进自有目录（但备份的是 `/etc/sudo.conf`，得让
   卸载记得去那个目录取），或干脆不备份、改用"块可重入"的写法。

## 相关

- `tools/README.md` —— 仓库专用的维护工具，不进安装树
- `install.sh` 的 `se_safe_rm_skill` / `se_own_backup` —— 两个归属判定的注释
  记录了为什么用标记而不是内容匹配
