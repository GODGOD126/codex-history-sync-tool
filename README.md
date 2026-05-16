# Codex History Sync Tool

一个用于修复 Codex Desktop 本地历史对话显示问题的开源工具。

当你切换 API、provider、模型或登录方式后，Codex Desktop 有时会出现“本地历史还在，但侧边栏看不到”的情况。本工具会检查本机 Codex 数据库、会话文件和侧边栏索引，并把旧历史安全地挂回当前 `model_provider` / `model`。

## 安全说明

- 所有操作都在本机执行，不上传历史记录、配置或数据库。
- 写入前会自动创建备份；恢复前也会创建 `pre-restore` 安全备份。
- 同步和恢复都建议先执行预览，图形界面会阻止未预览的写入操作。
- 备份默认保存在 `%USERPROFILE%\.codex\history_sync_backups`。
- 新版备份会生成 `*.manifest.json`，记录数据库、会话索引和元数据备份的 SHA256、大小和统计信息。
- 真实恢复会先校验备份 manifest；缺少 manifest 或 SHA256/大小不一致的备份只能预览，不能直接恢复。

## 功能

- 检查当前本地 Codex 历史属于哪些 provider/model。
- 预览同步会影响的数据库记录、会话文件和侧边栏索引。
- 将旧 provider/model 下的线程同步到当前 Codex 配置。
- 支持按项目目录 `cwd` 限定同步范围。
- 创建、预览和恢复备份。
- 提供 PowerShell WinForms、现代 Web UI 和 Tauri 桌面壳。
- 提供 GitHub Actions 预览构建，Windows 和 macOS 用户都可以下载验证包。

## 运行环境

- Python 3.10 或更高版本。
- Windows PowerShell 5.1 或 PowerShell 7 用于 WinForms 入口。
- Node.js 20 或更高版本用于 Web UI。
- 构建 Tauri 桌面版需要 Rust/Cargo 和系统 WebView 运行环境。
- 本机存在 Codex Desktop 数据目录，通常是 `%USERPROFILE%\.codex` 或 `~/.codex`。

## 快速使用

### WinForms 桌面界面

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launch_ui.ps1
```

创建桌面快捷方式：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launch_ui.ps1 -InstallShortcutOnly
```

### 现代 Web UI

```powershell
cd .\modern-ui
npm install
npm start
```

打开：

```text
http://127.0.0.1:4757
```

### Tauri 桌面版

```powershell
cd .\tauri-ui
npm install
npm run build
```

构建产物会生成在：

```text
tauri-ui\src-tauri\target\release\bundle
```

开发模式使用 `4758` 端口，避免和独立 Web UI 的 `4757` 冲突：

```powershell
npm run dev
```

也可以使用脚本启动已构建的 Windows 桌面版：

```cmd
scripts\start-tauri.cmd
```

## 命令行

环境检测：

```powershell
py -3 .\sync_backend.py --json doctor
```

查看状态：

```powershell
py -3 .\sync_backend.py --json status
```

预览同步，不写入：

```powershell
py -3 .\sync_backend.py --json sync --dry-run
```

执行同步：

```powershell
py -3 .\sync_backend.py --json sync
```

只同步某个项目目录：

```powershell
py -3 .\sync_backend.py --json sync --cwd "C:\path\to\project"
```

手动指定目标 provider/model：

```powershell
py -3 .\sync_backend.py --json sync --provider openai --model gpt-5.5
```

创建备份：

```powershell
py -3 .\sync_backend.py --json backup
```

预览恢复：

```powershell
py -3 .\sync_backend.py --json restore --dry-run
```

恢复最新备份：

```powershell
py -3 .\sync_backend.py --json restore
```

查看备份清单：

```powershell
py -3 .\sync_backend.py --json manifest --backup "C:\path\to\state_5.sqlite.manual.20260516-120000.bak"
```

校验备份完整性：

```powershell
py -3 .\sync_backend.py --json verify --backup "C:\path\to\state_5.sqlite.manual.20260516-120000.bak"
```

## 下载预览构建

本仓库不提交 `.exe`、`.msi`、`.dmg` 等二进制构建产物。预览包由 GitHub Actions 生成：

1. 打开仓库的 **Actions** 页面。
2. 选择 **Preview Build** workflow。
3. 打开目标分支或 PR 的最新运行记录。
4. 在 **Artifacts** 下载：
   - `codex-history-sync-windows-preview`
   - `codex-history-sync-macos-preview`
   - `codex-history-sync-web-preview`

这些 artifact 仅用于验证，不代表正式 release。

## 测试

```powershell
py -3 -m unittest discover -s tests -v
node --check .\modern-ui\public\app.js
node --check .\modern-ui\server.js
powershell -NoProfile -ExecutionPolicy Bypass -File .\launch_ui.ps1 -SmokeTest
cargo check --manifest-path .\tauri-ui\src-tauri\Cargo.toml
npm --prefix .\tauri-ui run build
```

## 项目结构

- `sync_backend.py`：同步、备份、恢复、环境检测后端。
- `launch_ui.ps1`：Windows WinForms 图形界面。
- `modern-ui/`：本地 Web UI 和 Node.js API 代理。
- `tauri-ui/`：Tauri 桌面壳，共用 Web UI 并调用同一个 Python 后端。
- `.github/workflows/preview-build.yml`：Windows/macOS 可下载预览构建。

## 许可证

本项目使用 MIT License。贡献和分发时请保留原许可证文本。
