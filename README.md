# Codex History Sync Tool (macOS 版)

一个用于恢复 Codex Desktop 本地历史对话显示的小工具。

当你切换 API、provider、模型或登录方式之后，Codex Desktop 有时会出现“本地历史明明还在，但侧边栏看不到”的情况。这个工具会检查本机的本地历史数据库、会话文件和侧边栏索引，并把旧线程重新挂到当前正在使用的 `model_provider` / `model` 下面。

## 这个工具能做什么

- 查看当前本机 Codex 历史线程属于哪些 provider
- 查看当前本机 Codex 历史线程属于哪些 model
- 一键把旧 provider / model 下的线程、会话元数据和侧边栏索引同步到当前设置
- 自动识别根目录或 `sqlite` 子目录中最近仍有活动的 Codex 状态数据库
- Codex Desktop 正在运行时也可以同步；如果本地数据库正在写入，工具会等待空闲后继续
- 在同步前自动备份数据库、侧边栏索引和会话元数据
- 从备份恢复数据库
- 提供一个可直接双击打开的 macOS 图形界面

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

## 运行环境

- macOS
- Python 3.9 或更高版本；GUI 需要 Tkinter
  - 系统自带 `/usr/bin/python3` 自带 Tkinter，但其 Tk 8.5 在新版 macOS 上可能无法启动，建议优先使用带新版 Tk 的 Python
  - Homebrew Python 默认不带 Tkinter，需要先执行 `brew install python-tk`
  - `launch_ui.command` 会自动检测并挑选能正常初始化 Tk 的 Python，找不到时会给出提示
- 本机存在 Codex Desktop 本地数据目录，通常是 `~/.codex`

## 快速使用

### 图形界面

在 Finder 中双击 `launch_ui.command` 即可。如果首次打开被系统拦截（从网络下载的脚本），请右键点击文件 → 打开，或先执行：

```bash
chmod +x launch_ui.command
./launch_ui.command
```

界面里可以查看状态、一键同步、手动备份、打开备份目录、恢复备份，并创建/更新桌面入口。

### 创建桌面入口

打开界面后点击“更新桌面入口”，或在终端手动复制：

```bash
cp launch_ui.command ~/Desktop/Codex\ 历史找回助手.command
chmod +x ~/Desktop/Codex\ 历史找回助手.command
```

注意：桌面入口指向工具所在目录，移动工具文件夹后需要重新生成。

### 查看当前状态

```bash
python3 sync_backend.py --json status
```

### 执行同步

```bash
python3 sync_backend.py --json sync
```

新版官方配置可能不再写入 `model_provider`。此时工具会安全地使用官方默认值 `openai`，不会从旧历史记录猜测当前账号。如果你使用第三方 Provider，或者自动识别结果不符合实际，可以手动指定目标：

```bash
python3 sync_backend.py --json sync --provider openai
python3 sync_backend.py --json sync --provider your-provider --model your-model
```

`--model` 留空时，如果 `config.toml` 里也没有 `model`，工具只修正 Provider，不会批量改写已有线程的模型。

### 手动创建备份

```bash
python3 sync_backend.py --json backup
```

### 从最新备份恢复

```bash
python3 sync_backend.py --json restore
```

也可以指定备份文件：

```bash
python3 sync_backend.py --json restore --backup /path/to/state_5.sqlite.pre-sync.xxx.bak
```

### 运行测试

```bash
python3 -m unittest discover -s tests -v
```

## 备份说明

- 每次同步前都会自动创建一份备份
- 每次恢复前也会先创建一份安全备份
- 备份默认保存在 `~/.codex/history_sync_backups`
- 新版备份会同时保存 `session_index.jsonl` 和会话文件首行元数据，恢复时会一起还原

## 状态数据库选择

Codex Desktop 不同版本可能把状态数据库放在以下任一位置：

- `~/.codex/state_5.sqlite`
- `~/.codex/sqlite/state_5.sqlite`

如果两个文件同时存在，工具会比较数据库本体和对应 `-wal` 文件的最近活动时间，选择实际仍在写入的那个；时间相同时优先根目录版本。工具不会仅因为 `sqlite` 子目录存在就使用其中可能已经过期的副本。

## 使用建议

- Codex Desktop 开着也可以同步；如果它正在生成回复或保存历史，工具可能会等待几秒
- 恢复备份会覆盖当前状态，最稳妥的做法仍然是在恢复前暂停正在运行的 Codex 任务
- 如果同步完成后历史列表没有立刻刷新，重开一次 Codex Desktop 即可
- 新版 Codex 可能还会按当前项目目录显示历史。如果同步后仍然看不到旧对话，先确认是否打开了旧对话原来的项目目录；本工具默认不会批量改写线程的 `cwd` 项目归属

## Windows 版

原版 Windows 工具仍保留在本仓库中：

- 图形界面：`launch_ui.ps1`，运行 `powershell -NoProfile -ExecutionPolicy Bypass -File .\launch_ui.ps1`
- 命令行使用 `py -3` 前缀，例如 `py -3 .\sync_backend.py --json status`

## 项目文件

- `sync_backend.py`：后端同步、备份、恢复逻辑（跨平台）
- `launch_ui.py` + `launch_ui.command`：macOS 图形界面与启动入口
- `launch_ui.ps1`：Windows 图形界面
- `CHANGELOG.md`：正式版本变更记录

## 免责声明

这个工具直接操作本机 Codex 的本地状态数据库。虽然已经做了自动备份，但仍建议你在使用前先理解它的作用，并自行确认本地数据目录状态。
