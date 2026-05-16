# Codex History Sync Modern UI

This is the modern local Web UI prototype for Codex History Sync Tool.

It uses a small Node.js local server with no third-party dependencies. The server calls the existing `sync_backend.py` CLI and exposes a browser UI at `http://127.0.0.1:4757`.

The Web UI is also uploaded as a preview artifact by the `Preview Build` GitHub Actions workflow, together with the shared Python backend.

## Run

```powershell
cd .\modern-ui
npm install
npm start
```

Open:

```text
http://127.0.0.1:4757
```

## Packaging Path

- Web: current implementation.
- Electron: wrap this local server and browser window with Electron.
- Tauri: implemented in `..\tauri-ui`; release builds use the same static UI and call the Python backend through Rust commands.

The UI is based on the Figma design spec in `..\docs\ui-design-spec.md`.
