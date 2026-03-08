#!/bin/bash
set -e

eval "$(micromamba shell hook -s bash)"
micromamba activate dsenv

echo "-----------------------------------------------------"
echo "  Python: $(python --version 2>&1)"
echo "  R:      $(R --version 2>&1 | head -1)"
echo "  Node:   $(node --version 2>&1)"
echo "-----------------------------------------------------"

# Locate claude: prefer CLAUDE_BIN env var (set by run.sh), then fall back to PATH
if [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ]; then
    HOST_CLAUDE="$CLAUDE_BIN"
    export PATH="$(dirname "$CLAUDE_BIN"):$PATH"
else
    HOST_CLAUDE=$(which claude 2>/dev/null || echo "")
fi
if [ -z "$HOST_CLAUDE" ]; then
    echo "WARNING: claude not found. On host: install via standalone, npm, or pnpm."
else
    echo "Claude Code: $($HOST_CLAUDE --version 2>/dev/null || echo 'unknown')"
fi

case "$1" in
  jupyter|jupyterlab)
    echo "Starting JupyterLab on port 8888..."
    python -c \
      "import os, json; from jupyter_server.auth import passwd; \
      os.makedirs('/root/.jupyter', exist_ok=True); \
      json.dump({'ServerApp': {'password': passwd(os.environ['JUPYTER_PASSWORD']), 'token': ''}}, \
      open('/root/.jupyter/jupyter_server_config.json', 'w'))"
    exec jupyter lab \
      --ip=0.0.0.0 \
      --port=8888 \
      --no-browser \
      --allow-root
    ;;
  rstudio)
    echo "Starting RStudio Server on port 8787..."
    exec /init
    ;;
  claude|claude-code)
    echo "Starting Claude Code..."
    exec "${HOST_CLAUDE:-claude}"
    ;;
  bash|shell)
    echo "Launching shell with dsenv activated..."
    exec bash
    ;;
  *)
    echo "Usage: ./run.sh [a|b] [jupyter|rstudio|claude|bash]"
    echo "Defaulting to JupyterLab..."
    exec jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root
    ;;
esac
