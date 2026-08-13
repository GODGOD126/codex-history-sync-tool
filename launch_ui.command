#!/bin/zsh
# Codex 历史找回助手 - macOS 启动入口
# Finder 里双击本文件即可打开图形界面。

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCH_UI="$SCRIPT_DIR/launch_ui.py"

if [[ ! -f "$LAUNCH_UI" ]]; then
  print -n "缺少界面脚本: $LAUNCH_UI"
  print -n "按任意键退出..."
  read -k1 -s
  exit 1
fi

find_python_with_tk() {
  local candidate
  for candidate in \
    python3 python3.14 python3.13 python3.12 python3.11 python3.10 \
    /opt/homebrew/bin/python3 /usr/bin/python3 \
    /opt/miniconda3/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 \
    /Library/Frameworks/Python.framework/Versions/3.11/bin/python3; do
    if command -v "$candidate" >/dev/null 2>&1 || [[ -x "$candidate" ]]; then
      if "$candidate" - <<'PY' >/dev/null 2>&1
import tkinter
root = tkinter.Tk()
root.withdraw()
root.destroy()
PY
      then
      print "$candidate"
      return 0
      fi
    fi
  done
  return 1
}

PYTHON_BIN="$(find_python_with_tk)"
if [[ -z "$PYTHON_BIN" ]]; then
  print "未找到带 Tkinter 的 Python 3。"
  print "可尝试: brew install python-tk"
  print "或安装 python.org 官方 Python 3.10+。"
  print "如果是远程终端，请在有图形界面的登录会话中双击运行本文件。"
  print -n "按任意键退出..."
  read -k1 -s
  exit 1
fi

exec "$PYTHON_BIN" "$LAUNCH_UI" "$@"
