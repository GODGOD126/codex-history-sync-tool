from __future__ import annotations

import json
import errno
import os
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest import mock

from sync_backend import (
    get_status,
    make_backup,
    replace_file_with_retry,
    resolve_paths,
    restore_backup,
    sync_to_current_provider,
)


def write_config(
    codex_home: Path,
    provider: str | None = "new_provider",
    model: str | None = "gpt-new",
) -> None:
    lines = []
    if provider is not None:
        lines.append(f'model_provider = "{provider}"')
    if model is not None:
        lines.append(f'model = "{model}"')
    (codex_home / "config.toml").write_text("\n".join(lines) + "\n", encoding="utf-8")


def create_threads_db(
    codex_home: Path,
    *,
    with_model: bool = True,
    db_path: Path | None = None,
) -> Path:
    chosen_db_path = db_path or codex_home / "state_5.sqlite"
    chosen_db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(chosen_db_path)
    if with_model:
        conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, model TEXT)")
        conn.executemany(
            "INSERT INTO threads (id, model_provider, model) VALUES (?, ?, ?)",
            [
                ("old-provider-old-model", "old_provider", "gpt-old"),
                ("new-provider-old-model", "new_provider", "gpt-old"),
                ("already-current", "new_provider", "gpt-new"),
            ],
        )
    else:
        conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL)")
        conn.executemany(
            "INSERT INTO threads (id, model_provider) VALUES (?, ?)",
            [
                ("old-provider", "old_provider"),
                ("already-current", "new_provider"),
            ],
        )
    conn.commit()
    conn.close()
    return chosen_db_path


def write_session_file(codex_home: Path, thread_id: str, provider: str, model: str | None = None) -> Path:
    folder = codex_home / "sessions" / "2026" / "06" / "14"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"rollout-2026-06-14T00-00-00-{thread_id}.jsonl"
    payload = {
        "timestamp": "2026-06-14T00:00:00Z",
        "type": "session_meta",
        "payload": {
            "id": thread_id,
            "model_provider": provider,
        },
    }
    if model is not None:
        payload["payload"]["model"] = model
    path.write_text(json.dumps(payload, separators=(",", ":")) + "\n{}\n", encoding="utf-8")
    return path


class SyncBackendTests(unittest.TestCase):
    def test_replace_file_with_retry_retries_busy_error_on_unix(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "source.tmp"
            target = Path(temp_dir) / "target.txt"
            source.write_text("content", encoding="utf-8")
            target.write_text("old", encoding="utf-8")
            original_replace = Path.replace

            def flaky_replace(path: Path, destination: Path) -> None:
                attempts = getattr(flaky_replace, "attempts", 0) + 1
                flaky_replace.attempts = attempts
                if attempts <= 2:
                    raise OSError(errno.EBUSY, "Resource busy")
                original_replace(path, destination)

            with mock.patch.object(Path, "replace", flaky_replace):
                replace_file_with_retry(source, target)

            self.assertEqual(flaky_replace.attempts, 3)
            self.assertEqual(target.read_text(encoding="utf-8"), "content")

    def test_replace_file_with_retry_reraises_unrelated_os_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            source = Path(temp_dir) / "source.tmp"
            target = Path(temp_dir) / "target.txt"
            source.write_text("content", encoding="utf-8")

            with mock.patch.object(
                Path,
                "replace",
                mock.Mock(side_effect=OSError(errno.ENOENT, "No such file")),
            ):
                with self.assertRaises(OSError):
                    replace_file_with_retry(source, target)

    def test_sync_updates_provider_and_model_for_newer_codex_schema(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))

            status = get_status(paths)

            self.assertEqual(status["provider_movable_threads"], 1)
            self.assertEqual(status["model_movable_threads"], 2)
            self.assertEqual(status["movable_threads"], 2)

            result = sync_to_current_provider(paths)

            self.assertEqual(result["synced_fields"], ["model_provider", "model"])
            self.assertEqual(result["updated_rows"], 2)

            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute(
                    "SELECT model_provider, model, COUNT(*) FROM threads GROUP BY model_provider, model"
                ).fetchall()

            self.assertEqual(rows, [("new_provider", "gpt-new", 3)])

    def test_resolve_paths_uses_modern_sqlite_state_directory_when_it_is_the_only_database(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            sqlite_dir = codex_home / "sqlite"
            sqlite_dir.mkdir()
            conn = sqlite3.connect(sqlite_dir / "state_5.sqlite")
            conn.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, model TEXT)")
            conn.execute(
                "INSERT INTO threads (id, model_provider, model) VALUES (?, ?, ?)",
                ("modern-db-thread", "old_provider", "gpt-old"),
            )
            conn.commit()
            conn.close()
            paths = resolve_paths(str(codex_home))

            self.assertEqual(paths.db_path, sqlite_dir / "state_5.sqlite")

            status = get_status(paths)

            self.assertEqual(status["movable_database_threads"], 1)

            result = sync_to_current_provider(paths)

            self.assertEqual(result["updated_rows"], 1)
            with closing(sqlite3.connect(sqlite_dir / "state_5.sqlite")) as conn:
                rows = conn.execute("SELECT model_provider, model FROM threads").fetchall()

            self.assertEqual(rows, [("new_provider", "gpt-new")])

    def test_resolve_paths_prefers_root_database_when_it_has_newer_activity(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            root_db = create_threads_db(codex_home)
            modern_db = create_threads_db(
                codex_home,
                db_path=codex_home / "sqlite" / "state_5.sqlite",
            )
            os.utime(modern_db, ns=(1_000_000_000, 1_000_000_000))
            os.utime(root_db, ns=(2_000_000_000, 2_000_000_000))

            paths = resolve_paths(str(codex_home))

            self.assertEqual(paths.db_path, root_db)

    def test_resolve_paths_prefers_modern_database_when_its_wal_has_newer_activity(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            root_db = create_threads_db(codex_home)
            modern_db = create_threads_db(
                codex_home,
                db_path=codex_home / "sqlite" / "state_5.sqlite",
            )
            modern_wal = Path(f"{modern_db}-wal")
            modern_wal.touch()
            os.utime(root_db, ns=(2_000_000_000, 2_000_000_000))
            os.utime(modern_db, ns=(1_000_000_000, 1_000_000_000))
            os.utime(modern_wal, ns=(3_000_000_000, 3_000_000_000))

            paths = resolve_paths(str(codex_home))

            self.assertEqual(paths.db_path, modern_db)

    def test_resolve_paths_prefers_root_database_when_activity_is_tied(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            root_db = create_threads_db(codex_home)
            modern_db = create_threads_db(
                codex_home,
                db_path=codex_home / "sqlite" / "state_5.sqlite",
            )
            os.utime(root_db, ns=(2_000_000_000, 2_000_000_000))
            os.utime(modern_db, ns=(2_000_000_000, 2_000_000_000))

            paths = resolve_paths(str(codex_home))

            self.assertEqual(paths.db_path, root_db)

    def test_missing_model_provider_uses_safe_openai_default(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home, provider=None)
            create_threads_db(codex_home)

            status = get_status(resolve_paths(str(codex_home)))

            self.assertEqual(status["current_provider"], "openai")

    def test_manual_provider_and_model_override_are_used_consistently(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home)
            paths = resolve_paths(str(codex_home))

            result = sync_to_current_provider(
                paths,
                provider_override="manual_provider",
                model_override="gpt-manual",
            )

            self.assertEqual(result["current_provider"], "manual_provider")
            self.assertEqual(result["current_model"], "gpt-manual")
            self.assertEqual(result["status"]["current_provider"], "manual_provider")
            self.assertEqual(result["status"]["current_model"], "gpt-manual")
            self.assertEqual(result["status"]["movable_threads"], 0)

    def test_sync_without_config_model_preserves_existing_models(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home, model=None)
            create_threads_db(codex_home)
            paths = resolve_paths(str(codex_home))

            result = sync_to_current_provider(paths)

            self.assertEqual(result["synced_fields"], ["model_provider"])
            self.assertEqual(result["updated_rows"], 1)
            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute(
                    "SELECT id, model_provider, model FROM threads ORDER BY id"
                ).fetchall()
            self.assertEqual(
                rows,
                [
                    ("already-current", "new_provider", "gpt-new"),
                    ("new-provider-old-model", "new_provider", "gpt-old"),
                    ("old-provider-old-model", "new_provider", "gpt-old"),
                ],
            )

    def test_session_file_without_model_is_current_when_provider_matches(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            write_session_file(
                codex_home,
                "019ec664-76f4-7bc3-95f4-b6204be9ae52",
                "new_provider",
            )
            paths = resolve_paths(str(codex_home))

            status = get_status(paths)

            self.assertEqual(status["movable_session_threads"], 0)

    def test_sync_still_supports_legacy_schema_without_model_column(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=False)
            paths = resolve_paths(str(codex_home))

            status = get_status(paths)

            self.assertEqual(status["provider_movable_threads"], 1)
            self.assertIsNone(status["model_movable_threads"])
            self.assertEqual(status["movable_threads"], 1)

            result = sync_to_current_provider(paths)

            self.assertEqual(result["synced_fields"], ["model_provider"])
            self.assertEqual(result["updated_rows"], 1)

            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute("SELECT model_provider, COUNT(*) FROM threads GROUP BY model_provider").fetchall()

            self.assertEqual(rows, [("new_provider", 2)])

    def test_restore_backup_restores_previous_database_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))
            backup_path = make_backup(paths, "manual")

            sync_to_current_provider(paths)
            result = restore_backup(paths, str(backup_path))

            self.assertEqual(result["restored_from"], str(backup_path))
            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute(
                    "SELECT model_provider, model, COUNT(*) FROM threads GROUP BY model_provider, model ORDER BY model_provider, model"
                ).fetchall()

            self.assertEqual(
                rows,
                [
                    ("new_provider", "gpt-new", 1),
                    ("new_provider", "gpt-old", 1),
                    ("old_provider", "gpt-old", 1),
                ],
            )


if __name__ == "__main__":
    unittest.main()
