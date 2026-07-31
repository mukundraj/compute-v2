#!/bin/bash
set -e

eval "$(micromamba shell hook -s bash)"

# (Re)build denv unless it is present AND importable. Guarding only on
# `-x bin/python` (the old check) is fooled by an interrupted first build: if
# the container is killed mid `micromamba create`, it leaves an executable but
# broken python (missing stdlib/packages), the guard treats it as "done", and
# the user is stranded with no working Jupyter kernels until someone manually
# wipes the volume. The completion stamp (.image-build-id, written as the LAST
# step below) marks a fully-built env, but guarding on the stamp alone would
# clobber a healthy env created by an older entrypoint that predates it — so we
# probe the interpreter instead, which is correct for both cases.
denv_healthy() {
    [ -x /opt/conda/envs/denv/bin/python ] || return 1
    /opt/conda/envs/denv/bin/python -c 'import types, ipykernel' >/dev/null 2>&1
}
if ! denv_healthy; then
    if [ -e /opt/conda/envs/denv ]; then
        echo "Found an incomplete/broken denv; removing and rebuilding..."
        micromamba env remove -n denv -y >/dev/null 2>&1 || true
        rm -rf /opt/conda/envs/denv
    fi
    echo "First run: creating denv (this takes a few minutes)..."
    micromamba create -n denv -y \
        python="${PYTHON_VERSION}" \
        jupyterlab notebook ipykernel numpy pandas matplotlib scikit-learn \
        google-cloud-sdk google-cloud-storage google-crc32c gcsfs
    micromamba run -n denv pip install --no-cache-dir \
        torch torchvision \
        --index-url https://download.pytorch.org/whl/cu124
    micromamba run -n denv python -m ipykernel install \
        --name denv --display-name "Python (denv)" --sys-prefix
    # Re-register the R Jupyter kernel into the freshly-recreated denv share
    # dir. IRkernel is installed against rocker's system R (Containerfile),
    # which --reset-env doesn't touch, so the package is still present — only
    # the kernel spec under /opt/conda/envs/denv/share/jupyter/kernels/ir/
    # needs rewriting.
    Rscript -e "IRkernel::installspec(user=FALSE, prefix='/opt/conda/envs/denv')"
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

# gcloud's bundled Python runs without site-packages by default, so it can't
# import the conda-installed google-crc32c and `gcloud storage cp` skips
# integrity-checked copies. Enable site-packages for all shells + R sessions
# (the Containerfile ENV covers PID 1; these reach RStudio terminals/R, which
# get a reset environment). Unconditional — gcloud is always present in denv.
echo "CLOUDSDK_PYTHON_SITEPACKAGES=1" >> /usr/local/lib/R/etc/Renviron.site
echo "export CLOUDSDK_PYTHON_SITEPACKAGES=1" >> /etc/profile.d/z-gcp.sh

# If GOOGLE_APPLICATION_CREDENTIALS wasn't injected but the SA key is mounted at
# the canonical in-container path, adopt it. run.sh's GCP_SERVICE_ACCOUNT_KEY
# branch sets both the -v mount AND the -e env var, but a raw GCP_VOLUMES
# override in config.local.env mounts the key WITHOUT the paired GCP_ENV,
# leaving the var unset — gcloud then silently falls back to the VM's metadata
# SA (the confusing "*-compute@developer" account). /run/secrets/gcp-key.json is
# the fixed mount path everywhere in the repo, so defaulting to it makes the
# mounted key activate regardless of which run.sh branch mounted it.
if [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f /run/secrets/gcp-key.json ]; then
    export GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/gcp-key.json
fi

# Forward GCP credentials to all services (terminals + R sessions)
if [ -n "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    echo "GOOGLE_APPLICATION_CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS}" >> /usr/local/lib/R/etc/Renviron.site
    echo "export GOOGLE_APPLICATION_CREDENTIALS=${GOOGLE_APPLICATION_CREDENTIALS}" >> /etc/profile.d/z-gcp.sh
    # Set gcloud's active account from the mounted key. Non-fatal (ADC via the
    # env var above works regardless), but log the outcome — a silent failure
    # here leaves `gcloud` defaulting to the VM's metadata-server SA, which is
    # confusing to debug from inside the container.
    if _gcloud_out=$(gcloud auth activate-service-account \
            --key-file="${GOOGLE_APPLICATION_CREDENTIALS}" 2>&1); then
        echo "gcloud: activated service account from ${GOOGLE_APPLICATION_CREDENTIALS}"
    else
        echo "WARNING: gcloud service-account activation failed (continuing): ${_gcloud_out}"
    fi
    unset _gcloud_out
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
