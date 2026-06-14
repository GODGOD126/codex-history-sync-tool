from __future__ import annotations

import sqlite3
import tempfile
import unittest
import json
from contextlib import closing
from pathlib import Path

from sync_backend import get_status, make_backup, resolve_paths, restore_backup, sync_to_current_provider


def write_config(codex_home, provider: str = "new_provider", model: str = "gpt-new") -> None:
    (codex_home / "config.toml").write_text(
        f'model_provider = "{provider}"\nmodel = "{model}"\n',
        encoding="utf-8",
    )


def create_threads_db(codex_home, *, with_model: bool = True) -> None:
    conn = sqlite3.connect(codex_home / "state_5.sqlite")
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

    def test_resolve_paths_prefers_modern_sqlite_state_directory(self) -> None:
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
