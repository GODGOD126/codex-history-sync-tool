import argparse
import json
import os
import sqlite3
import sys
import webbrowser
from datetime import datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from open_codex_history import (
    DEFAULT_CODEX_HOME,
    compact,
    fetch_threads,
    find_matches,
    format_match,
    format_row,
    open_thread,
    plain_path,
    promote_rows,
)


try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except AttributeError:
    pass


VISIBLE_LIMIT = 50
CODEX_HOME = DEFAULT_CODEX_HOME


def project_name(cwd: str) -> str:
    if not cwd:
        return "(no cwd)"
    normalized = cwd.rstrip("\\/")
    return Path(normalized).name or normalized


def thread_to_entry(row: sqlite3.Row, rank: int) -> dict:
    cwd = plain_path(row["cwd"])
    updated_at = row["updated_at"]
    return {
        "id": row["id"],
        "title": compact(row["title"] or "(untitled)", 220),
        "cwd": cwd,
        "project": project_name(cwd),
        "preview": compact(row["preview"] or row["first_user_message"] or "", 260),
        "updatedAt": updated_at,
        "updatedAtText": datetime.fromtimestamp(updated_at).strftime("%Y-%m-%d %H:%M") if updated_at else "",
        "rank": rank,
        "visible": rank <= VISIBLE_LIMIT,
        "archived": bool(row["archived"]),
    }


def load_entries(include_archived: bool = True) -> list[dict]:
    rows = fetch_threads(CODEX_HOME / "state_5.sqlite", include_archived=include_archived)
    active_rank = 0
    entries: list[dict] = []
    for row in rows:
        if row["archived"]:
            rank = 0
        else:
            active_rank += 1
            rank = active_rank
        entries.append(thread_to_entry(row, rank))
    return entries


def project_summary(entries: list[dict]) -> list[dict]:
    projects: dict[str, dict] = {}
    for entry in entries:
        item = projects.setdefault(
            entry["cwd"],
            {
                "cwd": entry["cwd"],
                "project": entry["project"],
                "total": 0,
                "visible": 0,
                "hidden": 0,
                "archived": 0,
            },
        )
        item["total"] += 1
        if entry["archived"]:
            item["archived"] += 1
        elif entry["visible"]:
            item["visible"] += 1
        else:
            item["hidden"] += 1
    return sorted(
        projects.values(),
        key=lambda item: (item["hidden"], item["total"], item["project"].casefold()),
        reverse=True,
    )


def respond_json(handler: BaseHTTPRequestHandler, payload: dict, status: HTTPStatus = HTTPStatus.OK) -> None:
    body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


def selected_rows_by_ids(ids: list[str], include_archived: bool = True) -> list[sqlite3.Row]:
    wanted = set(ids)
    rows = fetch_threads(CODEX_HOME / "state_5.sqlite", include_archived=include_archived)
    return [row for row in rows if row["id"] in wanted]


INDEX_HTML = r"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Codex 原生历史入口</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #111716;
      --panel: #18201f;
      --panel-2: #202a28;
      --panel-3: #25312f;
      --text: #edf2f1;
      --muted: #9ba8a4;
      --line: #34413e;
      --accent: #7bc5a7;
      --warn: #e3b45f;
      --bad: #d9857f;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: "Segoe UI", "Microsoft YaHei", Arial, sans-serif;
      font-size: 14px;
    }
    header {
      height: 58px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      padding: 0 18px;
      border-bottom: 1px solid var(--line);
      background: #131b1a;
      position: sticky;
      top: 0;
      z-index: 5;
    }
    h1 {
      margin: 0;
      font-size: 18px;
      line-height: 1.2;
      font-weight: 650;
    }
    .status {
      color: var(--muted);
      font-variant-numeric: tabular-nums;
      white-space: nowrap;
    }
    .layout {
      display: grid;
      grid-template-columns: 320px minmax(0, 1fr);
      min-height: calc(100vh - 58px);
    }
    aside {
      border-right: 1px solid var(--line);
      background: #131b1a;
      padding: 14px;
      overflow: auto;
      max-height: calc(100vh - 58px);
      position: sticky;
      top: 58px;
    }
    main {
      padding: 16px;
      min-width: 0;
    }
    .searchbar {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto auto auto;
      gap: 10px;
      margin-bottom: 12px;
    }
    input[type="search"] {
      width: 100%;
      min-height: 40px;
      padding: 0 12px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: var(--panel);
      color: var(--text);
      outline: none;
    }
    input[type="checkbox"] {
      accent-color: var(--accent);
    }
    button {
      min-height: 34px;
      padding: 0 12px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: var(--panel-2);
      color: var(--text);
      cursor: pointer;
      white-space: nowrap;
    }
    button:hover { border-color: var(--accent); }
    button.primary {
      border-color: #669986;
      background: #233d36;
    }
    button.warn {
      border-color: #77613a;
      color: #f0d59a;
    }
    button:disabled {
      cursor: default;
      opacity: 0.5;
    }
    .toggle {
      min-height: 40px;
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 0 10px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: var(--panel);
      color: var(--muted);
      white-space: nowrap;
    }
    .project-list {
      display: grid;
      gap: 6px;
    }
    .project {
      width: 100%;
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 8px;
      align-items: center;
      text-align: left;
      min-height: auto;
      padding: 9px 10px;
      background: transparent;
    }
    .project.active {
      background: var(--panel-2);
      border-color: var(--accent);
    }
    .project-name {
      min-width: 0;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .project-count {
      color: var(--muted);
      font-variant-numeric: tabular-nums;
    }
    .project-path {
      grid-column: 1 / -1;
      color: var(--muted);
      font-size: 12px;
      overflow-wrap: anywhere;
    }
    .summary {
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 8px;
      margin-bottom: 12px;
    }
    .metric {
      padding: 10px 12px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: var(--panel);
    }
    .metric b {
      display: block;
      margin-bottom: 4px;
      font-size: 18px;
      font-variant-numeric: tabular-nums;
    }
    .metric span { color: var(--muted); }
    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      align-items: center;
      margin: 8px 0 14px;
    }
    .hint {
      color: var(--muted);
      line-height: 1.5;
      margin-left: auto;
    }
    .thread-list {
      display: grid;
      gap: 8px;
    }
    .thread {
      display: grid;
      grid-template-columns: auto minmax(0, 1fr) auto;
      gap: 10px;
      padding: 12px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: var(--panel);
    }
    .thread.hidden { border-left: 3px solid var(--warn); }
    .thread.visible { border-left: 3px solid var(--accent); }
    .thread.archived { border-left: 3px solid var(--bad); opacity: 0.85; }
    .thread-title {
      font-weight: 650;
      overflow-wrap: anywhere;
      margin-bottom: 6px;
    }
    .thread-meta {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      color: var(--muted);
      font-size: 12px;
      margin-bottom: 6px;
    }
    .thread-preview {
      color: #c5cfcc;
      line-height: 1.45;
      overflow-wrap: anywhere;
    }
    .badges {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      margin-top: 8px;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      min-height: 22px;
      padding: 0 7px;
      border: 1px solid var(--line);
      border-radius: 999px;
      color: var(--muted);
      font-size: 12px;
    }
    .thread-actions {
      display: flex;
      flex-direction: column;
      gap: 8px;
      align-items: stretch;
    }
    .empty {
      padding: 18px;
      border: 1px solid var(--line);
      border-radius: 6px;
      background: var(--panel);
      color: var(--muted);
    }
    code {
      color: #d4e8df;
    }
    @media (max-width: 900px) {
      .layout { grid-template-columns: 1fr; }
      aside {
        position: static;
        max-height: none;
        border-right: 0;
        border-bottom: 1px solid var(--line);
      }
      .searchbar { grid-template-columns: 1fr; }
      .summary { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .thread { grid-template-columns: auto minmax(0, 1fr); }
      .thread-actions { grid-column: 2; flex-direction: row; flex-wrap: wrap; }
    }
  </style>
</head>
<body>
  <header>
    <h1>Codex 原生历史入口</h1>
    <div class="status" id="status">加载中</div>
  </header>
  <div class="layout">
    <aside>
      <div class="project-list" id="projects"></div>
    </aside>
    <main>
      <div class="searchbar">
        <input id="query" type="search" placeholder="搜索标题、项目路径、预览、thread id；点击“全文搜索”可搜 rollout 内容">
        <label class="toggle"><input id="includeArchived" type="checkbox"> 包含归档</label>
        <button id="metadataSearch">筛选</button>
        <button id="fullSearch" class="primary">全文搜索</button>
      </div>
      <section class="summary" id="summary"></section>
      <div class="toolbar">
        <button id="showHidden">只看未显示</button>
        <button id="showAll">显示全部</button>
        <button id="promoteResults" class="warn">导入当前结果前 50 条</button>
        <span class="hint">导入会先备份，再提升到左侧可加载范围；不会删除聊天内容。</span>
      </div>
      <section class="thread-list" id="threads"></section>
    </main>
  </div>
  <script>
    let entries = [];
    let projects = [];
    let selectedCwd = "";
    let onlyHidden = false;
    let currentRows = [];

    const $ = (selector) => document.querySelector(selector);
    const status = $("#status");
    const query = $("#query");
    const includeArchived = $("#includeArchived");

    function esc(value) {
      return String(value ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;");
    }

    async function api(path, options = {}) {
      const response = await fetch(path, {
        ...options,
        headers: {"Content-Type": "application/json", ...(options.headers || {})}
      });
      const payload = await response.json();
      if (!response.ok || payload.ok === false) {
        throw new Error(payload.error || payload.reason || response.statusText);
      }
      return payload;
    }

    function visibleState(entry) {
      if (entry.archived) return "归档";
      return entry.visible ? "已显示" : "未显示";
    }

    function renderSummary(rows) {
      const active = entries.filter((entry) => !entry.archived).length;
      const hidden = entries.filter((entry) => !entry.archived && !entry.visible).length;
      const archived = entries.filter((entry) => entry.archived).length;
      $("#summary").innerHTML = `
        <div class="metric"><b>${entries.length}</b><span>原生记录总数</span></div>
        <div class="metric"><b>${active}</b><span>活跃记录</span></div>
        <div class="metric"><b>${hidden}</b><span>未在初始窗口</span></div>
        <div class="metric"><b>${rows.length}</b><span>当前结果</span></div>
      `;
    }

    function renderProjects() {
      const allHidden = entries.filter((entry) => !entry.archived && !entry.visible).length;
      const allTotal = entries.length;
      const buttons = [
        `<button class="project ${selectedCwd === "" ? "active" : ""}" data-cwd="">
          <span class="project-name">全部项目</span>
          <span class="project-count">${allHidden}/${allTotal}</span>
          <span class="project-path">左侧数字：未显示 / 总数</span>
        </button>`
      ];
      for (const project of projects) {
        buttons.push(`
          <button class="project ${selectedCwd === project.cwd ? "active" : ""}" data-cwd="${esc(project.cwd)}">
            <span class="project-name">${esc(project.project)}</span>
            <span class="project-count">${project.hidden}/${project.total}</span>
            <span class="project-path">${esc(project.cwd)}</span>
          </button>
        `);
      }
      $("#projects").innerHTML = buttons.join("");
    }

    function metadataFilter() {
      const terms = query.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
      return entries.filter((entry) => {
        if (!includeArchived.checked && entry.archived) return false;
        if (selectedCwd && entry.cwd !== selectedCwd) return false;
        if (onlyHidden && (entry.archived || entry.visible)) return false;
        if (!terms.length) return true;
        const haystack = `${entry.title} ${entry.cwd} ${entry.preview} ${entry.id}`.toLowerCase();
        return terms.every((term) => haystack.includes(term));
      });
    }

    function renderThreads(rows) {
      currentRows = rows;
      renderSummary(rows);
      status.textContent = `${rows.length} 条结果`;
      if (!rows.length) {
        $("#threads").innerHTML = `<div class="empty">没有匹配结果。可以打开“包含归档”，或者点“全文搜索”。</div>`;
        return;
      }
      $("#threads").innerHTML = rows.map((entry) => {
        const cls = entry.archived ? "archived" : (entry.visible ? "visible" : "hidden");
        const rank = entry.rank ? `#${entry.rank}` : "归档";
        return `
          <article class="thread ${cls}">
            <input type="checkbox" class="selectThread" value="${esc(entry.id)}">
            <div>
              <div class="thread-title">${esc(entry.title)}</div>
              <div class="thread-meta">
                <span>${esc(rank)}</span>
                <span>${esc(visibleState(entry))}</span>
                <span>${esc(entry.updatedAtText)}</span>
                <span>${esc(entry.project)}</span>
              </div>
              <div class="thread-preview">${esc(entry.preview || entry.cwd)}</div>
              <div class="badges">
                <span class="badge">${esc(entry.cwd)}</span>
                <span class="badge">${esc(entry.id)}</span>
              </div>
            </div>
            <div class="thread-actions">
              <button class="primary importOpen" data-id="${esc(entry.id)}">导入并打开</button>
              <button class="importOnly" data-id="${esc(entry.id)}">只导入</button>
            </div>
          </article>
        `;
      }).join("");
    }

    function refreshMetadataView() {
      const rows = metadataFilter();
      renderThreads(rows);
      renderProjects();
    }

    async function load() {
      status.textContent = "加载中";
      const data = await api(`/api/entries?includeArchived=${includeArchived.checked ? "1" : "0"}`);
      entries = data.entries;
      projects = data.projects;
      refreshMetadataView();
    }

    async function fullTextSearch() {
      status.textContent = "全文搜索中";
      const params = new URLSearchParams({
        q: query.value.trim(),
        includeArchived: includeArchived.checked ? "1" : "0",
        limit: "300"
      });
      if (selectedCwd) params.set("cwd", selectedCwd);
      const data = await api(`/api/search?${params.toString()}`);
      renderThreads(data.matches);
    }

    async function promote(ids, open) {
      if (!ids.length) return;
      status.textContent = "导入中";
      const result = await api("/api/promote", {
        method: "POST",
        body: JSON.stringify({ids, open})
      });
      await load();
      status.textContent = open ? "已导入并打开" : `已导入 ${result.promoted_count || ids.length} 条`;
    }

    $("#metadataSearch").addEventListener("click", refreshMetadataView);
    $("#fullSearch").addEventListener("click", fullTextSearch);
    query.addEventListener("keydown", (event) => {
      if (event.key === "Enter") refreshMetadataView();
    });
    includeArchived.addEventListener("change", load);
    $("#showHidden").addEventListener("click", () => {
      onlyHidden = true;
      refreshMetadataView();
    });
    $("#showAll").addEventListener("click", () => {
      onlyHidden = false;
      refreshMetadataView();
    });
    $("#promoteResults").addEventListener("click", async () => {
      const checked = [...document.querySelectorAll(".selectThread:checked")].map((node) => node.value);
      const ids = checked.length ? checked : currentRows.filter((entry) => !entry.archived).slice(0, 50).map((entry) => entry.id);
      await promote(ids, false);
    });
    document.addEventListener("click", async (event) => {
      const project = event.target.closest(".project");
      if (project) {
        selectedCwd = project.dataset.cwd || "";
        refreshMetadataView();
        return;
      }
      const importOpen = event.target.closest(".importOpen");
      if (importOpen) {
        await promote([importOpen.dataset.id], true);
        return;
      }
      const importOnly = event.target.closest(".importOnly");
      if (importOnly) {
        await promote([importOnly.dataset.id], false);
      }
    });

    load().catch((error) => {
      status.textContent = "加载失败";
      $("#threads").innerHTML = `<div class="empty">${esc(error.message)}</div>`;
    });
  </script>
</body>
</html>
"""


class PortalHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))

    def do_GET(self) -> None:
        try:
            parsed = urlparse(self.path)
            if parsed.path == "/":
                body = INDEX_HTML.encode("utf-8")
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            if parsed.path == "/api/entries":
                params = parse_qs(parsed.query)
                include_archived = params.get("includeArchived", ["0"])[0] == "1"
                entries = load_entries(include_archived=include_archived)
                respond_json(self, {"ok": True, "entries": entries, "projects": project_summary(entries)})
                return
            if parsed.path == "/api/search":
                params = parse_qs(parsed.query)
                query = params.get("q", [""])[0]
                cwd = params.get("cwd", [""])[0]
                limit = int(params.get("limit", ["200"])[0])
                include_archived = params.get("includeArchived", ["0"])[0] == "1"
                matches = find_matches(
                    CODEX_HOME / "state_5.sqlite",
                    query=query,
                    thread_id=None,
                    limit=limit,
                    include_archived=include_archived,
                    scan_fulltext=True,
                )
                formatted = [match_to_entry(match) for match in matches]
                if cwd:
                    formatted = [entry for entry in formatted if entry["cwd"] == cwd]
                respond_json(self, {"ok": True, "matches": formatted})
                return
            respond_json(self, {"ok": False, "error": "not found"}, HTTPStatus.NOT_FOUND)
        except Exception as exc:
            respond_json(self, {"ok": False, "error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)

    def do_POST(self) -> None:
        try:
            parsed = urlparse(self.path)
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
            if parsed.path == "/api/promote":
                ids = [str(item) for item in payload.get("ids", []) if item]
                rows = selected_rows_by_ids(ids, include_archived=True)
                result = promote_rows(CODEX_HOME, rows, dry_run=False, unarchive=True)
                if payload.get("open") and rows:
                    open_thread(rows[0]["id"])
                    result["opened"] = f"codex://threads/{rows[0]['id']}"
                respond_json(self, result)
                return
            respond_json(self, {"ok": False, "error": "not found"}, HTTPStatus.NOT_FOUND)
        except Exception as exc:
            respond_json(self, {"ok": False, "error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)


def match_to_entry(match) -> dict:
    row = match.row
    rows = fetch_threads(CODEX_HOME / "state_5.sqlite", include_archived=True)
    rank_by_id: dict[str, int] = {}
    rank = 0
    for item in rows:
        if item["archived"]:
            continue
        rank += 1
        rank_by_id[item["id"]] = rank
    entry = thread_to_entry(row, rank_by_id.get(row["id"], 0))
    entry["score"] = match.score
    entry["where"] = match.where
    if match.snippet:
        entry["preview"] = match.snippet
    return entry


def main() -> None:
    global CODEX_HOME
    global VISIBLE_LIMIT

    parser = argparse.ArgumentParser(description="Run a local searchable Codex Desktop history portal.")
    parser.add_argument("--codex-home", default=str(DEFAULT_CODEX_HOME))
    parser.add_argument("--visible-limit", type=int, default=VISIBLE_LIMIT)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()

    CODEX_HOME = Path(args.codex_home).expanduser()
    VISIBLE_LIMIT = args.visible_limit
    server = ThreadingHTTPServer((args.host, args.port), PortalHandler)
    url = f"http://{args.host}:{args.port}/"
    print(f"Codex history portal: {url}")
    print("Press Ctrl+C to stop.")
    if not args.no_open:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
