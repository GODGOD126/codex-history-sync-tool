from __future__ import annotations

import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from sync_backend import (
    backup_manifest_path,
    doctor_environment,
    get_status,
    make_backup,
    preview_restore_backup,
    read_backup_manifest,
    resolve_paths,
    restore_backup,
    session_meta_backup_path,
    sync_to_current_provider,
    verify_backup,
    write_backup_manifest,
)


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


def create_threads_db_with_cwd(codex_home) -> None:
    conn = sqlite3.connect(codex_home / "state_5.sqlite")
    conn.execute(
        "CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, model TEXT, cwd TEXT NOT NULL)"
    )
    conn.executemany(
        "INSERT INTO threads (id, model_provider, model, cwd) VALUES (?, ?, ?, ?)",
        [
            ("project-a-old", "old_provider", "gpt-old", r"\\?\C:\project-a"),
            ("project-a-current", "new_provider", "gpt-new", r"\\?\C:\project-a"),
            ("project-b-old", "old_provider", "gpt-old", r"\\?\C:\project-b"),
        ],
    )
    conn.commit()
    conn.close()


class SyncBackendTests(unittest.TestCase):
    def test_missing_provider_in_config_defaults_to_openai(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config_without_provider(codex_home, model="gpt-new")
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))

            status = get_status(paths)

            self.assertEqual(status["current_provider"], "openai")
            self.assertEqual(status["current_model"], "gpt-new")

    def test_dry_run_reports_changes_without_writing_database(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))

            result = sync_to_current_provider(paths, dry_run=True)

            self.assertEqual(result["action"], "sync-preview")
            self.assertTrue(result["dry_run"])
            self.assertEqual(result["would_update_database_threads"], 2)
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

    def test_sync_can_be_limited_to_one_cwd(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db_with_cwd(codex_home)
            paths = resolve_paths(str(codex_home))

            status = get_status(paths, cwd_filter=r"C:\project-a")
            result = sync_to_current_provider(paths, cwd_filter=r"C:\project-a")

            self.assertEqual(status["scoped_threads"], 2)
            self.assertEqual(result["updated_rows"], 1)
            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute(
                    "SELECT id, model_provider, model FROM threads ORDER BY id"
                ).fetchall()

            self.assertEqual(
                rows,
                [
                    ("project-a-current", "new_provider", "gpt-new"),
                    ("project-a-old", "new_provider", "gpt-new"),
                    ("project-b-old", "old_provider", "gpt-old"),
                ],
            )

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

            self.assertTrue(backup_manifest_path(backup_path).exists())

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

    def test_restore_backup_ignores_metadata_paths_outside_codex_home(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            codex_home = root / "codex"
            codex_home.mkdir()
            outside_file = root / "outside.jsonl"
            outside_file.write_text("original\nbody\n", encoding="utf-8")
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))
            backup_path = make_backup(paths, "manual")
            session_meta_backup_path(backup_path).write_text(
                json.dumps(
                    [{"path": str(outside_file), "first_line": "tampered"}],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            write_backup_manifest(paths, backup_path, "manual")

            restore_backup(paths, str(backup_path))

            self.assertEqual(outside_file.read_text(encoding="utf-8"), "original\nbody\n")

    def test_restore_preview_does_not_write_database(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))
            backup_path = make_backup(paths, "manual")
            sync_to_current_provider(paths)

            result = preview_restore_backup(paths, str(backup_path))

            self.assertEqual(result["action"], "restore-preview")
            self.assertEqual(result["backup_thread_count"], 3)
            self.assertEqual(result["current_thread_count"], 3)
            self.assertTrue(result["verification"]["verified"])
            self.assertTrue(result["comparison"]["provider_counts_will_change"])
            self.assertEqual(result["comparison"]["thread_count_delta"], 0)
            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute(
                    "SELECT model_provider, model, COUNT(*) FROM threads GROUP BY model_provider, model"
                ).fetchall()

            self.assertEqual(rows, [("new_provider", "gpt-new", 3)])

    def test_doctor_reports_ready_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))

            result = doctor_environment(paths)

            self.assertTrue(result["ok"])
            self.assertEqual(result["current_provider"], "new_provider")
            self.assertEqual(result["current_model"], "gpt-new")
            self.assertEqual(result["thread_count"], 3)

    def test_manifest_can_be_read_for_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))
            backup_path = make_backup(paths, "manual")

            manifest = read_backup_manifest(backup_path)

            self.assertIsNotNone(manifest)
            self.assertEqual(manifest["format"], "codex-history-sync-backup-manifest-v1")
            self.assertEqual(manifest["thread_count"], 3)

    def test_verify_backup_passes_for_new_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))
            backup_path = make_backup(paths, "manual")

            result = verify_backup(paths, str(backup_path))

            self.assertTrue(result["verified"])
            self.assertTrue(all(item["ok"] for item in result["checks"]))

    def test_verify_backup_fails_when_database_is_modified(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))
            backup_path = make_backup(paths, "manual")

            with backup_path.open("ab") as handle:
                handle.write(b"tampered")

            result = verify_backup(paths, str(backup_path))

            self.assertFalse(result["verified"])
            failed = {item["name"] for item in result["checks"] if not item["ok"]}
            self.assertIn("database", failed)

    def test_verify_backup_fails_without_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))
            backup_path = make_backup(paths, "manual")
            backup_manifest_path(backup_path).unlink()

            result = verify_backup(paths, str(backup_path))

            self.assertFalse(result["verified"])
            self.assertFalse(result["manifest_exists"])

    def test_restore_is_blocked_when_backup_verification_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            codex_home = Path(temp_dir)
            write_config(codex_home)
            create_threads_db(codex_home, with_model=True)
            paths = resolve_paths(str(codex_home))
            backup_path = make_backup(paths, "manual")
            sync_to_current_provider(paths)

            with backup_path.open("ab") as handle:
                handle.write(b"tampered")

            with self.assertRaisesRegex(RuntimeError, "Backup verification failed"):
                restore_backup(paths, str(backup_path))

            with closing(sqlite3.connect(codex_home / "state_5.sqlite")) as conn:
                rows = conn.execute(
                    "SELECT model_provider, model, COUNT(*) FROM threads GROUP BY model_provider, model"
                ).fetchall()

            self.assertEqual(rows, [("new_provider", "gpt-new", 3)])


if __name__ == "__main__":
    unittest.main()
