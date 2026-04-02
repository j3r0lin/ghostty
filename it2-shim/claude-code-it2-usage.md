# Claude Code 对 it2 CLI 的使用方式

> 基于 Claude Code v2.1.81 二进制逆向分析

## 概述

Claude Code 通过 `it2` CLI（iTerm2 的 Python 命令行工具）实现 **Agent Swarm 多 Agent 分屏**功能。所有调用都通过 `ITermBackend` 类（内部混淆名 `eRL`）发起，仅使用 `it2 session` 子命令组。

## 安装检测

Claude Code 启动时先检测 `it2` 是否可用：

```bash
which it2    # 检测是否已安装
```

若未安装，按以下优先级自动安装：

1. `uv tool install it2`
2. `pipx install it2`
3. `pip install --user it2`（失败则 `pip3 install --user it2`）

## 命令详解

### 1. `it2 session list`

```bash
it2 session list
```

**场景 A：安装验证**

验证 it2 能否正常与 iTerm2 通信。

| 输出 | 使用方式 |
|------|----------|
| exit code | `=== 0` → 验证通过 |
| stdout | **忽略** |
| stderr | 转小写后检查是否包含 `"api"` / `"python"` / `"connection refused"` / `"not enabled"` 任一关键词 → 是则判定 Python API 未启用 |

**场景 B：死会话检测**

当 `session split` 失败时，检查目标 session 是否还存在。

| 输出 | 使用方式 |
|------|----------|
| exit code | `=== 0` → 输出有效 |
| stdout | `stdout.includes(sessionId)` — 若不包含目标 ID，说明该 session 已死亡，从内存列表中移除后重试 split |
| stderr | 不使用 |

---

### 2. `it2 session split`

创建新的分屏 pane。有 4 种参数组合：

```bash
# 首个 teammate，已知 leader session ID
it2 session split -v -s <leaderSessionId>

# 首个 teammate，未知 leader session ID
it2 session split -v

# 后续 teammate，从上一个 teammate session 分屏
it2 session split -s <lastTeammateSessionId>

# 后续 teammate，无可用 session
it2 session split
```

**参数说明：**
- `-v`：垂直分屏（仅首个 teammate 使用，形成左右布局）
- `-s <sessionId>`：指定从哪个 session 分屏

**leaderSessionId 来源：**

```
process.env.ITERM_SESSION_ID → "w0t0p0:F9B3..."
                                        ↑ 取冒号后面的部分
```

| 输出 | 使用方式 |
|------|----------|
| exit code | `=== 0` → 创建成功 |
| **stdout** | **关键输出**。用正则 `/Created new pane:\s*(.+)/` 提取新 pane 的 session ID，`.trim()` 后存入内存数组 |
| stderr | split 失败时用于日志 |

**期望的 stdout 格式：**

```
Created new pane: <sessionId>
```

**提取到的 sessionId 用途：**
- 存入 `fg` 数组（teammate pane 列表）
- 作为后续 `run` / `close` / `focus` / 下一次 `split` 的 `-s` 参数

---

### 3. `it2 session run`

在指定 pane 中执行命令（启动 teammate Agent 进程）。

```bash
# 指定 pane 执行
it2 session run -s <sessionId> <command>

# 当前 pane 执行
it2 session run <command>
```

| 输出 | 使用方式 |
|------|----------|
| exit code | `=== 0` → 执行成功 |
| stdout | **忽略** |
| stderr | 失败时作为错误消息：`"Failed to send command to iTerm2 pane <id>: <stderr>"` |

---

### 4. `it2 session close`

强制关闭指定 pane。

```bash
it2 session close -f -s <sessionId>
```

- `-f`：强制关闭，不提示确认
- `-s <sessionId>`：要关闭的 pane

| 输出 | 使用方式 |
|------|----------|
| exit code | `=== 0` → 返回 `true`（关闭成功） |
| stdout | **忽略** |
| stderr | **忽略** |

**副作用：** 关闭后从 `fg` 数组移除该 sessionId；若数组清空，重置 `hasFirstTeammate` 标志。

---

### 5. `it2 session focus`

将焦点切换到指定 pane（在 Teams 对话框中使用）。

```bash
it2 session focus -s <sessionId>
```

| 输出 | 使用方式 |
|------|----------|
| exit code | **忽略** |
| stdout | **忽略** |
| stderr | **忽略** |

fire-and-forget 调用，不关心任何输出。

---

## 汇总

| 命令 | exit code | stdout | stderr |
|------|-----------|--------|--------|
| `session list` | 判断通信正常 | 场景 B：`includes(id)` 检查 session 存活 | 场景 A：关键词匹配判断 Python API 状态 |
| `session split` | 判断成功 | **用正则提取新 session ID** | 失败日志 |
| `session run` | 判断成功 | 忽略 | 失败错误消息 |
| `session close` | 判断成功 | 忽略 | 忽略 |
| `session focus` | 忽略 | 忽略 | 忽略 |

## 数据流

```
split stdout → 正则提取 sessionId → 存入 fg 数组
                                         ↓
                        run -s <id>  ← 启动 agent
                        close -f -s <id> ← 关闭 pane
                        focus -s <id> ← 切换焦点
                        split -s <id> ← 下一个 teammate 从此分屏
```
