# it2-shim

Ghostty 的 iTerm2 `it2` CLI 兼容层，让 Claude Code 的 Agent Swarm 多分屏功能在 Ghostty 终端中正常工作。

## 架构

```
┌─────────────┐    ┌──────────┐    ┌─────────────────────────┐
│ Claude Code │───▶│  it2     │───▶│  Ghostty AppleScript API │
│             │    │  (shim)  │    │  (it2-shim 分支定制)      │
└─────────────┘    └──────────┘    └─────────────────────────┘
```

所有操作通过 Ghostty 原生 AppleScript API 完成，无需 dylib 注入或签名修改。

## it2-shim 分支的 Ghostty 定制

本 shim 依赖 `it2-shim` 分支对 Ghostty 的四处修改：

1. **`macos/Ghostty.sdef`** — 添加 `frame` record-type、terminal `frame` 属性和 `content` 属性
2. **`macos/Sources/Features/AppleScript/ScriptTerminal.swift`** — 实现 `frame` 和 `content` getter
3. **`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`** — 注入 `ITERM_SESSION_ID` 环境变量

## 构建与安装

```bash
# 构建（在仓库根目录）
git checkout it2-shim
zig build -Dxcframework-target=native -Doptimize=ReleaseFast
cp -R zig-out/Ghostty.app /Applications/Ghostty.app

# 安装 it2 shim
ln -sf "$(git rev-parse --show-toplevel)/it2-shim/it2" ~/.local/bin/it2
```

## 更新 Ghostty

```bash
git fetch origin
git checkout it2-shim
git rebase origin/main
zig build -Dxcframework-target=native -Doptimize=ReleaseFast
cp -R zig-out/Ghostty.app /Applications/Ghostty.app
```

## 命令一览

| 命令 | 说明 |
|------|------|
| `it2 session list [--json]` | 列出所有终端 session ID |
| `it2 session tabs` | 列出当前窗口所有 tab |
| `it2 session layout [-t N]` | 显示 tab 的分屏布局图 |
| `it2 session split [-v] [-s ID]` | 分屏 |
| `it2 session run -s ID <cmd>` | 在指定终端执行命令 |
| `it2 session send -s ID <text>` | 发送文本到终端 |
| `it2 session focus -s ID` | 聚焦终端 |
| `it2 session close -s ID` | 关闭终端 |
| `it2 session read [-s ID] [-n N]` | 读取终端屏幕内容 |
| `it2 session capture -o FILE` | 捕获屏幕内容到文件 |
| `it2 session set-name -s ID <name>` | 设置终端名称 |
| `it2 session clear [-s ID]` | 清屏 |

## 文件说明

| 文件 | 说明 |
|------|------|
| `it2` | Python CLI shim，映射 it2 命令到 Ghostty AppleScript |
| `claude-code-it2-usage.md` | Claude Code 对 it2 CLI 的调用方式分析 |
| `ghostty-applescript.md` | Ghostty AppleScript API 参考 |
