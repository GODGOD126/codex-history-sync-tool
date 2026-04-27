from __future__ import annotations

import argparse
import json
import re
import sqlite3
import time
from collections import OrderedDict
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

SESSION_FILENAME_PATTERN = re.compile(
    r"rollout-.*-(?P<id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$"
)
UTC = timezone.utc
DEFAULT_DB_TIMEOUT_SECONDS = 30.0
WRITE_OPERATION_TIMEOUT_SECONDS = 0.5
WRITE_LOCK_RETRY_LIMIT = 40
WRITE_LOCK_RETRY_DELAY_SECONDS = 0.25
FILE_REPLACE_RETRY_LIMIT = 20
FILE_REPLACE_RETRY_DELAY_SECONDS = 0.1
SYNC_CHECKPOINT_MODE = "PASSIVE"


def default_codex_home() -> Path:
    return Path.home() / ".codex"


@dataclass
class Paths:
    codex_home: Path
    config_path: Path
    db_path: Path
    backup_dir: Path
    session_index_path: Path
    sessions_dir: Path


@dataclass
class SessionRecord:
    thread_id: str
    path: Path
    model_provider: str
    model: str | None


def resolve_paths(codex_home: str | None) -> Paths:
    home = Path(codex_home).expanduser() if codex_home else default_codex_home()
    return Paths(
        codex_home=home,
        config_path=home / "config.toml",
        db_path=home / "state_5.sqlite",
        backup_dir=home / "history_sync_backups",
        session_index_path=home / "session_index.jsonl",
        sessions_dir=home / "sessions",
    )


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def read_text_exact(path: Path) -> str:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return handle.read()


def replace_file_with_retry(source_path: Path, target_path: Path) -> None:
    last_error: OSError | None = None
    for attempt in range(FILE_REPLACE_RETRY_LIMIT):
        try:
            # 用原子替换避免写到一半被 Codex 读到半成品文件。
            source_path.replace(target_path)
            return
        except PermissionError as exc:
            last_error = exc
        except OSError as exc:
            if getattr(exc, "winerror", None) not in (5, 32):
                raise
            last_error = exc

        if attempt < FILE_REPLACE_RETRY_LIMIT - 1:
            time.sleep(FILE_REPLACE_RETRY_DELAY_SECONDS)

    raise RuntimeError(f"File is busy and could not be replaced: {target_path}") from last_error


def write_text_exact(path: Path, text: str) -> None:
    temp_path = path.with_name(f".{path.name}.codex-sync-{time.time_ns()}.tmp")
    try:
        with temp_path.open("w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        replace_file_with_retry(temp_path, path)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def parse_current_provider(config_text: str) -> str:
    match = re.search(r'(?m)^\s*model_provider\s*=\s*"([^"]+)"', config_text)
    if not match:
        raise RuntimeError("Could not find model_provider in config.toml.")
    return match.group(1)


def parse_current_model(config_text: str) -> str | None:
    match = re.search(r'(?m)^\s*model\s*=\s*"([^"]+)"', config_text)
    return match.group(1) if match else None


@contextmanager
def connect_db(
    path: Path,
    readonly: bool = False,
    timeout_seconds: float = DEFAULT_DB_TIMEOUT_SECONDS,
    busy_timeout_ms: int | None = None,
) -> Iterator[sqlite3.Connection]:
    if busy_timeout_ms is None:
        busy_timeout_ms = max(1, int(timeout_seconds * 1000))

    if readonly:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=timeout_seconds)
    else:
        conn = sqlite3.connect(str(path), timeout=timeout_seconds)

    try:
        conn.execute(f"PRAGMA busy_timeout = {busy_timeout_ms}")
        conn.row_factory = sqlite3.Row
        yield conn
    finally:
        conn.close()


def ensure_environment(paths: Paths) -> None:
    if not paths.config_path.exists():
        raise RuntimeError(f"Missing config file: {paths.config_path}")
    if not paths.db_path.exists():
        raise RuntimeError(f"Missing database file: {paths.db_path}")


def get_thread_columns(conn: sqlite3.Connection) -> set[str]:
    return {str(row["name"]) for row in conn.execute("PRAGMA table_info(threads)")}


def counts_to_rows(counts: OrderedDict[str, int]) -> list[dict[str, object]]:
    return [{"provider": key, "count": value} for key, value in counts.items()]


def model_counts_to_rows(counts: OrderedDict[str, int]) -> list[dict[str, object]]:
    return [{"model": key, "count": value} for key, value in counts.items()]


def ordered_counts(values: list[str]) -> OrderedDict[str, int]:
    raw_counts: dict[str, int] = {}
    for value in values:
        key = value or "(empty)"
        raw_counts[key] = raw_counts.get(key, 0) + 1

    counts = OrderedDict()
    for key, value in sorted(raw_counts.items(), key=lambda item: (-item[1], item[0])):
        counts[key] = value
    return counts


def elapsed_ms(started_at: float) -> int:
    return int((time.monotonic() - started_at) * 1000)


def query_provider_counts(conn: sqlite3.Connection) -> OrderedDict[str, int]:
    counts = OrderedDict()
    for provider, count in conn.execute(
        """
        SELECT model_provider, COUNT(*)
        FROM threads
        GROUP BY model_provider
        ORDER BY COUNT(*) DESC, model_provider ASC
        """
    ):
        counts[str(provider or "(empty)")] = int(count)
    return counts


def query_model_counts(conn: sqlite3.Connection) -> OrderedDict[str, int]:
    counts = OrderedDict()
    for model, count in conn.execute(
        """
        SELECT model, COUNT(*)
        FROM threads
        GROUP BY model
        ORDER BY COUNT(*) DESC, model ASC
        """
    ):
        counts[str(model or "(empty)")] = int(count)
    return counts


def query_provider_model_counts(conn: sqlite3.Connection) -> list[dict[str, object]]:
    rows = []
    for provider, model, count in conn.execute(
        """
        SELECT model_provider, model, COUNT(*)
        FROM threads
        GROUP BY model_provider, model
        ORDER BY COUNT(*) DESC, model_provider ASC, model ASC
        """
    ):
        rows.append(
            {
                "provider": str(provider or "(empty)"),
                "model": str(model or "(empty)"),
                "count": int(count),
            }
        )
    return rows


def query_cwd_counts(conn: sqlite3.Connection, limit: int = 20) -> list[dict[str, object]]:
    rows = []
    for cwd, count in conn.execute(
        """
        SELECT cwd, COUNT(*)
        FROM threads
        GROUP BY cwd
        ORDER BY COUNT(*) DESC, cwd ASC
        LIMIT ?
        """,
        (limit,),
    ):
        rows.append({"cwd": str(cwd or "(empty)"), "count": int(count)})
    return rows


def count_mismatched(conn: sqlite3.Connection, column: str, expected: str | None) -> int | None:
    if expected is None:
        return None
    return int(
        conn.execute(
            f"SELECT COUNT(*) FROM threads WHERE {column} IS NULL OR {column} <> ?",
            (expected,),
        ).fetchone()[0]
    )


def list_backups(paths: Paths, limit: int = 20) -> list[dict[str, str]]:
    if not paths.backup_dir.exists():
        return []
    files = sorted(
        paths.backup_dir.glob("state_5.sqlite.*.bak"),
        key=lambda item: item.stat().st_mtime,
        reverse=True,
    )
    output = []
    for item in files[:limit]:
        output.append(
            {
                "name": item.name,
                "path": str(item),
                "modified_at": datetime.fromtimestamp(item.stat().st_mtime).isoformat(timespec="seconds"),
            }
        )
    return output


def split_first_line(text: str) -> tuple[str, str, str]:
    for ending in ("\r\n", "\n", "\r"):
        index = text.find(ending)
        if index >= 0:
            return text[:index], ending, text[index + len(ending) :]
    return text, "", ""


def replace_first_line(path: Path, first_line: str) -> None:
    text = read_text_exact(path)
    _, ending, remainder = split_first_line(text)
    if ending:
        new_text = first_line + ending + remainder
    elif text:
        new_text = first_line
    else:
        new_text = first_line + "\n"
    write_text_exact(path, new_text)


def session_index_backup_path(backup_path: Path) -> Path:
    return backup_path.with_name(f"{backup_path.name}.session_index.jsonl")


def session_meta_backup_path(backup_path: Path) -> Path:
    return backup_path.with_name(f"{backup_path.name}.session_meta.json")


def iter_session_paths(paths: Paths) -> list[Path]:
    if not paths.sessions_dir.exists():
        return []
    return sorted(paths.sessions_dir.rglob("rollout-*.jsonl"))


def parse_session_record(path: Path) -> SessionRecord | None:
    if not SESSION_FILENAME_PATTERN.search(path.name):
        return None

    with path.open("r", encoding="utf-8", newline="") as handle:
        first_line = handle.readline()

    if not first_line:
        return None

    item = json.loads(first_line.rstrip("\r\n"))
    if item.get("type") != "session_meta":
        return None

    payload = item.get("payload")
    if not isinstance(payload, dict):
        return None

    thread_id = str(payload.get("id") or "").strip()
    if not thread_id:
        return None

    model_provider = str(payload.get("model_provider") or "")
    raw_model = payload.get("model")
    model = str(raw_model) if raw_model else None
    return SessionRecord(thread_id=thread_id, path=path, model_provider=model_provider, model=model)


def scan_session_records(paths: Paths) -> list[SessionRecord]:
    records: list[SessionRecord] = []
    for path in iter_session_paths(paths):
        record = parse_session_record(path)
        if record:
            records.append(record)
    return records


def read_session_index(paths: Paths) -> OrderedDict[str, dict[str, str]]:
    entries: OrderedDict[str, dict[str, str]] = OrderedDict()
    if not paths.session_index_path.exists():
        return entries

    for line in read_text(paths.session_index_path).splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        thread_id = str(entry.get("id") or "").strip()
        if not thread_id:
            continue
        entries[thread_id] = {
            "id": thread_id,
            "thread_name": str(entry.get("thread_name") or thread_id),
            "updated_at": str(entry.get("updated_at") or ""),
        }
    return entries


def write_session_index(paths: Paths, entries: list[dict[str, str]]) -> None:
    lines = [json.dumps(entry, ensure_ascii=False, separators=(",", ":")) for entry in entries]
    content = "\n".join(lines)
    if content:
        content += "\n"
    write_text_exact(paths.session_index_path, content)


def iso_utc_from_unix(timestamp: int) -> str:
    return datetime.fromtimestamp(timestamp, tz=UTC).isoformat().replace("+00:00", "Z")


def parse_index_timestamp(value: str) -> datetime:
    if not value:
        return datetime.fromtimestamp(0, tz=UTC)
    normalized = value.replace("Z", "+00:00")
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def snapshot_metadata(paths: Paths, backup_path: Path) -> None:
    if paths.session_index_path.exists():
        write_text_exact(session_index_backup_path(backup_path), read_text_exact(paths.session_index_path))

    items: list[dict[str, str]] = []
    for path in iter_session_paths(paths):
        with path.open("r", encoding="utf-8", newline="") as handle:
            first_line = handle.readline().rstrip("\r\n")
        if not first_line:
            continue

        try:
            relative_path = path.relative_to(paths.codex_home)
        except ValueError:
            relative_path = path

        items.append({"path": str(relative_path), "first_line": first_line})

    write_text_exact(
        session_meta_backup_path(backup_path),
        json.dumps(items, ensure_ascii=False, indent=2) + "\n",
    )


def restore_metadata(paths: Paths, backup_path: Path) -> dict[str, object]:
    started_at = time.monotonic()
    session_index_restored = False
    session_files_restored = 0

    index_backup = session_index_backup_path(backup_path)
    if index_backup.exists():
        write_text_exact(paths.session_index_path, read_text_exact(index_backup))
        session_index_restored = True

    meta_backup = session_meta_backup_path(backup_path)
    if meta_backup.exists():
        for item in json.loads(read_text(meta_backup)):
            raw_path = Path(item["path"])
            path = raw_path if raw_path.is_absolute() else paths.codex_home / raw_path
            if not path.exists():
                continue
            # 只恢复首行 session_meta，后面的对话内容保持原文件不动。
            replace_first_line(path, str(item["first_line"]))
            session_files_restored += 1

    return {
        "session_index_restored": session_index_restored,
        "session_files_restored": session_files_restored,
        "duration_ms": elapsed_ms(started_at),
    }


def rebuild_session_index(paths: Paths, conn: sqlite3.Connection) -> dict[str, int]:
    started_at = time.monotonic()
    existing_entries = read_session_index(paths)
    columns = get_thread_columns(conn)
    select_parts = ["id"]
    if "title" in columns:
        select_parts.append("title")
    if "updated_at" in columns:
        select_parts.append("updated_at")
    where_sql = "WHERE archived = 0" if "archived" in columns else ""
    db_rows = conn.execute(
        f"""
        SELECT {", ".join(select_parts)}
        FROM threads
        {where_sql}
        ORDER BY id ASC
        """
    ).fetchall()
    db_ids = {str(row["id"]) for row in db_rows}
    existing_ids = set(existing_entries)

    merged: list[dict[str, str]] = []
    for row in db_rows:
        thread_id = str(row["id"])
        existing_entry = existing_entries.get(thread_id)
        title = str(row["title"]) if "title" in columns and row["title"] else thread_id
        updated_at = int(row["updated_at"]) if "updated_at" in columns and row["updated_at"] else 0
        merged.append(
            {
                "id": thread_id,
                "thread_name": str((existing_entry or {}).get("thread_name") or title),
                "updated_at": iso_utc_from_unix(updated_at),
            }
        )

    for thread_id, entry in existing_entries.items():
        if thread_id not in db_ids:
            merged.append(entry)

    merged.sort(key=lambda item: (parse_index_timestamp(item["updated_at"]), item["id"]))
    write_session_index(paths, merged)

    return {
        "rewritten_index_entries": len(merged),
        "missing_session_index_entries_before": len(db_ids - existing_ids),
        "preserved_index_only_entries": len(existing_ids - db_ids),
        "duration_ms": elapsed_ms(started_at),
    }


def sync_session_records(paths: Paths, current_provider: str, current_model: str | None) -> dict[str, object]:
    started_at = time.monotonic()
    before_records = scan_session_records(paths)
    updated_session_files = 0

    for record in before_records:
        model_matches = current_model is None or record.model == current_model
        if record.model_provider == current_provider and model_matches:
            continue

        text = read_text_exact(record.path)
        first_line, ending, remainder = split_first_line(text)
        item = json.loads(first_line)
        payload = item.get("payload")
        if not isinstance(payload, dict):
            continue

        payload["model_provider"] = current_provider
        if current_model:
            payload["model"] = current_model
        new_first_line = json.dumps(item, ensure_ascii=False, separators=(",", ":"))
        if ending:
            new_text = new_first_line + ending + remainder
        else:
            new_text = new_first_line
        write_text_exact(record.path, new_text)
        updated_session_files += 1

    after_records = scan_session_records(paths)
    return {
        "updated_session_files": updated_session_files,
        "session_before_counts": counts_to_rows(
            ordered_counts([record.model_provider for record in before_records])
        ),
        "session_after_counts": counts_to_rows(
            ordered_counts([record.model_provider for record in after_records])
        ),
        "session_before_model_counts": model_counts_to_rows(
            ordered_counts([record.model or "(empty)" for record in before_records])
        ),
        "session_after_model_counts": model_counts_to_rows(
            ordered_counts([record.model or "(empty)" for record in after_records])
        ),
        "duration_ms": elapsed_ms(started_at),
    }


def is_locked_error(exc: sqlite3.OperationalError) -> bool:
    message = str(exc).lower()
    return (
        "database is locked" in message
        or "database table is locked" in message
        or "database is busy" in message
        or "destination database is in use" in message
    )


def checkpoint(conn: sqlite3.Connection, mode: str = SYNC_CHECKPOINT_MODE) -> tuple[int, int, int]:
    row = conn.execute(f"PRAGMA wal_checkpoint({mode})").fetchone()
    return int(row[0]), int(row[1]), int(row[2])


def update_provider_assignments(
    paths: Paths,
    current_provider: str,
    current_model: str | None,
) -> dict[str, object]:
    started_at = time.monotonic()
    last_error: sqlite3.OperationalError | None = None

    for attempt in range(1, WRITE_LOCK_RETRY_LIMIT + 1):
        try:
            with connect_db(
                paths.db_path,
                readonly=False,
                timeout_seconds=WRITE_OPERATION_TIMEOUT_SECONDS,
            ) as conn:
                # 显式拿写锁，把等待控制在我们自己的重试节奏里。
                conn.execute("BEGIN IMMEDIATE")
                columns = get_thread_columns(conn)
                before_counts = query_provider_counts(conn)
                before_model_counts = query_model_counts(conn) if "model" in columns else OrderedDict()
                set_parts = ["model_provider = ?"]
                set_params = [current_provider]
                where_parts = ["model_provider IS NULL OR model_provider <> ?"]
                where_params = [current_provider]
                synced_fields = ["model_provider"]

                if "model" in columns and current_model:
                    set_parts.append("model = ?")
                    set_params.append(current_model)
                    where_parts.append("model IS NULL OR model <> ?")
                    where_params.append(current_model)
                    synced_fields.append("model")

                set_sql = ", ".join(set_parts)
                where_sql = " OR ".join(f"({part})" for part in where_parts)
                updated_rows = conn.execute(
                    f"UPDATE threads SET {set_sql} WHERE {where_sql}",
                    (*set_params, *where_params),
                ).rowcount
                conn.commit()
                after_counts = query_provider_counts(conn)
                after_model_counts = query_model_counts(conn) if "model" in columns else OrderedDict()
                checkpoint_result = checkpoint(conn)

            return {
                "attempts": attempt,
                "lock_wait_ms": elapsed_ms(started_at),
                "synced_fields": synced_fields,
                "updated_rows": updated_rows,
                "before_counts": counts_to_rows(before_counts),
                "after_counts": counts_to_rows(after_counts),
                "before_model_counts": model_counts_to_rows(before_model_counts),
                "after_model_counts": model_counts_to_rows(after_model_counts),
                "checkpoint": {
                    "mode": SYNC_CHECKPOINT_MODE,
                    "busy": checkpoint_result[0],
                    "log_frames": checkpoint_result[1],
                    "checkpointed_frames": checkpoint_result[2],
                },
            }
        except sqlite3.OperationalError as exc:
            if not is_locked_error(exc):
                raise
            last_error = exc
            if attempt >= WRITE_LOCK_RETRY_LIMIT:
                waited_seconds = (time.monotonic() - started_at)
                raise RuntimeError(
                    "Codex 当前正在写入本地历史数据库，"
                    f"已等待 {waited_seconds:.1f} 秒仍未拿到写锁。"
                    "保持 Codex 开着也可以同步，但请等当前回复、工具调用或自动保存结束后再试一次。"
                ) from exc
            time.sleep(WRITE_LOCK_RETRY_DELAY_SECONDS)

    raise RuntimeError("Database write lock retry loop ended unexpectedly.") from last_error


def restore_database_with_retry(paths: Paths, chosen_backup: Path) -> dict[str, object]:
    started_at = time.monotonic()
    last_error: sqlite3.OperationalError | None = None

    for attempt in range(1, WRITE_LOCK_RETRY_LIMIT + 1):
        try:
            with connect_db(chosen_backup, readonly=True) as source, connect_db(
                paths.db_path,
                readonly=False,
                timeout_seconds=WRITE_OPERATION_TIMEOUT_SECONDS,
            ) as target:
                # SQLite 在整库 backup 到目标库时会自己申请所需锁；
                # 这里直接尝试 restore，失败后统一按“数据库正忙”重试即可。
                source.backup(target)
                checkpoint_result = checkpoint(target)

            return {
                "attempts": attempt,
                "lock_wait_ms": elapsed_ms(started_at),
                "checkpoint": {
                    "mode": SYNC_CHECKPOINT_MODE,
                    "busy": checkpoint_result[0],
                    "log_frames": checkpoint_result[1],
                    "checkpointed_frames": checkpoint_result[2],
                },
            }
        except sqlite3.OperationalError as exc:
            if not is_locked_error(exc):
                raise
            last_error = exc
            if attempt >= WRITE_LOCK_RETRY_LIMIT:
                waited_seconds = (time.monotonic() - started_at)
                raise RuntimeError(
                    "Codex 当前正在写入本地历史数据库，"
                    f"已等待 {waited_seconds:.1f} 秒仍无法完成还原。"
                    "请等当前回复、工具调用或自动保存结束后再试一次。"
                ) from exc
            time.sleep(WRITE_LOCK_RETRY_DELAY_SECONDS)

    raise RuntimeError("Database restore retry loop ended unexpectedly.") from last_error


def get_status(paths: Paths) -> dict[str, object]:
    ensure_environment(paths)
    config_text = read_text(paths.config_path)
    current_provider = parse_current_provider(config_text)
    current_model = parse_current_model(config_text)
    session_records = scan_session_records(paths)
    session_provider_counts = ordered_counts([record.model_provider for record in session_records])
    session_model_counts = ordered_counts([record.model or "(empty)" for record in session_records])
    session_movable_ids = {
        record.thread_id
        for record in session_records
        if record.model_provider != current_provider
        or (current_model is not None and record.model != current_model)
    }
    should_check_index = paths.session_index_path.exists() or paths.sessions_dir.exists()
    index_entries = read_session_index(paths)

    with connect_db(paths.db_path, readonly=True) as conn:
        columns = get_thread_columns(conn)
        counts = query_provider_counts(conn)
        model_counts = query_model_counts(conn) if "model" in columns else OrderedDict()
        provider_model_counts = query_provider_model_counts(conn) if "model" in columns else []
        cwd_counts = query_cwd_counts(conn) if "cwd" in columns else []
        total_threads = int(conn.execute("SELECT COUNT(*) FROM threads").fetchone()[0])
        provider_movable = count_mismatched(conn, "model_provider", current_provider)
        model_movable = count_mismatched(conn, "model", current_model) if "model" in columns else None
        where_parts = ["model_provider IS NULL OR model_provider <> ?"]
        params: list[str] = [current_provider]
        if "model" in columns and current_model:
            where_parts.append("model IS NULL OR model <> ?")
            params.append(current_model)
        where_sql = " OR ".join(f"({part})" for part in where_parts)
        db_movable_ids = {str(row["id"]) for row in conn.execute(f"SELECT id FROM threads WHERE {where_sql}", params)}
        db_thread_query = "SELECT id FROM threads WHERE archived = 0" if "archived" in columns else "SELECT id FROM threads"
        db_thread_ids = {str(row["id"]) for row in conn.execute(db_thread_query)}
        missing_index_ids = db_thread_ids - set(index_entries) if should_check_index else set()
        sync_candidate_ids = db_movable_ids | session_movable_ids | missing_index_ids

    return {
        "codex_home": str(paths.codex_home),
        "config_path": str(paths.config_path),
        "db_path": str(paths.db_path),
        "session_index_path": str(paths.session_index_path),
        "sessions_dir": str(paths.sessions_dir),
        "backup_dir": str(paths.backup_dir),
        "current_provider": current_provider,
        "current_model": current_model,
        "total_threads": total_threads,
        "movable_threads": len(sync_candidate_ids),
        "provider_movable_threads": provider_movable,
        "model_movable_threads": model_movable,
        "movable_database_threads": len(db_movable_ids),
        "movable_session_threads": len(session_movable_ids),
        "missing_session_index_entries": len(missing_index_ids),
        "indexed_threads": len(index_entries),
        "session_file_count": len(session_records),
        "provider_counts": counts_to_rows(counts),
        "model_counts": model_counts_to_rows(model_counts),
        "provider_model_counts": provider_model_counts,
        "cwd_counts": cwd_counts,
        "session_provider_counts": counts_to_rows(session_provider_counts),
        "session_model_counts": model_counts_to_rows(session_model_counts),
        "backups": list_backups(paths),
    }


def make_backup(paths: Paths, label: str) -> Path:
    ensure_environment(paths)
    paths.backup_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_path = paths.backup_dir / f"state_5.sqlite.{label}.{timestamp}.bak"
    with connect_db(paths.db_path, readonly=True) as source, connect_db(backup_path, readonly=False) as target:
        source.backup(target)
    snapshot_metadata(paths, backup_path)
    backup_path.touch()
    return backup_path


def sync_to_current_provider(paths: Paths) -> dict[str, object]:
    total_started_at = time.monotonic()
    status_before = get_status(paths)
    current_provider = str(status_before["current_provider"])
    raw_current_model = status_before.get("current_model")
    current_model = str(raw_current_model) if raw_current_model else None

    backup_started_at = time.monotonic()
    backup_path = make_backup(paths, "pre-sync")
    backup_duration_ms = elapsed_ms(backup_started_at)

    db_summary = update_provider_assignments(paths, current_provider, current_model)
    session_summary = sync_session_records(paths, current_provider, current_model)

    with connect_db(paths.db_path, readonly=True) as conn:
        index_summary = rebuild_session_index(paths, conn)

    status_after = get_status(paths)
    return {
        "action": "sync",
        "current_provider": current_provider,
        "current_model": current_model,
        "synced_fields": db_summary["synced_fields"],
        "updated_rows": db_summary["updated_rows"],
        "updated_session_files": session_summary["updated_session_files"],
        "provider_movable_threads": status_before["provider_movable_threads"],
        "model_movable_threads": status_before["model_movable_threads"],
        "backup_path": str(backup_path),
        "before_counts": db_summary["before_counts"],
        "after_counts": db_summary["after_counts"],
        "before_model_counts": db_summary["before_model_counts"],
        "after_model_counts": db_summary["after_model_counts"],
        "session_before_counts": session_summary["session_before_counts"],
        "session_after_counts": session_summary["session_after_counts"],
        "session_before_model_counts": session_summary["session_before_model_counts"],
        "session_after_model_counts": session_summary["session_after_model_counts"],
        "checkpoint": db_summary["checkpoint"],
        "lock_wait_ms": db_summary["lock_wait_ms"],
        "lock_attempts": db_summary["attempts"],
        "rewritten_index_entries": index_summary["rewritten_index_entries"],
        "missing_session_index_entries_before": index_summary["missing_session_index_entries_before"],
        "preserved_index_only_entries": index_summary["preserved_index_only_entries"],
        "timing": {
            "backup_ms": backup_duration_ms,
            "database_ms": db_summary["lock_wait_ms"],
            "session_ms": session_summary["duration_ms"],
            "index_ms": index_summary["duration_ms"],
            "total_ms": elapsed_ms(total_started_at),
        },
        "status": status_after,
    }


def resolve_backup(paths: Paths, requested_path: str | None) -> Path:
    if requested_path:
        backup = Path(requested_path).expanduser()
    else:
        backups = list_backups(paths, limit=1)
        if not backups:
            raise RuntimeError("No backup files were found.")
        backup = Path(backups[0]["path"])
    if not backup.exists():
        raise RuntimeError(f"Backup file does not exist: {backup}")
    return backup


def restore_backup(paths: Paths, backup_path: str | None) -> dict[str, object]:
    total_started_at = time.monotonic()
    ensure_environment(paths)
    chosen_backup = resolve_backup(paths, backup_path)

    backup_started_at = time.monotonic()
    restore_snapshot = make_backup(paths, "pre-restore")
    backup_duration_ms = elapsed_ms(backup_started_at)

    restore_db_started_at = time.monotonic()
    restore_db_summary = restore_database_with_retry(paths, chosen_backup)
    restore_db_duration_ms = elapsed_ms(restore_db_started_at)

    restore_summary = restore_metadata(paths, chosen_backup)
    # 恢复后统一重建索引，让数据库与侧边栏索引重新对齐。
    with connect_db(paths.db_path, readonly=True) as conn:
        index_summary = rebuild_session_index(paths, conn)

    status_after = get_status(paths)
    return {
        "action": "restore",
        "restored_from": str(chosen_backup),
        "safety_backup": str(restore_snapshot),
        "metadata_restore": restore_summary,
        "checkpoint": restore_db_summary["checkpoint"],
        "lock_wait_ms": restore_db_summary["lock_wait_ms"],
        "lock_attempts": restore_db_summary["attempts"],
        "rewritten_index_entries": index_summary["rewritten_index_entries"],
        "timing": {
            "backup_ms": backup_duration_ms,
            "database_ms": restore_db_duration_ms,
            "metadata_ms": restore_summary["duration_ms"],
            "index_ms": index_summary["duration_ms"],
            "total_ms": elapsed_ms(total_started_at),
        },
        "status": status_after,
    }


def to_json(payload: dict[str, object]) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2)


def main() -> int:
    parser = argparse.ArgumentParser(description="Codex history sync helper")
    parser.add_argument("--codex-home", help="Override Codex home directory")
    parser.add_argument("--json", action="store_true", help="Emit JSON output")

    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status", help="Show current provider/thread status")
    subparsers.add_parser("sync", help="Move all thread providers to the current provider")
    restore_parser = subparsers.add_parser("restore", help="Restore from a backup")
    restore_parser.add_argument("--backup", help="Backup file path; newest backup is used when omitted")
    subparsers.add_parser("backup", help="Create a manual backup")

    args = parser.parse_args()
    paths = resolve_paths(args.codex_home)

    try:
        if args.command == "status":
            payload = get_status(paths)
        elif args.command == "sync":
            payload = sync_to_current_provider(paths)
        elif args.command == "restore":
            payload = restore_backup(paths, args.backup)
        elif args.command == "backup":
            ensure_environment(paths)
            backup_started_at = time.monotonic()
            payload = {
                "action": "backup",
                "backup_path": str(make_backup(paths, "manual")),
                "timing": {"total_ms": elapsed_ms(backup_started_at)},
            }
        else:
            raise RuntimeError(f"Unsupported command: {args.command}")
    except Exception as exc:
        error_payload = {"ok": False, "error": str(exc)}
        if args.json:
            print(to_json(error_payload))
        else:
            print(error_payload["error"])
        return 1

    if isinstance(payload, dict):
        payload["ok"] = True

    if args.json:
        print(to_json(payload))
    else:
        print(payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
