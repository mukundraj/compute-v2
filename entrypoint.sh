#!/bin/bash
set -e

eval "$(micromamba shell hook -s bash)"

# First-run: if conda-envs dir is mounted but denv doesn't exist, recreate it
if [ ! -x /opt/conda/envs/denv/bin/R ]; then
    echo "First run: creating denv (this takes a few minutes)..."
    micromamba create -n denv -y \
        r-base="${R_VERSION}" \
        r-tidyverse r-irkernel \
        python="${PYTHON_VERSION}" \
        jupyterlab notebook ipykernel numpy pandas matplotlib scikit-learn \
        google-cloud-sdk google-cloud-storage gcsfs
    micromamba run -n denv python -m ipykernel install \
        --name denv --display-name "Python (denv)" --sys-prefix
    micromamba run -n denv Rscript -e "IRkernel::installspec(user=FALSE)"
fi

micromamba activate denv

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
    # Wrapper script (not symlink) so the shim's $0-based basedir resolves correctly
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$HOST_CLAUDE" > /usr/local/bin/claude
    chmod +x /usr/local/bin/claude
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
      --allow-root \
      --notebook-dir="${WORK_MOUNT:-/home/workdir}"
    ;;
  rstudio)
    echo "Starting RStudio Server on port 8787..."
    mkdir -p /etc/rstudio
    echo "session-default-working-dir=${WORK_MOUNT:-/home/workdir}" >> /etc/rstudio/rsession.conf
    exec /init
    ;;
  claude|claude-code)
    echo "Starting Claude Code..."
    exec "${HOST_CLAUDE:-claude}"
    ;;
  bash|shell)
    echo "Launching shell with denv activated..."
    exec bash
    ;;
  *)
    echo "Usage: ./run.sh [a|b] [jupyter|rstudio|claude|bash]"
    echo "Defaulting to JupyterLab..."
    exec jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root
    ;;
esac
