from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

from sync_backend import FileBusyError, get_status, make_backup, resolve_paths, restore_backup, sync_to_current_provider


def write_config(codex_home, provider: str = "new_provider", model: str = "gpt-new") -> None:
    (codex_home / "config.toml").write_text(
        f'model_provider = "{provider}"\nmodel = "{model}"\n',
        encoding="utf-8",
    )


def write_config_without_provider(codex_home, model: str = "gpt-new") -> None:
    (codex_home / "config.toml").write_text(
        f'model = "{model}"\n',
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


def create_session_file(
    codex_home: Path,
    *,
    thread_id: str,
    model_provider: str,
    model: str | None,
    slug: str,
) -> Path:
    session_dir = codex_home / "sessions" / "2026" / "06" / "15"
    session_dir.mkdir(parents=True, exist_ok=True)
    session_path = session_dir / f"rollout-{slug}-{thread_id}.jsonl"
    meta = {
        "type": "session_meta",
        "payload": {
            "id": thread_id,
            "model_provider": model_provider,
        },
    }
    if model is not None:
        meta["payload"]["model"] = model
    session_path.write_text(
        f'{json.dumps(meta, ensure_ascii=False)}\n{{"type":"message"}}\n',
        encoding="utf-8",
    )
    return session_path


class SyncBackendTests(unittest.TestCase):
    def test_status_falls_back_to_openai_when_model_provider_is_omitted(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config_without_provider(codex_home, model="gpt-5.4")
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))

            status = get_status(paths)

            self.assertEqual(status["current_provider"], "openai")
            self.assertEqual(status["current_model"], "gpt-5.4")
            self.assertEqual(status["provider_movable_threads"], 3)
            self.assertEqual(status["model_movable_threads"], 3)
            self.assertEqual(status["movable_threads"], 3)

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

    def test_sync_skips_busy_session_files_and_keeps_other_updates(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home, provider="openai", model="gpt-5.4")
            create_threads_db(codex_home, with_model=True)
            locked_path = create_session_file(
                codex_home,
                thread_id="11111111-1111-1111-1111-111111111111",
                model_provider="custom",
                model="gpt-5.5",
                slug="2026-06-15T03-22-03",
            )
            updated_path = create_session_file(
                codex_home,
                thread_id="22222222-2222-2222-2222-222222222222",
                model_provider="custom",
                model="gpt-5.5",
                slug="2026-06-15T03-22-04",
            )
            paths = resolve_paths(str(codex_home))

            from sync_backend import write_text_exact as original_write_text_exact

            def flaky_write_text_exact(path: Path, text: str) -> None:
                if path == locked_path:
                    raise FileBusyError(path)
                original_write_text_exact(path, text)

            with patch("sync_backend.write_text_exact", side_effect=flaky_write_text_exact):
                result = sync_to_current_provider(paths)

            self.assertEqual(result["updated_session_files"], 1)
            self.assertEqual(result["skipped_busy_session_files"], 1)
            self.assertEqual(result["skipped_busy_session_paths"], [str(locked_path)])

            locked_meta = json.loads(locked_path.read_text(encoding="utf-8").splitlines()[0])
            updated_meta = json.loads(updated_path.read_text(encoding="utf-8").splitlines()[0])
            self.assertEqual(locked_meta["payload"]["model_provider"], "custom")
            self.assertEqual(locked_meta["payload"]["model"], "gpt-5.5")
            self.assertEqual(updated_meta["payload"]["model_provider"], "openai")
            self.assertEqual(updated_meta["payload"]["model"], "gpt-5.4")


if __name__ == "__main__":
    unittest.main()
