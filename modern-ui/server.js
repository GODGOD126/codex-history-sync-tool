const http = require("node:http");
const fs = require("node:fs/promises");
const path = require("node:path");
const { spawn } = require("node:child_process");

const root = __dirname;
const repoRoot = path.resolve(root, "..");
const publicDir = path.join(root, "public");
const backendPath = path.join(repoRoot, "sync_backend.py");
function readPort() {
  const index = process.argv.indexOf("--port");
  if (index >= 0 && process.argv[index + 1]) {
    return Number(process.argv[index + 1]);
  }
  return Number(process.env.PORT || 4757);
}

const port = readPort();
const reuseExisting = process.env.REUSE_EXISTING === "1";

const mimeTypes = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
};

function sendJson(res, statusCode, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      if (!chunks.length) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch (error) {
        reject(error);
      }
    });
    req.on("error", reject);
  });
}

function pythonCommand() {
  if (process.platform === "win32") {
    return { command: "py", args: ["-3"] };
  }
  return { command: "python3", args: [] };
}

function backend(args) {
  return new Promise((resolve) => {
    const python = pythonCommand();
    const child = spawn(python.command, [...python.args, backendPath, "--json", ...args], {
      cwd: repoRoot,
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (error) => {
      if (settled) return;
      settled = true;
      resolve({
        statusCode: 500,
        payload: {
          ok: false,
          error: `Failed to start Python backend with ${python.command}: ${error.message}`,
        },
      });
    });
    child.on("close", (code) => {
      if (settled) return;
      settled = true;
      try {
        const payload = JSON.parse(stdout || "{}");
        if (code !== 0 && payload.ok !== false) {
          payload.ok = false;
          payload.error = payload.error || stderr || `Backend exited with code ${code}`;
        }
        resolve({ statusCode: code === 0 ? 200 : 500, payload });
      } catch (error) {
        resolve({
          statusCode: 500,
          payload: {
            ok: false,
            error: `Backend returned invalid JSON: ${error.message}`,
            stdout,
            stderr,
          },
        });
      }
    });
  });
}

function openPath(targetPath) {
  if (!targetPath || typeof targetPath !== "string") {
    throw new Error("Missing path to open.");
  }

  let command = "xdg-open";
  let args = [targetPath];
  if (process.platform === "win32") {
    command = "explorer.exe";
  } else if (process.platform === "darwin") {
    command = "open";
  }

  const child = spawn(command, args, {
    detached: true,
    stdio: "ignore",
    windowsHide: true,
  });
  child.unref();
}

function scopedArgs(scope) {
  if (scope && typeof scope.cwd === "string" && scope.cwd.trim()) {
    return ["--cwd", scope.cwd.trim()];
  }
  return [];
}

async function routeApi(req, res, url) {
  try {
    if (req.method === "GET" && url.pathname === "/api/doctor") {
      const result = await backend(["doctor"]);
      sendJson(res, result.statusCode, result.payload);
      return;
    }

    if (req.method === "GET" && url.pathname === "/api/status") {
      const cwd = url.searchParams.get("cwd");
      const args = ["status", ...scopedArgs({ cwd })];
      const result = await backend(args);
      sendJson(res, result.statusCode, result.payload);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/sync/preview") {
      const body = await readBody(req);
      const result = await backend(["sync", "--dry-run", ...scopedArgs(body)]);
      sendJson(res, result.statusCode, result.payload);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/sync") {
      const body = await readBody(req);
      const result = await backend(["sync", ...scopedArgs(body)]);
      sendJson(res, result.statusCode, result.payload);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/backup") {
      const result = await backend(["backup"]);
      sendJson(res, result.statusCode, result.payload);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/restore/preview") {
      const body = await readBody(req);
      const args = ["restore", "--dry-run"];
      if (body.backup) args.push("--backup", body.backup);
      const result = await backend(args);
      sendJson(res, result.statusCode, result.payload);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/restore") {
      const body = await readBody(req);
      const args = ["restore"];
      if (body.backup) args.push("--backup", body.backup);
      const result = await backend(args);
      sendJson(res, result.statusCode, result.payload);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/manifest") {
      const body = await readBody(req);
      const args = ["manifest"];
      if (body.backup) args.push("--backup", body.backup);
      const result = await backend(args);
      sendJson(res, result.statusCode, result.payload);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/verify") {
      const body = await readBody(req);
      const args = ["verify"];
      if (body.backup) args.push("--backup", body.backup);
      const result = await backend(args);
      sendJson(res, result.statusCode, result.payload);
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/backups/open") {
      const result = await backend(["doctor"]);
      if (result.payload.ok === false && !result.payload.backup_dir) {
        sendJson(res, result.statusCode, result.payload);
        return;
      }
      await fs.mkdir(result.payload.backup_dir, { recursive: true });
      openPath(result.payload.backup_dir);
      sendJson(res, 200, { ok: true, action: "open-backup-dir", path: result.payload.backup_dir });
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/manifest/open") {
      const body = await readBody(req);
      const args = ["manifest"];
      if (body.backup) args.push("--backup", body.backup);
      const result = await backend(args);
      if (result.statusCode !== 200) {
        sendJson(res, result.statusCode, result.payload);
        return;
      }
      openPath(result.payload.manifest_path);
      sendJson(res, 200, {
        ok: true,
        action: "open-manifest",
        path: result.payload.manifest_path,
      });
      return;
    }

    sendJson(res, 404, { ok: false, error: "Unknown API route." });
  } catch (error) {
    sendJson(res, 500, { ok: false, error: error.message });
  }
}

async function serveStatic(req, res, url) {
  const requested = url.pathname === "/" ? "/index.html" : url.pathname;
  const filePath = path.resolve(publicDir, "." + decodeURIComponent(requested));
  if (!filePath.startsWith(publicDir)) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }
  try {
    const content = await fs.readFile(filePath);
    const type = mimeTypes[path.extname(filePath)] || "application/octet-stream";
    res.writeHead(200, { "content-type": type });
    res.end(content);
  } catch {
    res.writeHead(404);
    res.end("Not found");
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname.startsWith("/api/")) {
    await routeApi(req, res, url);
    return;
  }
  await serveStatic(req, res, url);
});

server.on("error", (error) => {
  if (error.code === "EADDRINUSE" && reuseExisting) {
    console.log(`Codex History Sync Modern UI already running: http://127.0.0.1:${port}`);
    process.exit(0);
  }
  throw error;
});

server.listen(port, "127.0.0.1", () => {
  console.log(`Codex History Sync Modern UI: http://127.0.0.1:${port}`);
});
