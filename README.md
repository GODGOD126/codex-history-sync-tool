# Codex History Sync Tool

一个用于恢复 Codex Desktop 本地历史对话显示的小工具。

当你切换 API、provider、模型或登录方式之后，Codex Desktop 有时会出现“本地历史明明还在，但侧边栏看不到”的情况。这个工具会检查本机的本地历史数据库、会话文件和侧边栏索引，并把旧线程重新挂到当前正在使用的 `model_provider` / `model` 下面。

## 这个工具能做什么

- 查看当前本机 Codex 历史线程属于哪些 provider
- 查看当前本机 Codex 历史线程属于哪些 model
- 一键把旧 provider / model 下的线程、会话元数据和侧边栏索引同步到当前设置
- Codex Desktop 正在运行时也可以同步；如果本地数据库正在写入，工具会等待空闲后继续
- 在同步前自动备份数据库、侧边栏索引和会话元数据
- 从备份恢复数据库
- 提供可直接点击的 Windows 和 macOS 图形界面

## 适用场景

- 你切换了不同 API
- 你切换了不同 provider
- 你切换了不同模型
- 你切换了登录方式
- 你确认本地历史文件还在，但 Codex Desktop 左侧历史列表变空了

## 不适用的场景

- 云端账号之间的聊天记录互相同步
- 本地历史文件已经被删除
- 不同电脑之间迁移聊天记录

## macOS 快速使用

1. 首次在访达中双击 `启动历史同步工具.command`，它会生成并打开 `Codex 历史同步工具.app`
2. 后续可以直接双击 `Codex 历史同步工具.app`
3. 首次打开如果被系统拦截，请在文件上右键选择“打开”
4. 检查界面显示的当前 provider、model 和待整理数量后，点击“同步到当前配置”

也可以在终端运行：

```bash
./启动历史同步工具.command
```

macOS 版使用系统原生 AppKit 界面，无需安装第三方 Python 依赖。首次启动需要 Apple
Command Line Tools 提供的 Swift 编译器；如果尚未安装，可先运行 `xcode-select --install`。
Intel Mac 最低支持 macOS 10.15，Apple Silicon 最低支持 macOS 11。工具会自动识别
`~/.codex/state_5.sqlite` 与 `~/.codex/sqlite/state_5.sqlite` 中较新的活动数据库，
并同时处理 `sessions` 和 `archived_sessions` 下的会话文件。

## Windows 运行环境

- Windows
- PowerShell 5.1 或更高版本
- 已安装 Python 3.10 或更高版本，并可通过 `py -3` 调用
- 本机存在 Codex Desktop 本地数据目录，通常是 `%USERPROFILE%\\.codex`

## 快速使用

### 图形界面

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launch_ui.ps1
```

### 创建桌面快捷方式

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launch_ui.ps1 -InstallShortcutOnly
```

### 查看当前状态

```powershell
py -3 .\sync_backend.py --json status
```

### 执行同步

```powershell
py -3 .\sync_backend.py --json sync
```

### 手动创建备份

```powershell
py -3 .\sync_backend.py --json backup
```

### 从最新备份恢复

```powershell
py -3 .\sync_backend.py --json restore
```

### 运行测试

```powershell
py -3 -m unittest discover -s tests -v
```

## 备份说明

- 每次同步前都会自动创建一份备份
- 每次恢复前也会先创建一份安全备份
- 备份默认保存在 `%USERPROFILE%\\.codex\\history_sync_backups`
- 新版备份会同时保存 `session_index.jsonl` 和会话文件首行元数据，恢复时会一起还原

## 使用建议

- Codex Desktop 开着也可以同步；如果它正在生成回复或保存历史，工具可能会等待几秒
- 恢复备份会覆盖当前状态，最稳妥的做法仍然是在恢复前暂停正在运行的 Codex 任务
- 如果同步完成后历史列表没有立刻刷新，重开一次 Codex Desktop 即可
- 新版 Codex 可能还会按当前项目目录显示历史。如果同步后仍然看不到旧对话，先确认是否打开了旧对话原来的项目目录；本工具默认不会批量改写线程的 `cwd` 项目归属。

## 项目文件

- `sync_backend.py`：后端同步、备份、恢复逻辑
- `launch_ui.ps1`：Windows 图形界面
- `launch_ui_macos.swift`：macOS 原生图形界面
- `启动历史同步工具.command`：macOS 双击启动入口

## 免责声明

这个工具直接操作本机 Codex 的本地状态数据库。虽然已经做了自动备份，但仍建议你在使用前先理解它的作用，并自行确认本地数据目录状态。
