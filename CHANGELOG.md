# Changelog

本项目从 `v1.0.0` 开始记录正式版本变更。

## [1.1.0] - 2026-08-13

macOS 版本。

### 新增

- 新增 macOS 图形界面 `launch_ui.py` 和可双击启动的 `launch_ui.command`，功能对齐 Windows 版（状态查看、一键同步、备份/恢复、打开备份目录、桌面入口）。
- `launch_ui.command` 会自动检测并优先选择能正常初始化 Tk 的 Python，规避系统自带 Tk 8.5 在新版 macOS 上的兼容问题。
- 后端文件替换重试逻辑兼容 macOS/Linux 的 `errno`（EBUSY/EACCES/EPERM），不再只识别 Windows 独占锁错误。
- 为跨平台文件替换重试补充单元测试。
- README 改为 macOS 优先，并保留 Windows 版说明。

### 兼容性

- 后端本身保持跨平台，Windows 版 `launch_ui.ps1` 与 `py -3` 命令行用法不变。

## [1.0.0] - 2026-08-11

首个正式稳定版本。

### 新增

- 支持新版 Codex 的 `sqlite/state_5.sqlite` 状态数据库位置。
- 支持通过图形界面或命令行手动指定目标 Provider 和 Model。
- 支持同步数据库、会话文件和侧边栏索引，并在写入前自动备份。
- 支持数据库占用重试、备份恢复和 7 位小数时间戳兼容。

### 安全与兼容性

- 当根目录和 `sqlite` 子目录的数据库同时存在时，根据数据库及其 WAL 的最近活动时间选择实际使用中的数据库。
- 配置缺少 `model_provider` 时安全回退到官方默认值 `openai`，不再从旧历史数据猜测当前 Provider。
- 配置与命令行都未指定 Model 时保留线程原有模型，不做批量改写。
