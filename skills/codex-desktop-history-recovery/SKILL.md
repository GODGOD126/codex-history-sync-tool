---
name: codex-desktop-history-recovery
description: Recover, inspect, search, and reopen local Codex Desktop history when chats still exist on disk but are missing or incomplete in the sidebar. Use for provider/model switches, partially missing project history, hidden older threads, sidebar restoration checks, and native Desktop-only recovery where VS Code/plugin or other originators must not be mixed into Codex Desktop history.
---

# Codex Desktop History Recovery

## Goal

Restore native Codex Desktop history conservatively, keep local files intact, and make older hidden threads searchable and reopenable even when the Desktop sidebar only shows a recent window.

## Core Rules

- Prefer the repository's existing backend first: `sync_backend.py --json backup`, then `status`, then `sync`.
- Back up before every write.
- Treat `originator == "Codex Desktop"` as the native-history boundary. Do not import `codex_vscode`, Claude, or unrelated originators into Desktop history unless the user explicitly asks for that.
- Do not delete rollout files.
- Do not rewrite the main recovery flow when the backend already supports the operation.
- Use the bundled search/import helpers only after the backend flow is complete or when the sidebar remains incomplete despite intact local history.

## Workflow

1. Inspect the active Codex home.

```powershell
py -3 .\sync_backend.py --json status
```

Verify at least: `sessions/`, `state_5.sqlite`, `session_index.jsonl`, current provider/model, indexed rows, missing index rows, and any suspicious `has_user_event` distribution.

2. Run the safe backend sequence.

```powershell
py -3 .\sync_backend.py --json backup
py -3 .\sync_backend.py --json status
py -3 .\sync_backend.py --json sync
```

3. If the Desktop sidebar is still incomplete, distinguish three cases.

- **Provider/model mismatch**: keep using `sync_backend.py`.
- **Rows exist but older chats are outside the recent sidebar window**: use the bundled search/import helpers below.
- **Rows look malformed**: read [troubleshooting.md](references/troubleshooting.md) before changing the database.

4. Search or reopen native Desktop-only chats with the bundled helper.

```powershell
py -3 .\skills\codex-desktop-history-recovery\scripts\open_codex_history.py --stats
py -3 .\skills\codex-desktop-history-recovery\scripts\open_codex_history.py "project keyword"
py -3 .\skills\codex-desktop-history-recovery\scripts\open_codex_history.py "project keyword" --pick 1
```

Use `--codex-home <path>` when the active home is not the default.

5. When the user needs a broader browse/search surface, run the local portal.

```powershell
py -3 .\skills\codex-desktop-history-recovery\scripts\codex_history_portal.py
```

Useful options:

```powershell
py -3 .\skills\codex-desktop-history-recovery\scripts\codex_history_portal.py --codex-home "C:\path\to\.codex" --visible-limit 150
```

The portal groups projects, searches metadata and rollout text, and can promote one selected native Desktop thread back into the recent window before opening it.

## When To Read The Reference

Read [troubleshooting.md](references/troubleshooting.md) when:

- `sync` reports a busy database or file lock.
- `missing_session_index_entries` is non-zero.
- `threads.has_user_event` is unexpectedly zero-heavy.
- the same project appears split across multiple path spellings.
- native Desktop rows exist, but the sidebar still appears incomplete after `sync`.

## Validation

Before declaring success:

1. Re-run `status`.
2. Confirm native Desktop counts are unchanged except for intended updates.
3. Confirm no non-Desktop originators were introduced.
4. Search at least one known older thread and reopen it successfully.
5. If using the portal, confirm the user can find hidden threads without bulk-importing unrelated history.
