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
