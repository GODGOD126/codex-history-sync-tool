# Codex History Sync Tauri

This folder wraps the shared `modern-ui/public` frontend in a native Tauri window.

Preview builds for Windows and macOS are produced by the `Preview Build` GitHub Actions workflow. Download them from the workflow run artifacts instead of committing binaries to the repository.

## Run

Use the built desktop app:

```powershell
.\src-tauri\target\release\codex-history-sync-tauri.exe
```

For development, Tauri uses port `4758` so it does not collide with the standalone Web UI on `4757`.

```powershell
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
npm install
npm run dev
```

## Build

```powershell
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
npm run build
```

The Rust commands embed `sync_backend.py` at compile time and write it to a temporary runtime location before calling Python. That keeps the packaged desktop app independent from the source checkout path.

On Windows, the desktop shell calls `py -3`. On macOS and Linux, it calls `python3`.
