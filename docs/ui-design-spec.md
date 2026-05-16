# Codex History Sync UI Design Spec

Figma design file: internal design reference. If this project is published publicly, include screenshots or exported frames instead of relying on a private Figma URL.

## Direction

The interface should feel like a polished recovery console rather than a raw system utility. The visual model is a restrained desktop dashboard: a dark navigation rail, warm neutral workspace, clear status strip, and readable operational panels.

## Frames

- `Desktop WinForms - Recovery Console`: the retained PowerShell WinForms desktop surface.
- `Modern Web/Tauri - Dashboard`: the modern UI target for Web first, with a path to Electron or Tauri packaging.

## Design Tokens

- Window background: `#F6F5F2`
- Panel: `#FFFFFF`
- Text: `#151515`
- Muted text: `#6F6A60`
- Primary action: `#2558D4`
- Primary action border: `#1D49B6`
- Sidebar: `#111111`
- Border: `#E2DED6`
- Soft info: `#E8EEFF`
- Danger: `#B42318`

## UI Principles

- Run preview before destructive actions.
- Keep sync scope visible near the primary action.
- Treat restore actions as dangerous and visually distinct.
- Show backup manifest availability directly in the backup list.
- Keep logs readable but secondary to the status and action panels.
