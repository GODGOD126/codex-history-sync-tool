import argparse
import json
import os
import shutil
import sqlite3
import sys
import time
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


def default_codex_home() -> Path:
    raw = os.environ.get("CODEX_HOME")
    return Path(raw).expanduser() if raw else Path.home() / ".codex"


DEFAULT_CODEX_HOME = default_codex_home()
DESKTOP_ORIGINATOR = "Codex Desktop"

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except AttributeError:
    pass


@dataclass
class Match:
    row: sqlite3.Row
    score: int
    snippet: str
    where: str


def plain_path(raw: str | None) -> str:
    if raw is None:
        return ""
    return raw[4:] if raw.startswith("\\\\?\\") else raw


def backup_file(path: Path, backup_dir: Path, label: str) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    target = backup_dir / f"{path.name}.{label}.{stamp}.bak"
    shutil.copy2(path, target)
    return target


def read_originator(path: Path) -> str:
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if item.get("type") == "session_meta":
                    return str((item.get("payload") or {}).get("originator") or "")
    except FileNotFoundError:
        return ""
    return ""


def compact(value: str, max_len: int = 180) -> str:
    text = " ".join(value.replace("\r", " ").replace("\n", " ").split())
    if len(text) <= max_len:
        return text
    return text[: max_len - 1] + "..."


def recursive_strings(value) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from recursive_strings(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            if key in {"id", "thread_id", "parent_id", "timestamp", "cwd", "rollout_path"}:
                continue
            yield from recursive_strings(item)


def all_terms_in(text: str, terms: list[str]) -> bool:
    hay = text.casefold()
    return all(term in hay for term in terms)


def line_snippet(raw_line: str, terms: list[str]) -> str:
    try:
        item = json.loads(raw_line)
        text = " ".join(s for s in recursive_strings(item) if s)
    except json.JSONDecodeError:
        text = raw_line
    text = compact(text)
    if not terms:
        return text
    lowered = text.casefold()
    positions = [lowered.find(term) for term in terms if lowered.find(term) >= 0]
    if not positions:
        return text
    start = max(0, min(positions) - 45)
    end = min(len(text), max(positions) + 135)
    prefix = "..." if start else ""
    suffix = "..." if end < len(text) else ""
    return prefix + text[start:end] + suffix


def fetch_threads(db_path: Path, include_archived: bool) -> list[sqlite3.Row]:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        archived_filter = "" if include_archived else "WHERE archived = 0"
        rows = conn.execute(
            f"""
            SELECT id, title, cwd, preview, first_user_message, updated_at,
                   updated_at_ms, rollout_path, archived
            FROM threads
            {archived_filter}
            ORDER BY updated_at DESC, id DESC
            """
        ).fetchall()
    finally:
        conn.close()
    return [row for row in rows if read_originator(Path(row["rollout_path"])) == DESKTOP_ORIGINATOR]


def score_metadata(row: sqlite3.Row, terms: list[str]) -> tuple[int, str, str]:
    fields = [
        ("title", row["title"] or "", 120),
        ("cwd", plain_path(row["cwd"]), 80),
        ("preview", row["preview"] or "", 55),
        ("first_user_message", row["first_user_message"] or "", 55),
        ("id", row["id"], 10),
    ]
    score = 0
    best_where = ""
    best_snippet = ""
    for name, value, weight in fields:
        if value and all_terms_in(value, terms):
            score += weight
            if not best_where:
                best_where = name
                best_snippet = compact(value)
    return score, best_where, best_snippet


def score_rollout(row: sqlite3.Row, terms: list[str], scan_fulltext: bool) -> tuple[int, str, str]:
    if not scan_fulltext:
        return 0, "", ""
    path = Path(row["rollout_path"])
    score = 0
    best_snippet = ""
    try:
        with path.open("r", encoding="utf-8") as handle:
            for raw_line in handle:
                if all_terms_in(raw_line, terms):
                    score += 8
                    if not best_snippet:
                        best_snippet = line_snippet(raw_line, terms)
                    if score >= 80:
                        break
    except FileNotFoundError:
        return 0, "", ""
    return score, "rollout", best_snippet


def find_matches(
    db_path: Path,
    query: str,
    thread_id: str | None,
    limit: int,
    include_archived: bool,
    scan_fulltext: bool,
) -> list[Match]:
    rows = fetch_threads(db_path, include_archived=include_archived)
    if thread_id:
        return [
            Match(row=row, score=9999, snippet=compact(row["title"] or row["id"]), where="id")
            for row in rows
            if row["id"] == thread_id
        ]

    terms = [part.casefold() for part in query.split() if part.strip()]
    if not terms:
        return [
            Match(row=row, score=1, snippet=compact(row["preview"] or row["first_user_message"] or ""), where="recent")
            for row in rows[:limit]
        ]

    matches: list[Match] = []
    for row in rows:
        metadata_score, metadata_where, metadata_snippet = score_metadata(row, terms)
        rollout_score, rollout_where, rollout_snippet = score_rollout(row, terms, scan_fulltext)
        score = metadata_score + rollout_score
        if score <= 0:
            continue
        where = metadata_where or rollout_where
        snippet = metadata_snippet or rollout_snippet
        matches.append(Match(row=row, score=score, snippet=snippet, where=where))

    matches.sort(key=lambda item: (item.score, item.row["updated_at"] or 0, item.row["id"]), reverse=True)
    return matches[:limit]


def update_session_index(index_path: Path, thread_ids: set[str], iso_time: str) -> int:
    if not index_path.exists():
        return 0
    rows: list[str] = []
    changed = 0
    with index_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                rows.append(line)
                continue
            if item.get("id") in thread_ids:
                item["updated_at"] = iso_time
                changed += 1
                rows.append(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n")
            else:
                rows.append(line)
    index_path.write_text("".join(rows), encoding="utf-8")
    return changed


def append_rollout_touch_events(rows: list[sqlite3.Row], backup_dir: Path, iso_time_ms: str) -> list[str]:
    touched: list[str] = []
    for row in rows:
        rollout_path = Path(row["rollout_path"])
        if not rollout_path.exists():
            continue
        backup_file(rollout_path, backup_dir, "pre-open-rollout")
        event = {
            "timestamp": iso_time_ms,
            "type": "event_msg",
            "payload": {
                "type": "thread_name_updated",
                "thread_id": row["id"],
                "thread_name": row["title"],
            },
        }
        with rollout_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")
        touched.append(str(rollout_path))
    return touched


def promote_rows(codex_home: Path, rows: list[sqlite3.Row], dry_run: bool, unarchive: bool) -> dict:
    if not rows:
        return {"ok": False, "reason": "no rows selected"}

    db_path = codex_home / "state_5.sqlite"
    index_path = codex_home / "session_index.jsonl"
    backup_dir = codex_home / "history_sync_backups"
    now = int(time.time())
    iso_time = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    iso_time_ms = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    thread_ids = {row["id"] for row in rows}

    result = {
        "ok": True,
        "dry_run": dry_run,
        "promoted_count": len(rows),
        "promoted_to_updated_at": iso_time,
        "threads": [format_row(row) for row in rows],
    }
    if dry_run:
        return result

    db_backup = backup_file(db_path, backup_dir, "pre-open-history")
    index_backup = backup_file(index_path, backup_dir, "pre-open-history") if index_path.exists() else None

    conn = sqlite3.connect(db_path)
    try:
        for offset, row in enumerate(rows):
            promoted = now + len(rows) - offset
            conn.execute(
                """
                UPDATE threads
                SET updated_at = ?,
                    updated_at_ms = CASE WHEN updated_at_ms IS NULL THEN NULL ELSE ? END,
                    archived = CASE WHEN ? THEN 0 ELSE archived END
                WHERE id = ?
                """,
                (promoted, promoted * 1000 if row["updated_at_ms"] is not None else None, 1 if unarchive else 0, row["id"]),
            )
        conn.commit()
    finally:
        conn.close()

    result["db_backup"] = str(db_backup)
    result["session_index_backup"] = str(index_backup) if index_backup else None
    result["session_index_updates"] = update_session_index(index_path, thread_ids, iso_time)
    result["touched_rollouts"] = append_rollout_touch_events(rows, backup_dir, iso_time_ms)
    return result


def format_row(row: sqlite3.Row) -> dict:
    return {
        "id": row["id"],
        "title": compact(row["title"] or "", 180),
        "cwd": plain_path(row["cwd"]),
        "updated_at": row["updated_at"],
        "archived": bool(row["archived"]),
        "rollout_path": plain_path(row["rollout_path"]),
    }


def print_matches(matches: list[Match]) -> None:
    if not matches:
        print("No matching active Codex Desktop threads.")
        return
    for index, match in enumerate(matches, start=1):
        row = match.row
        print(f"[{index}] {compact(row['title'] or '(untitled)', 120)}")
        print(f"    id: {row['id']}")
        print(f"    cwd: {plain_path(row['cwd'])}")
        print(f"    score: {match.score}  where: {match.where}  archived: {bool(row['archived'])}")
        if match.snippet:
            print(f"    snippet: {match.snippet}")


def print_stats(db_path: Path) -> None:
    active_rows = fetch_threads(db_path, include_archived=False)
    all_rows = fetch_threads(db_path, include_archived=True)
    archived_rows = [row for row in all_rows if row["archived"]]
    by_cwd = Counter(plain_path(row["cwd"]) or "(no cwd)" for row in active_rows)
    result = {
        "originator": DESKTOP_ORIGINATOR,
        "active_native_desktop_threads": len(active_rows),
        "archived_native_desktop_threads": len(archived_rows),
        "total_native_desktop_threads": len(all_rows),
        "active_project_count": len(by_cwd),
        "top_active_projects": [
            {"cwd": cwd, "count": count}
            for cwd, count in by_cwd.most_common(30)
        ],
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))


def launch_codex_app() -> dict[str, str]:
    app_id = os.environ.get("CODEX_DESKTOP_APPID", "OpenAI.Codex_2p2nqsd0c76g0!App")
    subprocess.Popen(
        ["explorer.exe", f"shell:AppsFolder\\{app_id}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    return {"open_mode": "app", "app_id": app_id}


def open_thread(thread_id: str) -> dict[str, str]:
    if sys.platform != "win32":
        raise RuntimeError("Codex Desktop launch is only implemented for Windows here")
    if os.environ.get("CODEX_HISTORY_OPEN_MODE", "").casefold() == "deeplink":
        os.startfile(f"codex://threads/{thread_id}")  # type: ignore[attr-defined]
        return {"open_mode": "deeplink", "uri": f"codex://threads/{thread_id}"}
    result = launch_codex_app()
    result["thread_id"] = thread_id
    return result


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Search all native Codex Desktop history, promote a selected thread, and open it in Codex Desktop."
    )
    parser.add_argument("query", nargs="?", default="", help="Search text. Searches title, cwd, preview, first user message, and rollout text.")
    parser.add_argument("--codex-home", default=str(DEFAULT_CODEX_HOME))
    parser.add_argument("--id", dest="thread_id", help="Open a specific thread id.")
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--pick", type=int, help="Promote/open the Nth result from the search output, 1-based.")
    parser.add_argument("--promote-matches", action="store_true", help="Promote every result in the current result page.")
    parser.add_argument("--metadata-only", action="store_true", help="Do not scan rollout JSONL full text.")
    parser.add_argument("--include-archived", action="store_true", help="Also search archived native Desktop threads.")
    parser.add_argument("--keep-archived", action="store_true", help="Do not unarchive a selected archived thread.")
    parser.add_argument("--no-open", action="store_true", help="Promote selected thread but do not launch Codex Desktop.")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--stats", action="store_true", help="Print native Codex Desktop history counts and active project distribution.")
    args = parser.parse_args()

    codex_home = Path(args.codex_home)
    db_path = codex_home / "state_5.sqlite"
    if not db_path.exists():
        raise SystemExit(f"state db not found: {db_path}")

    if args.stats:
        print_stats(db_path)
        return

    matches = find_matches(
        db_path=db_path,
        query=args.query,
        thread_id=args.thread_id,
        limit=args.limit,
        include_archived=args.include_archived,
        scan_fulltext=not args.metadata_only,
    )

    selected: list[sqlite3.Row] = []
    should_open = False
    if args.thread_id:
        selected = [match.row for match in matches]
        should_open = True
    elif args.promote_matches:
        selected = [match.row for match in matches]
        should_open = len(selected) == 1
    elif args.pick is not None:
        if args.pick < 1 or args.pick > len(matches):
            raise SystemExit(f"--pick must be between 1 and {len(matches)}")
        selected = [matches[args.pick - 1].row]
        should_open = True
    elif len(matches) == 1 and args.query:
        selected = [matches[0].row]
        should_open = True

    if not selected:
        if args.json:
            print(json.dumps({"ok": True, "selected": False, "matches": [format_match(m) for m in matches]}, ensure_ascii=False, indent=2))
        else:
            print_matches(matches)
            if matches:
                print("")
                print("To open one result, run:")
                print('  python .\\open_codex_history.py "<query>" --pick 1')
                print("Or open by id:")
                print("  python .\\open_codex_history.py --id <thread-id>")
        return

    result = promote_rows(
        codex_home=codex_home,
        rows=selected,
        dry_run=args.dry_run,
        unarchive=not args.keep_archived,
    )
    if should_open and not args.no_open and not args.dry_run:
        result["opened"] = open_thread(selected[0]["id"])

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(result, ensure_ascii=False, indent=2))


def format_match(match: Match) -> dict:
    data = format_row(match.row)
    data["score"] = match.score
    data["where"] = match.where
    data["snippet"] = match.snippet
    return data


if __name__ == "__main__":
    main()
