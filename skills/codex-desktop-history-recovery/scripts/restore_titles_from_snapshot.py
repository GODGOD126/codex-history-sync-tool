import argparse
import json
import os
import shutil
import sqlite3
from datetime import datetime, timezone
from pathlib import Path


RAW_TITLE_PREFIXES = (
    "# ",
    "%",
    "Traceback ",
    "<ide_opened_file>",
    "<command-name>",
    "The user opened ",
)
LOW_VALUE_TITLES = {
    "",
    "hi",
    "hello",
    "test",
    "1",
    "111111",
    "你好",
    "您好",
    "在吗",
    "新对话",
}


def default_codex_home() -> Path:
    raw = os.environ.get("CODEX_HOME")
    return Path(raw).expanduser() if raw else Path.home() / ".codex"


def backup_file(path: Path, backup_dir: Path, label: str) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    target = backup_dir / f"{path.name}.{label}.{stamp}.bak"
    shutil.copy2(path, target)
    return target


def plain_path(raw: str | None) -> Path:
    value = raw or ""
    return Path(value[4:] if value.startswith("\\\\?\\") else value)


def table_columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in conn.execute(f"PRAGMA table_info({table})")}


def normalized_title(title: str | None) -> str:
    return " ".join((title or "").replace("\r", " ").replace("\n", " ").split())


def low_value_title(title: str | None) -> bool:
    value = normalized_title(title)
    if value.casefold() in LOW_VALUE_TITLES:
        return True
    if len(value) > 2 and len(set(value)) == 1:
        return True
    return value.isdigit()


def raw_current_title(row: dict[str, object]) -> bool:
    title = str(row.get("title") or "")
    first = str(row.get("first_user_message") or "")
    preview = str(row.get("preview") or "")
    return (
        title == first
        or title == preview
        or len(title) > 120
        or "\n" in title
        or "\r" in title
        or title.startswith(RAW_TITLE_PREFIXES)
    )


def useful_snapshot_title(row: dict[str, object]) -> bool:
    title = str(row.get("title") or "")
    first = str(row.get("first_user_message") or "")
    if low_value_title(title):
        return False
    if len(title) > 120 or "\n" in title or "\r" in title:
        return False
    if title.startswith(RAW_TITLE_PREFIXES):
        return False
    return title != first


def fetch_rows(conn: sqlite3.Connection, columns: set[str]) -> dict[str, dict[str, object]]:
    wanted = [column for column in ["id", "title", "preview", "first_user_message", "cwd", "rollout_path"] if column in columns]
    rows: dict[str, dict[str, object]] = {}
    for row in conn.execute(f"SELECT {','.join(wanted)} FROM threads"):
        item = dict(zip(wanted, row))
        rows[str(item["id"])] = item
    return rows


def rewrite_session_index(session_index: Path, title_by_id: dict[str, str]) -> int:
    updated = 0
    rebuilt: list[str] = []
    for raw_line in session_index.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip():
            continue
        try:
            item = json.loads(raw_line)
        except json.JSONDecodeError:
            rebuilt.append(raw_line)
            continue
        thread_id = item.get("id") or item.get("thread_id")
        title = title_by_id.get(thread_id)
        if title is not None:
            item["thread_name"] = title
            updated += 1
        rebuilt.append(json.dumps(item, ensure_ascii=False, separators=(",", ":")))
    session_index.write_text(("\n".join(rebuilt) + "\n") if rebuilt else "", encoding="utf-8")
    return updated


def append_title_events(
    rows_by_id: dict[str, dict[str, object]],
    title_by_id: dict[str, str],
    backup_dir: Path,
) -> list[str]:
    timestamp = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    touched: list[str] = []
    for thread_id, title in title_by_id.items():
        rollout_path = plain_path(str(rows_by_id.get(thread_id, {}).get("rollout_path") or ""))
        if not rollout_path.exists():
            continue
        backup_file(rollout_path, backup_dir, "pre-title-restore-rollout")
        event = {
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": {
                "type": "thread_name_updated",
                "thread_id": thread_id,
                "thread_name": title,
            },
        }
        with rollout_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
        touched.append(str(rollout_path))
    return touched


def restore_titles(
    codex_home: Path,
    snapshot_db: Path,
    dry_run: bool,
    write_rollout_events: bool,
) -> dict[str, object]:
    current_db = codex_home / "state_5.sqlite"
    session_index = codex_home / "session_index.jsonl"
    if not current_db.exists():
        raise FileNotFoundError(current_db)
    if not snapshot_db.exists():
        raise FileNotFoundError(snapshot_db)

    current = sqlite3.connect(current_db)
    snapshot = sqlite3.connect(snapshot_db)
    try:
        current_columns = table_columns(current, "threads")
        snapshot_columns = table_columns(snapshot, "threads")
        current_rows = fetch_rows(current, current_columns)
        snapshot_rows = fetch_rows(snapshot, snapshot_columns)

        candidates: list[dict[str, str]] = []
        for thread_id, row in sorted(current_rows.items()):
            old = snapshot_rows.get(thread_id)
            if old is None or row.get("title") == old.get("title"):
                continue
            if not raw_current_title(row) or not useful_snapshot_title(old):
                continue
            candidates.append(
                {
                    "id": thread_id,
                    "restore_title": str(old.get("title") or ""),
                    "current_title_prefix": normalized_title(str(row.get("title") or ""))[:160],
                    "cwd": str(row.get("cwd") or ""),
                }
            )

        if dry_run:
            return {
                "ok": True,
                "dry_run": True,
                "codex_home": str(codex_home),
                "snapshot_db": str(snapshot_db),
                "candidate_count": len(candidates),
                "candidates": candidates,
            }

        backup_dir = codex_home / "history_sync_backups"
        db_backup = backup_file(current_db, backup_dir, "pre-title-restore")
        index_backup = backup_file(session_index, backup_dir, "pre-title-restore-index") if session_index.exists() else None
        title_by_id = {item["id"]: item["restore_title"] for item in candidates}

        current.execute("BEGIN IMMEDIATE")
        for thread_id, title in title_by_id.items():
            current.execute("UPDATE threads SET title = ? WHERE id = ?", (title, thread_id))
        current.commit()

        updated_index_entries = rewrite_session_index(session_index, title_by_id) if session_index.exists() else 0
        touched_rollouts = append_title_events(current_rows, title_by_id, backup_dir) if write_rollout_events else []

        return {
            "ok": True,
            "dry_run": False,
            "codex_home": str(codex_home),
            "snapshot_db": str(snapshot_db),
            "db_backup": str(db_backup),
            "index_backup": str(index_backup) if index_backup else None,
            "restored_title_count": len(candidates),
            "updated_index_entries": updated_index_entries,
            "touched_rollouts": touched_rollouts,
            "restored_titles": [{"id": item["id"], "title": item["restore_title"], "cwd": item["cwd"]} for item in candidates],
        }
    except Exception:
        current.rollback()
        raise
    finally:
        snapshot.close()
        current.close()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Restore useful Codex thread titles from a known-good state_5.sqlite snapshot."
    )
    parser.add_argument("--codex-home", type=Path, default=default_codex_home())
    parser.add_argument("--snapshot", type=Path, required=True, help="Known-good state_5.sqlite backup or snapshot.")
    parser.add_argument("--no-rollout-events", action="store_true", help="Do not append thread_name_updated events to rollouts.")
    parser.add_argument("--apply", action="store_true", help="Write changes. Default is dry-run.")
    args = parser.parse_args()

    result = restore_titles(
        codex_home=args.codex_home.expanduser(),
        snapshot_db=args.snapshot.expanduser(),
        dry_run=not args.apply,
        write_rollout_events=not args.no_rollout_events,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
