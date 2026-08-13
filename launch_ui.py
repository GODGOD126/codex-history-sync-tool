#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Codex 历史找回助手 - macOS 图形界面（Tkinter 移植版）

功能对应 Windows 版 launch_ui.ps1：
- 展示当前 provider/model 与历史线程归属
- 手动指定目标 Provider/Model 后一键同步
- 手动备份、打开备份目录、恢复选中或最新备份
- 创建/更新桌面启动入口
"""

from __future__ import annotations

import json
import queue
import shlex
import subprocess
import sys
import threading
from datetime import datetime
from pathlib import Path

import tkinter as tk
from tkinter import font as tkfont
from tkinter import messagebox, ttk

APP_TITLE = "Codex 历史找回助手"
TOOL_DIR = Path(__file__).resolve().parent
BACKEND_PATH = TOOL_DIR / "sync_backend.py"
DESKTOP_ENTRY_NAME = "Codex 历史找回助手.command"
POLL_INTERVAL_MS = 80


def run_backend(arguments: list[str]) -> dict[str, object]:
    """调用后端 sync_backend.py，返回解析后的 JSON 结果。"""
    if not BACKEND_PATH.exists():
        raise RuntimeError(f"缺少后端脚本: {BACKEND_PATH}")

    proc = subprocess.run(
        [sys.executable, str(BACKEND_PATH), "--json", *arguments],
        capture_output=True,
        text=True,
    )
    text = (proc.stdout or "").strip()
    if not text:
        raise RuntimeError((proc.stderr or "后端没有返回任何内容。").strip())
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"后端 JSON 解析失败。\n原始返回内容:\n{text}") from exc
    if proc.returncode != 0 or not payload.get("ok"):
        raise RuntimeError(str(payload.get("error") or text))
    return payload


class CodexSyncApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title(APP_TITLE)
        self.root.geometry("940x780")
        self.root.minsize(920, 740)
        self.root.configure(bg="#F6F8FB")

        self.latest_state: dict[str, object] | None = None
        self.backup_map: dict[str, str] = {}
        self.action_buttons: list[tk.Button] = []
        self.queue: queue.Queue = queue.Queue()

        self._build_ui()
        self.root.after(POLL_INTERVAL_MS, self._poll_queue)

        try:
            self._ensure_desktop_entry()
        except Exception as exc:
            self.log(f"初始化桌面入口失败: {exc}")

        self.refresh_state()

    # ------------------------------------------------------------------ UI 构建

    def _build_ui(self) -> None:
        default_family = tkfont.nametofont("TkDefaultFont").actual("family")
        bg = "#F6F8FB"

        main = tk.Frame(self.root, bg=bg)
        main.pack(fill="both", expand=True, padx=20, pady=16)
        main.columnconfigure(0, weight=1)

        header = tk.Label(
            main,
            text=APP_TITLE,
            font=(default_family, 18, "bold"),
            bg=bg,
            anchor="w",
        )
        header.grid(row=0, column=0, sticky="w")

        intro = tk.Label(
            main,
            text=(
                "用于把“换了 API / Provider / 登录方式后看不见的本地历史”重新挂回当前 Codex。"
                "Codex 开着也可以试，工具会等待数据库空闲。"
            ),
            font=(default_family, 10),
            fg="#4D5969",
            bg=bg,
            anchor="w",
            justify="left",
            wraplength=880,
        )
        intro.grid(row=1, column=0, sticky="we", pady=(2, 8))

        self.status_label = tk.Label(
            main,
            text="正在读取状态...",
            font=(default_family, 10, "bold"),
            fg="#1C54A0",
            bg=bg,
            anchor="w",
            justify="left",
            wraplength=880,
        )
        self.status_label.grid(row=2, column=0, sticky="we")

        self.progress = ttk.Progressbar(main, mode="indeterminate")
        self.progress.grid(row=3, column=0, sticky="we", pady=(6, 4))
        self.progress.grid_remove()

        info_rows = (
            ("provider", "当前账号/Provider:"),
            ("model", "当前模型:"),
            ("summary", "历史线程:"),
            ("repair", "待修复:"),
            ("path", "数据位置:"),
        )
        self.info_labels: dict[str, tk.Label] = {}
        for index, (key, _text) in enumerate(info_rows):
            label = tk.Label(main, text="", font=(default_family, 10), bg=bg, anchor="w", justify="left")
            label.grid(row=4 + index, column=0, sticky="we", pady=1)
            self.info_labels[key] = label

        override_info = tk.Label(
            main,
            text="手动指定目标 (留空则自动检测):",
            font=(default_family, 10),
            fg="#4D5969",
            bg=bg,
            anchor="w",
        )
        override_info.grid(row=9, column=0, sticky="w", pady=(6, 2))

        override_row = tk.Frame(main, bg=bg)
        override_row.grid(row=10, column=0, sticky="we", pady=(0, 8))
        tk.Label(override_row, text="Provider:", font=(default_family, 10), bg=bg).pack(side="left")
        self.provider_var = tk.StringVar()
        provider_entry = tk.Entry(override_row, textvariable=self.provider_var, width=24)
        provider_entry.pack(side="left", padx=(6, 18))
        tk.Label(override_row, text="Model:", font=(default_family, 10), bg=bg).pack(side="left")
        self.model_var = tk.StringVar()
        tk.Entry(override_row, textvariable=self.model_var, width=24).pack(side="left", padx=(6, 0))

        button_row = tk.Frame(main, bg=bg)
        button_row.grid(row=11, column=0, sticky="w", pady=(0, 10))
        self.refresh_button = self._make_button(button_row, "重新检查", self.refresh_state)
        self.sync_button = self._make_button(
            button_row,
            "开始找回历史",
            self.action_sync,
            accent=True,
        )
        self.backup_button = self._make_button(button_row, "先做备份", self.action_backup)
        self.open_backups_button = self._make_button(button_row, "打开备份", self.action_open_backups)
        self.desktop_button = self._make_button(button_row, "更新桌面入口", self.action_desktop_entry)

        panes = tk.Frame(main, bg=bg)
        panes.grid(row=12, column=0, sticky="nsew", pady=(0, 10))
        panes.columnconfigure(0, weight=1)
        panes.columnconfigure(1, weight=1)
        panes.rowconfigure(0, weight=1)
        main.rowconfigure(12, weight=1)

        history_box = ttk.LabelFrame(panes, text="历史归属", padding=8)
        history_box.grid(row=0, column=0, sticky="nsew", padx=(0, 8))
        history_box.columnconfigure(0, weight=1)
        history_box.rowconfigure(0, weight=1)

        self.providers_view = ttk.Treeview(
            history_box,
            columns=("provider", "count", "location", "status"),
            show="headings",
            height=6,
        )
        for column, title, width, anchor in (
            ("provider", "账号/Provider", 150, "w"),
            ("count", "数量", 60, "center"),
            ("location", "位置", 90, "center"),
            ("status", "状态", 55, "center"),
        ):
            self.providers_view.heading(column, text=title)
            self.providers_view.column(column, width=width, anchor=anchor)
        tree_scroll = ttk.Scrollbar(history_box, orient="vertical", command=self.providers_view.yview)
        self.providers_view.configure(yscrollcommand=tree_scroll.set)
        self.providers_view.grid(row=0, column=0, sticky="nsew")
        tree_scroll.grid(row=0, column=1, sticky="ns")

        backups_box = ttk.LabelFrame(panes, text="安全备份", padding=8)
        backups_box.grid(row=0, column=1, sticky="nsew", padx=(8, 0))
        backups_box.columnconfigure(0, weight=1)
        backups_box.rowconfigure(0, weight=1)

        self.backup_list = tk.Listbox(backups_box, height=6, selectmode="single")
        backup_scroll = tk.Scrollbar(backups_box, orient="vertical", command=self.backup_list.yview)
        self.backup_list.configure(yscrollcommand=backup_scroll.set)
        self.backup_list.grid(row=0, column=0, columnspan=2, sticky="nsew")
        backup_scroll.grid(row=0, column=2, sticky="ns")

        self.restore_button = self._make_button(
            backups_box,
            "恢复选中备份",
            self.action_restore_selected,
            pack=False,
        )
        self.restore_button.grid(row=1, column=0, sticky="w", pady=(8, 0))
        self.restore_latest_button = self._make_button(
            backups_box,
            "恢复最新备份",
            self.action_restore_latest,
            pack=False,
        )
        self.restore_latest_button.grid(row=1, column=1, sticky="w", pady=(8, 0), padx=(8, 0))

        log_frame = tk.Frame(main, bg=bg)
        log_frame.grid(row=13, column=0, sticky="nsew")
        log_frame.columnconfigure(0, weight=1)
        log_frame.rowconfigure(0, weight=1)
        self.log_box = tk.Text(log_frame, height=7, state="disabled", bg="white", wrap="word")
        log_scroll = tk.Scrollbar(log_frame, orient="vertical", command=self.log_box.yview)
        self.log_box.configure(yscrollcommand=log_scroll.set)
        self.log_box.grid(row=0, column=0, sticky="nsew")
        log_scroll.grid(row=0, column=1, sticky="ns")

    def _make_button(
        self,
        parent: tk.Widget,
        text: str,
        command,
        accent: bool = False,
        pack: bool = True,
    ) -> tk.Button:
        button = tk.Button(
            parent,
            text=text,
            command=command,
            padx=12,
            pady=4,
        )
        if accent:
            button.configure(
                bg="#205BB1",
                fg="white",
                activebackground="#1A4D99",
                activeforeground="white",
                relief="flat",
            )
        if pack:
            button.pack(side="left", padx=(0, 8))
        self.action_buttons.append(button)
        return button

    # ------------------------------------------------------------- 线程与队列

    def _poll_queue(self) -> None:
        try:
            while True:
                task = self.queue.get_nowait()
                task()
        except queue.Empty:
            pass
        self.root.after(POLL_INTERVAL_MS, self._poll_queue)

    def _submit(self, task) -> None:
        self.queue.put(task)

    def _run_async(self, arguments: list[str], on_success, on_error, action: str) -> None:
        def work() -> None:
            try:
                payload = run_backend(arguments)
            except Exception as exc:
                self._submit(lambda action=action, exc=exc: on_error(action, exc))
            else:
                self._submit(lambda payload=payload: on_success(payload))

        threading.Thread(target=work, daemon=True).start()

    # ------------------------------------------------------------------ 状态

    def set_busy(self, busy: bool, message: str = "") -> None:
        for button in self.action_buttons:
            button.configure(state="disabled" if busy else "normal")
        if busy:
            self.status_label.configure(text=message)
            self.progress.grid()
            self.progress.start(12)
        else:
            self.progress.stop()
            self.progress.grid_remove()
            if self.latest_state is not None:
                self.status_label.configure(text=self.friendly_status(self.latest_state))
            else:
                self.status_label.configure(text="准备就绪")

    def override_args(self, command: str) -> list[str]:
        arguments = [command]
        provider = self.provider_var.get().strip()
        model = self.model_var.get().strip()
        if provider:
            arguments += ["--provider", provider]
        if model:
            arguments += ["--model", model]
        return arguments

    def friendly_status(self, status: dict[str, object]) -> str:
        if int(status.get("movable_threads") or 0) <= 0:
            return "一切正常：历史记录已经挂到当前账号/Provider。"
        parts = []
        if int(status.get("movable_database_threads") or 0) > 0:
            parts.append(f"{status['movable_database_threads']} 条数据库记录待迁移")
        model_movable = status.get("model_movable_threads")
        if model_movable is not None and int(model_movable) > 0:
            parts.append(f"{model_movable} 条模型归属待修正")
        if int(status.get("movable_session_threads") or 0) > 0:
            parts.append(f"{status['movable_session_threads']} 个会话文件待修正")
        if int(status.get("missing_session_index_entries") or 0) > 0:
            parts.append(f"{status['missing_session_index_entries']} 条侧边栏索引待补回")
        return "需要同步：" + "，".join(parts) + "。"

    def refresh_state(self) -> None:
        self.set_busy(True, "正在读取状态...")
        self._run_async(self.override_args("status"), self._on_status, self._on_error, "刷新状态")

    def apply_state(self, status: dict[str, object]) -> None:
        self.latest_state = status
        self.info_labels["provider"].configure(text=f"当前账号/Provider: {status['current_provider']}")
        if status.get("current_model"):
            self.info_labels["model"].configure(
                text=f"当前模型: {status['current_model']}    待修正: {status.get('model_movable_threads')}"
            )
        else:
            self.info_labels["model"].configure(text="当前模型: 未读取到")
        self.info_labels["summary"].configure(
            text=(
                f"历史线程: {status['total_threads']}    会话文件: {status['session_file_count']}"
                f"    侧边栏索引: {status['indexed_threads']}"
            )
        )
        self.info_labels["repair"].configure(
            text=(
                f"待修复: {status['movable_threads']}    数据库: {status['movable_database_threads']}"
                f"    模型: {status['model_movable_threads']}    会话文件: {status['movable_session_threads']}"
                f"    索引: {status['missing_session_index_entries']}"
            )
        )
        self.info_labels["path"].configure(text=f"数据位置: {status['codex_home']}")

        self.providers_view.delete(*self.providers_view.get_children())
        current = str(status["current_provider"])
        for row in status.get("provider_counts", []):
            is_current = "当前" if str(row["provider"]) == current else ""
            self.providers_view.insert(
                "",
                "end",
                values=(row["provider"], row["count"], "数据库", is_current),
            )
        for row in status.get("session_provider_counts", []):
            is_current = "当前" if str(row["provider"]) == current else ""
            self.providers_view.insert(
                "",
                "end",
                values=(row["provider"], row["count"], "会话文件", is_current),
            )

        self.backup_list.delete(0, "end")
        self.backup_map = {}
        for backup in status.get("backups", []):
            label = f"{backup['modified_at']}    {backup['name']}"
            self.backup_map[label] = str(backup["path"])
            self.backup_list.insert("end", label)

    def _on_status(self, status: dict[str, object]) -> None:
        self.apply_state(status)
        self.log(f"状态已刷新：{self.friendly_status(status)}")
        self.set_busy(False)

    def _on_error(self, action: str, exc: Exception) -> None:
        self.log(f"{action}失败: {exc}")
        self.set_busy(False)
        messagebox.showerror(f"{action}失败", str(exc))

    def _handle_exception(self, exc: Exception, action: str) -> None:
        self._on_error(action, exc)

    # ------------------------------------------------------------------ 动作

    def action_sync(self) -> None:
        try:
            if self.latest_state is None:
                self.refresh_state()
                return
            if int(self.latest_state["movable_threads"]) <= 0:
                messagebox.showinfo("无需同步", "当前已经整理好了，不需要再同步。")
                self.log("同步跳过：当前已经没有需要修复的历史。")
                return
            message = (
                f"将把旧账号/Provider/模型下的本地历史挂回当前设置：\n"
                f"Provider: {self.latest_state['current_provider']}\n"
                f"模型: {self.latest_state['current_model']}\n\n"
                f"本次预计处理：{self.latest_state['movable_threads']} 项\n"
                f"包含数据库记录、会话文件和侧边栏索引。\n\n"
                f"工具会先自动备份。Codex 正在运行也可以，但如果它正在写入历史，可能会等待几秒。"
            )
            if not messagebox.askokcancel("开始找回历史？", message):
                self.log("用户取消了同步。")
                return
            self.set_busy(True, "正在同步历史，Codex 忙的时候会自动等一会儿...")
            self._run_async(self.override_args("sync"), self._on_sync_done, self._on_error, "同步")
        except Exception as exc:
            self._handle_exception(exc, "同步")

    def _on_sync_done(self, result: dict[str, object]) -> None:
        self.log(f"同步完成。数据库更新 {result['updated_rows']} 条，会话文件更新 {result['updated_session_files']} 个。")
        self.log(f"等待数据库空闲: {self._format_duration(result['lock_wait_ms'])}，总耗时: {self._format_duration(result['timing']['total_ms'])}。")
        self.log(f"数据库同步前: {self._format_counts(result['before_counts'])}")
        self.log(f"数据库同步后: {self._format_counts(result['after_counts'])}")
        self.log(f"模型同步前: {self._format_model_counts(result['before_model_counts'])}")
        self.log(f"模型同步后: {self._format_model_counts(result['after_model_counts'])}")
        self.log(f"会话文件同步前: {self._format_counts(result['session_before_counts'])}")
        self.log(f"会话文件同步后: {self._format_counts(result['session_after_counts'])}")
        self.log(f"侧边栏索引已重建: {result['rewritten_index_entries']} 条，补回 {result['missing_session_index_entries_before']} 条。")
        self.log(f"备份文件: {result['backup_path']}")
        self.apply_state(dict(result["status"]))
        self.set_busy(False)
        messagebox.showinfo("同步完成", "同步完成。如果侧边栏没有马上刷新，重新打开 Codex 即可。")

    def action_backup(self) -> None:
        self.set_busy(True, "正在创建安全备份...")
        self._run_async(["backup"], self._on_backup_done, self._on_error, "备份")

    def _on_backup_done(self, result: dict[str, object]) -> None:
        self.log(f"手动备份完成: {result['backup_path']}")
        self.log(f"备份耗时: {self._format_duration(result['timing']['total_ms'])}")
        self.set_busy(False)
        self.refresh_state()

    def action_open_backups(self) -> None:
        try:
            folder_value = ""
            if self.latest_state is not None:
                folder_value = str(self.latest_state.get("backup_dir") or "")
            folder = Path(folder_value) if folder_value else Path.home() / ".codex" / "history_sync_backups"
            folder.mkdir(parents=True, exist_ok=True)
            subprocess.Popen(["open", str(folder)])
            self.log(f"已打开备份目录: {folder}")
        except Exception as exc:
            self._handle_exception(exc, "打开目录")

    def action_desktop_entry(self) -> None:
        try:
            path = self._write_desktop_entry()
            self.log(f"桌面入口已更新: {path}")
            messagebox.showinfo("完成", f"桌面入口已更新：\n{path}")
        except Exception as exc:
            self._handle_exception(exc, "创建入口")

    def action_restore_selected(self) -> None:
        try:
            selection = self.backup_list.curselection()
            if not selection:
                messagebox.showwarning("未选择备份", "请先在右侧选一个备份。")
                return
            label = self.backup_list.get(selection[0])
            backup_path = self.backup_map.get(label)
            if not backup_path:
                raise RuntimeError("无法解析选中的备份路径。")
            self._confirm_restore(backup_path)
        except Exception as exc:
            self._handle_exception(exc, "恢复")

    def action_restore_latest(self) -> None:
        try:
            self._confirm_restore(None)
        except Exception as exc:
            self._handle_exception(exc, "恢复")

    def _confirm_restore(self, backup_path: str | None) -> None:
        if backup_path:
            message = f"将恢复这个备份：\n{backup_path}\n\n恢复前会再自动做一份当前状态备份，方便反悔。"
        else:
            message = "将恢复最新备份，并在恢复前再做一次当前状态备份。"
        if not messagebox.askokcancel("确认恢复？", message):
            self.log("用户取消了恢复。")
            return
        arguments = ["restore"]
        if backup_path:
            arguments += ["--backup", backup_path]
        self.set_busy(True, "正在恢复备份...")
        self._run_async(arguments, self._on_restore_done, self._on_error, "恢复")

    def _on_restore_done(self, result: dict[str, object]) -> None:
        self.log(f"恢复完成。来源备份: {result['restored_from']}")
        self.log(f"恢复前安全备份: {result['safety_backup']}")
        self.log(f"恢复耗时: {self._format_duration(result['timing']['total_ms'])}")
        self.apply_state(dict(result["status"]))
        self.set_busy(False)
        messagebox.showinfo("恢复完成", "恢复完成。建议重新打开 Codex 再看历史列表。")

    # ------------------------------------------------------------- 桌面入口

    def _desktop_entry_path(self) -> Path:
        return Path.home() / "Desktop" / DESKTOP_ENTRY_NAME

    def _write_desktop_entry(self) -> Path:
        launcher = TOOL_DIR / "launch_ui.command"
        content = "#!/bin/zsh\n" + f"exec {shlex.quote(str(launcher))}\n"
        path = self._desktop_entry_path()
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)
        return path

    def _ensure_desktop_entry(self) -> None:
        path = self._desktop_entry_path()
        if path.exists():
            return
        self._write_desktop_entry()
        self.log(f"桌面入口已就绪: {path}")

    # --------------------------------------------------------------- 工具方法

    def log(self, message: str) -> None:
        timestamp = datetime.now().strftime("%H:%M:%S")
        self.log_box.configure(state="normal")
        self.log_box.insert("end", f"[{timestamp}] {message}\n")
        self.log_box.see("end")
        self.log_box.configure(state="disabled")

    @staticmethod
    def _format_counts(counts) -> str:
        if not counts:
            return "无"
        return ", ".join(f"{row['provider']}={row['count']}" for row in counts)

    @staticmethod
    def _format_model_counts(counts) -> str:
        if not counts:
            return "无"
        return ", ".join(f"{row['model']}={row['count']}" for row in counts)

    @staticmethod
    def _format_duration(milliseconds) -> str:
        if milliseconds is None:
            return "0 秒"
        seconds = round(float(milliseconds) / 1000, 1)
        return f"{seconds} 秒"


def main(argv: list[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if "--smoke-test" in arguments:
        print("Smoke test OK")
        return 0
    root = tk.Tk()
    CodexSyncApp(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
