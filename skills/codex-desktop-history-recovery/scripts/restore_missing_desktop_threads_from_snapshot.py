import argparse
import json
import os
import shutil
import sqlite3
import time
from datetime import datetime
from pathlib import Path


DESKTOP_ORIGINATOR = "Codex Desktop"


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


def session_id_from_name(path: Path) -> str:
    stem = path.stem
    parts = stem.split("-")
    return "-".join(parts[-5:]) if len(parts) >= 6 else ""


def read_session_meta(path: Path) -> dict[str, object]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if item.get("type") == "session_meta":
                    return item.get("payload") or {}
    except FileNotFoundError:
        return {}
    return {}


def scan_native_rollouts(existing_ids: set[str], roots: list[Path]) -> dict[str, Path]:
    found: dict[str, Path] = {}
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("rollout-*.jsonl"):
            meta = read_session_meta(path)
            thread_id = str(meta.get("id") or "") or session_id_from_name(path)
            if not thread_id or thread_id in existing_ids or thread_id in found:
                continue
            if str(meta.get("originator") or "") != DESKTOP_ORIGINATOR:
                continue
            found[thread_id] = path
    return found


def table_columns(conn: sqlite3.Connection, table: str) -> list[str]:
    return [str(row[1]) for row in conn.execute(f"PRAGMA table_info({table})")]


def restore_missing_threads(
    codex_home: Path,
    snapshot_db: Path,
    scan_roots: list[Path],
    dry_run: bool,
    restore_active: bool,
) -> dict[str, object]:
    current_db = codex_home / "state_5.sqlite"
    if not current_db.exists():
        raise FileNotFoundError(current_db)
    if not snapshot_db.exists():
        raise FileNotFoundError(snapshot_db)

    current = sqlite3.connect(current_db)
    current.row_factory = sqlite3.Row
    snapshot = sqlite3.connect(snapshot_db)
    snapshot.row_factory = sqlite3.Row
    try:
        current_columns = table_columns(current, "threads")
        snapshot_columns = set(table_columns(snapshot, "threads"))
        existing_ids = {str(row["id"]) for row in current.execute("SELECT id FROM threads")}
        missing_rollouts = scan_native_rollouts(existing_ids, scan_roots)

        candidates: list[dict[str, object]] = []
        for thread_id, rollout_path in sorted(missing_rollouts.items()):
            row = snapshot.execute("SELECT * FROM threads WHERE id = ?", (thread_id,)).fetchone()
            if row is None:
                continue
            item: dict[str, object] = {
                column: row[column]
                for column in current_columns
                if column in snapshot_columns
            }
            item["id"] = thread_id
            if "rollout_path" in current_columns:
                item["rollout_path"] = str(rollout_path)
            if "archived" in current_columns:
                item["archived"] = 0 if restore_active else 1
            if "archived_at" in current_columns:
                item["archived_at"] = None if restore_active else int(time.time())
            candidates.append(item)

        preview = [
            {
                "id": str(item.get("id") or ""),
                "title": str(item.get("title") or ""),
                "cwd": str(item.get("cwd") or ""),
                "rollout_path": str(item.get("rollout_path") or ""),
            }
            for item in candidates
        ]

        if dry_run:
            return {
                "ok": True,
                "dry_run": True,
                "codex_home": str(codex_home),
                "snapshot_db": str(snapshot_db),
                "candidate_count": len(candidates),
                "candidates": preview,
            }

        backup_dir = codex_home / "history_sync_backups"
        db_backup = backup_file(current_db, backup_dir, "pre-restore-missing-desktop")
        current.execute("BEGIN IMMEDIATE")
        for item in candidates:
            insert_columns = [column for column in current_columns if column in item]
            placeholders = ",".join("?" for _ in insert_columns)
            sql = f"INSERT INTO threads ({','.join(insert_columns)}) VALUES ({placeholders})"
            current.execute(sql, [item[column] for column in insert_columns])
        current.commit()

        return {
            "ok": True,
            "dry_run": False,
            "codex_home": str(codex_home),
            "snapshot_db": str(snapshot_db),
            "db_backup": str(db_backup),
            "restored_count": len(candidates),
            "restored_as_active": restore_active,
            "restored": preview,
        }
    except Exception:
        current.rollback()
        raise
    finally:
        snapshot.close()
        current.close()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Restore missing native Codex Desktop thread rows from a known-good state_5.sqlite snapshot."
    )
    parser.add_argument("--codex-home", type=Path, default=default_codex_home())
    parser.add_argument("--snapshot", type=Path, required=True, help="Known-good state_5.sqlite backup or snapshot.")
    parser.add_argument(
        "--scan-root",
        type=Path,
        action="append",
        help="Rollout scan root. Defaults to sessions, archived_sessions, and history_sync_backups.",
    )
    parser.add_argument("--active", action="store_true", help="Restore rows as active instead of archived.")
    parser.add_argument("--apply", action="store_true", help="Write changes. Default is dry-run.")
    args = parser.parse_args()

    codex_home = args.codex_home.expanduser()
    scan_roots = args.scan_root or [
        codex_home / "sessions",
        codex_home / "archived_sessions",
        codex_home / "history_sync_backups",
    ]
    result = restore_missing_threads(
        codex_home=codex_home,
        snapshot_db=args.snapshot.expanduser(),
        scan_roots=[root.expanduser() for root in scan_roots],
        dry_run=not args.apply,
        restore_active=args.active,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
