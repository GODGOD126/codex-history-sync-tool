import argparse
import json
import os
import sqlite3
from collections import Counter
from pathlib import Path


DESKTOP_ORIGINATOR = "Codex Desktop"


def default_codex_home() -> Path:
    raw = os.environ.get("CODEX_HOME")
    return Path(raw).expanduser() if raw else Path.home() / ".codex"


def plain_path(raw: str | None) -> Path:
    value = raw or ""
    return Path(value[4:] if value.startswith("\\\\?\\") else value)


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


def suspicious_title(title: str | None, first_user_message: str | None, preview: str | None) -> bool:
    value = title or ""
    return (
        value == (first_user_message or "")
        or value == (preview or "")
        or len(value) > 120
        or "\n" in value
        or "\r" in value
        or value.startswith(("# ", "%", "Traceback "))
    )


def scan_rollouts(codex_home: Path, roots: list[Path]) -> dict[str, dict[str, str]]:
    rollouts: dict[str, dict[str, str]] = {}
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("rollout-*.jsonl"):
            meta = read_session_meta(path)
            thread_id = str(meta.get("id") or "")
            if not thread_id or thread_id in rollouts:
                continue
            rollouts[thread_id] = {
                "id": thread_id,
                "originator": str(meta.get("originator") or ""),
                "cwd": str(meta.get("cwd") or ""),
                "timestamp": str(meta.get("timestamp") or ""),
                "path": str(path),
            }
    return rollouts


def audit(codex_home: Path, roots: list[Path]) -> dict[str, object]:
    db_path = codex_home / "state_5.sqlite"
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            """
            SELECT id, title, cwd, preview, first_user_message, rollout_path,
                   archived, has_user_event
            FROM threads
            """
        ).fetchall()
    finally:
        conn.close()

    db_ids = {str(row["id"]) for row in rows}
    rollouts = scan_rollouts(codex_home, roots)

    db_origin_counts: Counter[str] = Counter()
    db_native_ids: set[str] = set()
    missing_rollout_rows: list[dict[str, str]] = []
    active_non_desktop_rows: list[dict[str, str]] = []
    suspicious_title_rows: list[dict[str, str]] = []

    for row in rows:
        rollout_path = plain_path(str(row["rollout_path"] or ""))
        meta = read_session_meta(rollout_path)
        originator = str(meta.get("originator") or "")
        db_origin_counts[originator] += 1
        if originator == DESKTOP_ORIGINATOR:
            db_native_ids.add(str(row["id"]))
        if not rollout_path.exists():
            missing_rollout_rows.append(
                {"id": str(row["id"]), "title": str(row["title"] or ""), "rollout_path": str(rollout_path)}
            )
        if int(row["archived"] or 0) == 0 and originator and originator != DESKTOP_ORIGINATOR:
            active_non_desktop_rows.append(
                {"id": str(row["id"]), "originator": originator, "title": str(row["title"] or "")}
            )
        if suspicious_title(row["title"], row["first_user_message"], row["preview"]):
            suspicious_title_rows.append(
                {"id": str(row["id"]), "title_prefix": str(row["title"] or "")[:160]}
            )

    native_rollouts = {
        thread_id: item
        for thread_id, item in rollouts.items()
        if item["originator"] == DESKTOP_ORIGINATOR
    }
    missing_native_from_db = [
        item for thread_id, item in sorted(native_rollouts.items()) if thread_id not in db_ids
    ]

    return {
        "codex_home": str(codex_home),
        "db_thread_count": len(db_ids),
        "db_originator_counts": dict(db_origin_counts),
        "db_native_desktop_threads": len(db_native_ids),
        "rollout_unique_count": len(rollouts),
        "rollout_originator_counts": dict(Counter(item["originator"] for item in rollouts.values())),
        "rollout_native_desktop_threads": len(native_rollouts),
        "missing_native_desktop_from_db_count": len(missing_native_from_db),
        "missing_native_desktop_from_db": missing_native_from_db,
        "missing_rollout_rows_count": len(missing_rollout_rows),
        "missing_rollout_rows": missing_rollout_rows,
        "active_non_desktop_rows_count": len(active_non_desktop_rows),
        "active_non_desktop_rows": active_non_desktop_rows,
        "suspicious_title_rows_count": len(suspicious_title_rows),
        "suspicious_title_rows": suspicious_title_rows[:100],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Audit native Codex Desktop history consistency.")
    parser.add_argument("--codex-home", type=Path, default=default_codex_home())
    parser.add_argument(
        "--scan-root",
        type=Path,
        action="append",
        help="Additional or replacement rollout scan root. Defaults to sessions, archived_sessions, and history_sync_backups.",
    )
    args = parser.parse_args()

    codex_home = args.codex_home.expanduser()
    roots = args.scan_root or [
        codex_home / "sessions",
        codex_home / "archived_sessions",
        codex_home / "history_sync_backups",
    ]
    print(json.dumps(audit(codex_home, [root.expanduser() for root in roots]), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
