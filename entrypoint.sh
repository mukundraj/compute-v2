#!/bin/bash
set -e

eval "$(micromamba shell hook -s bash)"

# First-run: if conda-envs dir is mounted but denv doesn't exist, recreate it
if [ ! -x /opt/conda/envs/denv/bin/python ]; then
    echo "First run: creating denv (this takes a few minutes)..."
    micromamba create -n denv -y \
        python="${PYTHON_VERSION}" \
        jupyterlab notebook ipykernel numpy pandas matplotlib scikit-learn \
        google-cloud-sdk google-cloud-storage gcsfs
    micromamba run -n denv pip install --no-cache-dir \
        torch torchvision \
        --index-url https://download.pytorch.org/whl/cu124
    micromamba run -n denv python -m ipykernel install \
        --name denv --display-name "Python (denv)" --sys-prefix
fi

micromamba activate denv

# Persist Claude config inside the named volume at /root/.claude
# by symlinking /root/.claude.json → /root/.claude/.claude.json
ln -sf /root/.claude/.claude.json /root/.claude.json

echo "-----------------------------------------------------"
echo "  Python: $(python --version 2>&1)"
echo "  R:      $(R --version 2>&1 | head -1)"
echo "  Node:   $(node --version 2>&1)"
echo "-----------------------------------------------------"

if command -v claude &>/dev/null; then
    echo "Claude Code: $(claude --version 2>/dev/null || echo 'unknown')"
else
    echo "WARNING: claude not found inside image."
fi

# Forward GCP credentials to all services (terminals + R sessions)
if [ -n "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    echo "GOOGLE_APPLICATION_CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS}" >> /usr/local/lib/R/etc/Renviron.site
    echo "export GOOGLE_APPLICATION_CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS}" >> /etc/profile.d/z-gcp.sh
    gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" 2>/dev/null || true
fi
for _var in GCS_READ_PATHS GCS_WRITE_PATHS; do
    _val="${!_var}"
    if [ -n "$_val" ]; then
        echo "${_var}=${_val}" >> /usr/local/lib/R/etc/Renviron.site
        echo "export ${_var}=${_val}" >> /etc/profile.d/z-gcp.sh
    fi
done
unset _var _val

case "$1" in
  jupyter|jupyterlab)
    echo "Starting JupyterLab on port 8888..."
    export SHELL=/bin/bash
    echo "cd ${WORK_MOUNT:-/home/workdir}" >> /root/.bashrc
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
    exec claude
    ;;
  bash|shell)
    echo "Launching shell with denv activated..."
    exec bash
    ;;
  vscode)
    echo "Starting VS Code Server on port 8080..."
    exec code-server \
      --bind-addr 0.0.0.0:8080 \
      --auth password \
      "${WORK_MOUNT:-/home/workdir}"
    ;;
  *)
    echo "Usage: ./run.sh [a|b] [jupyter|rstudio|claude|bash|vscode]"
    echo "Defaulting to JupyterLab..."
    exec jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root
    ;;
esac
