use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const BACKEND_SOURCE: &str = include_str!("../../../sync_backend.py");

fn backend_path() -> Result<PathBuf, String> {
    let mut dir = std::env::temp_dir();
    dir.push("codex-history-sync-tool");
    fs::create_dir_all(&dir).map_err(|error| format!("Failed to create backend temp dir: {error}"))?;

    let path = dir.join("sync_backend.py");
    fs::write(&path, BACKEND_SOURCE)
        .map_err(|error| format!("Failed to write embedded backend: {error}"))?;
    Ok(path)
}

fn run_backend(args: Vec<String>) -> Result<Value, String> {
    let backend_path = backend_path()?;
    let backend_dir = backend_path
        .parent()
        .ok_or_else(|| "Unable to resolve backend directory".to_string())?;

    let mut command = python_command();
    command.arg(&backend_path).arg("--json").args(args).current_dir(backend_dir);

    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }

    let output = command
        .output()
        .map_err(|error| format!("Failed to run backend: {error}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let mut payload: Value = serde_json::from_str(stdout.trim()).map_err(|error| {
        format!(
            "Backend returned invalid JSON: {error}; stdout={}; stderr={}",
            stdout.trim(),
            stderr.trim()
        )
    })?;

    if !output.status.success() {
        if let Value::Object(map) = &mut payload {
            map.entry("ok").or_insert(Value::Bool(false));
            if !stderr.trim().is_empty() {
                map.entry("error")
                    .or_insert(Value::String(stderr.trim().to_string()));
            }
        }
    }

    Ok(payload)
}

#[cfg(target_os = "windows")]
fn python_command() -> Command {
    let mut command = Command::new("py");
    command.arg("-3");
    command
}

#[cfg(not(target_os = "windows"))]
fn python_command() -> Command {
    Command::new("python3")
}

fn payload_string(payload: &Value, key: &str) -> Result<String, String> {
    payload
        .get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| format!("Backend response did not include {key}."))
}

fn open_path(path: &Path) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    let mut command = Command::new("explorer.exe");
    #[cfg(target_os = "macos")]
    let mut command = Command::new("open");
    #[cfg(all(not(target_os = "windows"), not(target_os = "macos")))]
    let mut command = Command::new("xdg-open");

    command
        .arg(path)
        .spawn()
        .map_err(|error| format!("Failed to open {}: {error}", path.display()))?;
    Ok(())
}

#[tauri::command]
fn backend_doctor() -> Result<Value, String> {
    run_backend(vec!["doctor".to_string()])
}

#[tauri::command]
fn backend_status(cwd: Option<String>) -> Result<Value, String> {
    let mut args = vec!["status".to_string()];
    if let Some(cwd) = cwd.filter(|value| !value.trim().is_empty()) {
        args.extend(["--cwd".to_string(), cwd]);
    }
    run_backend(args)
}

#[tauri::command]
fn backend_sync_preview(cwd: Option<String>) -> Result<Value, String> {
    let mut args = vec!["sync".to_string(), "--dry-run".to_string()];
    if let Some(cwd) = cwd.filter(|value| !value.trim().is_empty()) {
        args.extend(["--cwd".to_string(), cwd]);
    }
    run_backend(args)
}

#[tauri::command]
fn backend_sync(cwd: Option<String>) -> Result<Value, String> {
    let mut args = vec!["sync".to_string()];
    if let Some(cwd) = cwd.filter(|value| !value.trim().is_empty()) {
        args.extend(["--cwd".to_string(), cwd]);
    }
    run_backend(args)
}

#[tauri::command]
fn backend_backup() -> Result<Value, String> {
    run_backend(vec!["backup".to_string()])
}

#[tauri::command]
fn backend_restore_preview(backup: Option<String>) -> Result<Value, String> {
    let mut args = vec!["restore".to_string(), "--dry-run".to_string()];
    if let Some(backup) = backup.filter(|value| !value.trim().is_empty()) {
        args.extend(["--backup".to_string(), backup]);
    }
    run_backend(args)
}

#[tauri::command]
fn backend_restore(backup: Option<String>) -> Result<Value, String> {
    let mut args = vec!["restore".to_string()];
    if let Some(backup) = backup.filter(|value| !value.trim().is_empty()) {
        args.extend(["--backup".to_string(), backup]);
    }
    run_backend(args)
}

#[tauri::command]
fn backend_verify(backup: Option<String>) -> Result<Value, String> {
    let mut args = vec!["verify".to_string()];
    if let Some(backup) = backup.filter(|value| !value.trim().is_empty()) {
        args.extend(["--backup".to_string(), backup]);
    }
    run_backend(args)
}

#[tauri::command]
fn backend_manifest(backup: Option<String>) -> Result<Value, String> {
    let mut args = vec!["manifest".to_string()];
    if let Some(backup) = backup.filter(|value| !value.trim().is_empty()) {
        args.extend(["--backup".to_string(), backup]);
    }
    run_backend(args)
}

#[tauri::command]
fn open_backup_dir() -> Result<Value, String> {
    let payload = run_backend(vec!["doctor".to_string()])?;
    let backup_dir = PathBuf::from(payload_string(&payload, "backup_dir")?);
    fs::create_dir_all(&backup_dir)
        .map_err(|error| format!("Failed to create backup directory {}: {error}", backup_dir.display()))?;
    open_path(&backup_dir)?;
    Ok(serde_json::json!({
        "ok": true,
        "action": "open-backup-dir",
        "path": backup_dir.to_string_lossy()
    }))
}

#[tauri::command]
fn open_manifest(backup: Option<String>) -> Result<Value, String> {
    let manifest = backend_manifest(backup)?;
    let manifest_path = PathBuf::from(payload_string(&manifest, "manifest_path")?);
    open_path(&manifest_path)?;
    Ok(serde_json::json!({
        "ok": true,
        "action": "open-manifest",
        "path": manifest_path.to_string_lossy()
    }))
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            backend_status,
            backend_sync_preview,
            backend_sync,
            backend_backup,
            backend_restore_preview,
            backend_restore,
            backend_verify,
            backend_manifest,
            backend_doctor,
            open_backup_dir,
            open_manifest
        ])
        .run(tauri::generate_context!())
        .expect("error while running Tauri application");
}
