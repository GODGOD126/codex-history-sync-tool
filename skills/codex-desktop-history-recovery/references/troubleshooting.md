# Troubleshooting

## Data Surfaces

- `state_5.sqlite`: Desktop thread metadata and sidebar-facing state.
- `session_index.jsonl`: index rows that connect rollout files to thread ids.
- `sessions/**/rollout-*.jsonl`: durable local conversation files.

Use all three before concluding that history is lost.

## Native Desktop Boundary

Treat rollout metadata with `originator == "Codex Desktop"` as native Desktop history.

Do not silently import:

- `codex_vscode`
- Claude imports
- other non-Desktop originators

Those may be useful records, but mixing them into Desktop recovery changes the user's history surface.

## Busy Database Or Files

If `sync_backend.py --json sync` reports a busy database or file:

1. Do not force-close Codex.
2. Rebuild or repair read-only indexes first when possible.
3. If a write is still needed, wait for all Codex Desktop processes to exit, then run:

```powershell
py -3 .\sync_backend.py --json backup
py -3 .\sync_backend.py --json sync
py -3 .\sync_backend.py --json status
```

## Missing Session Index Rows

If rollout files exist but `missing_session_index_entries > 0`, rebuild the index from rollout metadata before changing broader history state.

Always back up `session_index.jsonl` before rewriting it.

## Suspicious `has_user_event`

If many rows have `threads.has_user_event = 0` even though the rollout contains user activity:

1. Back up `state_5.sqlite`.
2. For each suspect thread, scan its rollout JSONL.
3. If the rollout contains a `user_message` event, set that thread's `has_user_event` to `1`.

This repair is relevant because Desktop history views commonly hide rows that appear to lack user activity.

## Project Path Splits

If the same project is represented by several equivalent path spellings, normalize cautiously:

- preserve the real project path
- avoid collapsing unrelated workspaces with similar leaf names
- prefer exact existing native Desktop roots when the user is trying to restore the original Desktop project list

## Sidebar Still Looks Incomplete

If the database and rollouts are intact but the sidebar still omits older chats, the issue may be a recent-window display limit rather than missing data.

Use:

```powershell
py -3 .\skills\codex-desktop-history-recovery\scripts\open_codex_history.py "query"
py -3 .\skills\codex-desktop-history-recovery\scripts\codex_history_portal.py
```

The helper scripts search all native Desktop rows, then selectively promote only the thread the user chooses to reopen.

## Native Completeness Audit

When the sidebar and portal disagree with what the user remembers, audit the native Desktop boundary instead of judging by visible sidebar rows.

```powershell
py -3 .\skills\codex-desktop-history-recovery\scripts\audit_native_history_integrity.py --codex-home "C:\path\to\.codex"
```

Healthy recovery target:

- `db_native_desktop_threads` equals `rollout_native_desktop_threads`
- `missing_native_desktop_from_db_count` is `0`
- active non-Desktop rows are not mixed into the Desktop sidebar surface

The audit scans `sessions`, `archived_sessions`, and `history_sync_backups` by default. If old rollouts were quarantined elsewhere, add one or more `--scan-root` values.

## Missing Native Rows In Backups Or Quarantine

If the audit reports native Desktop rollout files that are absent from `state_5.sqlite`, restore those rows from a known-good snapshot. Dry-run first:

```powershell
py -3 .\skills\codex-desktop-history-recovery\scripts\restore_missing_desktop_threads_from_snapshot.py --codex-home "C:\path\to\.codex" --snapshot "C:\path\to\state_5.sqlite.bak"
```

Apply only after reviewing the candidate list:

```powershell
py -3 .\skills\codex-desktop-history-recovery\scripts\restore_missing_desktop_threads_from_snapshot.py --codex-home "C:\path\to\.codex" --snapshot "C:\path\to\state_5.sqlite.bak" --apply
```

By default, restored rows are archived. That keeps them searchable and reopenable without forcing every recovered conversation into the active sidebar window. Use `--active` only when the user explicitly wants those rows active.

## Raw Prompt Titles Or Missing Known Titles

If a known thread exists but cannot be found by its remembered title, the current title may have been overwritten by a raw prompt, preview, or IDE event. Restore only suspicious titles from a known-good snapshot:

```powershell
py -3 .\skills\codex-desktop-history-recovery\scripts\restore_titles_from_snapshot.py --codex-home "C:\path\to\.codex" --snapshot "C:\path\to\state_5.sqlite.bak"
py -3 .\skills\codex-desktop-history-recovery\scripts\restore_titles_from_snapshot.py --codex-home "C:\path\to\.codex" --snapshot "C:\path\to\state_5.sqlite.bak" --apply
```

The title restore is intentionally conservative: it skips low-value snapshot titles, long raw prompts, multiline text, and any current title that does not look damaged.

## Portal Completeness Rules

When maintaining or debugging the portal:

- include archived native Desktop threads by default, because archived rows are still real local history
- project search must match project name, path, title, preview, and thread id
- full-text search should search rollout JSONL content, not only database metadata
- fold Codex temporary scratch directories in the project sidebar when useful, but do not filter those conversations out of search results
- when a project filter is active, left-side counts should reflect the current search context, not only total project size
- keep long explanatory text out of the main toolbar; use concise controls and documentation instead
