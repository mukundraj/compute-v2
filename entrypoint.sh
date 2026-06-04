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
    # Stamp the recreated env with the current image's build ID so future
    # restarts can detect drift the same way as image-initialized volumes.
    echo "${IMAGE_BUILD_ID:-unknown}" > /opt/conda/envs/denv/.image-build-id
fi

# Detect stale conda-envs volume: the env's stamp predates the image's stamp.
# Happens when the image was rebuilt but the ds-conda-envs-<profile> volume
# was carried forward, so the user keeps seeing the old env. Recover with:
# stop, podman volume rm ds-conda-envs-<profile>, restart — or use the
# --reset-env flag on run.sh.
if [ -f /opt/conda/envs/denv/.image-build-id ]; then
    VOLUME_BUILD_ID=$(cat /opt/conda/envs/denv/.image-build-id)
    if [ "$VOLUME_BUILD_ID" != "${IMAGE_BUILD_ID:-unknown}" ]; then
        echo ""
        echo "WARNING: ds-conda-envs volume was built against image ${VOLUME_BUILD_ID:-unknown},"
        echo "         current image is ${IMAGE_BUILD_ID:-unknown}."
        echo "         If you see broken imports or missing packages, reset the env:"
        echo "           on the host: ./run.sh <profile> <service> --reset-env"
        echo ""
    fi
fi

micromamba activate denv

# Install the transparent apt / apt-get wrapper from the bind-mounted script
# (run.sh mounts templates/apt-autosave.sh at /opt/apt-autosave.sh). /usr/local/bin
# precedes /usr/bin in PATH, so this shadows the real binaries. Copied (not
# symlinked) each boot so the mount can stay read-only; editing the host script
# takes effect on the next ./run.sh with no image rebuild.
if [ -r /opt/apt-autosave.sh ]; then
    install -m 0755 /opt/apt-autosave.sh /usr/local/bin/apt-get
    ln -sf /usr/local/bin/apt-get /usr/local/bin/apt
    hash -r
fi

# Extra apt system libs (APT_PACKAGES, resolved per-profile by run.sh). The
# unpacked files land in the ephemeral overlay, so we reinstall on every start;
# the .deb cache is a named volume (mounted at /var/cache/apt/archives), so after
# the first pull this is fast and works offline. Keep cached .debs (no apt clean).
# Call the real binary directly so these baseline installs aren't re-recorded.
if [ -n "${APT_PACKAGES:-}" ]; then
    echo "Installing APT_PACKAGES: ${APT_PACKAGES}"
    # Non-fatal (set -e is on): a transient network failure or one uninstallable
    # package must not abort container startup. update can fail offline — install
    # then falls back to cached .debs/lists; a failed install just warns so the
    # service still launches (fix the offending entry in config.local.env).
    /usr/bin/apt-get update -qq || echo "WARNING: apt-get update failed; using cached package lists"
    /usr/bin/apt-get install -y --no-install-recommends ${APT_PACKAGES} \
        || echo "WARNING: APT_PACKAGES install failed (continuing): ${APT_PACKAGES}"
fi

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
      --extensions-dir /opt/code-server-extensions \
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
