@echo off
setlocal

set "REPO=%~dp0.."
pushd "%REPO%" >nul || exit /b 1
for %%I in ("%CD%") do set "REPO=%%~fI"
popd >nul

set "TAURI_DIR=%REPO%\tauri-ui"
set "EXE=%TAURI_DIR%\src-tauri\target\release\codex-history-sync-tauri.exe"
set "PATH=%USERPROFILE%\.cargo\bin;%PATH%"

cd /d "%TAURI_DIR%" || (
  echo Cannot find Tauri folder: %TAURI_DIR%
  pause
  exit /b 1
)

where node >nul 2>nul || (
  echo Missing Node.js. Please install Node.js 20 or newer.
  pause
  exit /b 1
)

where npm >nul 2>nul || (
  echo Missing npm. Please install Node.js 20 or newer.
  pause
  exit /b 1
)

where cargo >nul 2>nul || (
  echo Missing Rust/Cargo. Please install Rust from https://rustup.rs/
  pause
  exit /b 1
)

where py >nul 2>nul || (
  echo Missing Python launcher py.exe. Please install Python 3.
  pause
  exit /b 1
)

if not exist "%TAURI_DIR%\node_modules" (
  echo Installing Tauri npm dependencies...
  call npm install || (
    echo npm install failed.
    pause
    exit /b 1
  )
)

if not exist "%EXE%" (
  echo Building Tauri desktop app. First build can take a few minutes...
  call npm run build || (
    echo Tauri build failed.
    pause
    exit /b 1
  )
)

start "" "%EXE%"
