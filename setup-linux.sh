#!/bin/bash
# Run once on a new Linux machine before using build.sh / run.sh
set -e

# shellcheck source=utils.sh
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

DATA_DIR="${HOME}/.podman-data"
# Runtime dir must be on local storage — network-mounted $HOME (NFS/CIFS) breaks
# network namespace creation (pasta/slirp4netns). Use /tmp instead.
RUNTIME_DIR="/tmp/${USER}-podman-runtime"

# 1. Create persistent directories
mkdir -p "${RUNTIME_DIR}"
chmod 700 "${RUNTIME_DIR}"
mkdir -p "${RUNTIME_DIR}/libpod/tmp"   # Podman won't create this itself; missing = pause.pid error
mkdir -p "${DATA_DIR}/tmp"
mkdir -p "${DATA_DIR}/storage"
export XDG_RUNTIME_DIR="${RUNTIME_DIR}"
echo "Set XDG_RUNTIME_DIR=${RUNTIME_DIR} (local /tmp — required for network namespaces)"

# 2. Raise file descriptor limit (needed for large container layers)
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true

# 3. Install Podman, fuse-overlayfs, and OCI runtime if missing
PKGS=()
command -v podman &>/dev/null || PKGS+=(podman)
command -v fuse-overlayfs &>/dev/null || PKGS+=(fuse-overlayfs)
command -v crun &>/dev/null || command -v runc &>/dev/null || PKGS+=(crun runc)
command -v rsync &>/dev/null || PKGS+=(rsync)
command -v tmux &>/dev/null || PKGS+=(tmux)
command -v htop &>/dev/null || PKGS+=(htop)
command -v git &>/dev/null || PKGS+=(git)
command -v unzip &>/dev/null || PKGS+=(unzip)
if [ ${#PKGS[@]} -gt 0 ]; then
    echo "Installing packages (requires sudo): ${PKGS[*]}"
    sudo apt-get install -y "${PKGS[@]}"
fi

# Determine which OCI runtime to use
if command -v crun &>/dev/null; then
    OCI_RUNTIME="crun"
else
    OCI_RUNTIME="runc"
fi
echo "Using OCI runtime: ${OCI_RUNTIME}"

# NVIDIA GPU passthrough — detect host GPU and prompt for toolkit install if missing.
# Not auto-installed: nvidia-container-toolkit needs NVIDIA's apt repo + sudo and
# host policy varies. The CDI spec must be regenerated after host driver upgrades.
if command -v nvidia-smi &>/dev/null && ! command -v nvidia-ctk &>/dev/null; then
    echo ""
    echo "==> NVIDIA GPU detected but nvidia-container-toolkit is not installed."
    echo "    To enable GPU passthrough into containers:"
    echo ""
    echo "    curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | \\"
    echo "      sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
    echo "    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \\"
    echo "      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' | \\"
    echo "      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
    echo "    sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit"
    echo "    sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
    echo ""
    echo "    Then set GPU_ENABLED=true in config.env."
    echo ""
fi

# 4. Configure Podman for rootless operation
mkdir -p ~/.config/containers

# Storage: fuse-overlayfs under home directory, runRoot on local /tmp
cat > ~/.config/containers/storage.conf << EOF
[storage]
  driver = "overlay"
  graphRoot = "${DATA_DIR}/storage"
  runRoot = "${RUNTIME_DIR}/containers"

[storage.options.overlay]
  mount_program = "/usr/bin/fuse-overlayfs"
EOF
echo "Configured fuse-overlayfs storage at ${DATA_DIR}/storage"
echo "Configured runRoot at ${RUNTIME_DIR}/containers"

# Engine: cgroupfs manager + writable tmp_dir + explicit OCI runtime
cat > ~/.config/containers/containers.conf << EOF
[engine]
  cgroup_manager = "cgroupfs"
  tmp_dir = "${DATA_DIR}/tmp"
  runtime = "${OCI_RUNTIME}"
EOF
echo "Configured cgroup_manager=cgroupfs, tmp_dir, and runtime=${OCI_RUNTIME}"

# 5. Reset Podman storage to pick up new config, then migrate to clear stale runtime state
timeout 15 podman system reset --force 2>/dev/null || true
podman system migrate 2>/dev/null || true
echo "Reset Podman storage"

# 6, 7 & 8. Write utils.sh, XDG_RUNTIME_DIR, and run/stop/status aliases to
#           /etc/profile.d/compute-v2.sh (sourced for all users on login shells),
#           and make repo scripts executable by all users.
#           Skipped silently if the current user lacks passwordless sudo — a privileged
#           user should run this script once to configure the system for all users.
UTILS_PATH="$(realpath "$(dirname "${BASH_SOURCE[0]}")/utils.sh")"
REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
PROFILE_D="/etc/profile.d/compute-v2.sh"

if sudo -n true 2>/dev/null; then
    # Make repo dir and all scripts executable by all users
    sudo chmod o+x "${REPO_DIR}" "${REPO_DIR}"/*.sh
    echo "Set o+x on ${REPO_DIR} and its scripts"

    # Write /etc/profile.d/compute-v2.sh — replaces on every run so paths stay current
    sudo tee "${PROFILE_D}" > /dev/null << EOF
# Managed by setup-linux.sh — do not edit manually
[ -f "${UTILS_PATH}" ] && source "${UTILS_PATH}"
export XDG_RUNTIME_DIR="/tmp/\${USER}-podman-runtime"
alias run='${REPO_DIR}/run.sh'
alias stop='${REPO_DIR}/stop.sh'
alias status='${REPO_DIR}/status.sh'
EOF
    sudo chmod +x "${PROFILE_D}"
    echo "Wrote ${PROFILE_D}"
else
    echo "No sudo access — skipping system-wide config (already done by privileged user)."
fi

echo ""
echo "Setup complete. Run: ./build.sh all"

# If the script is being sourced (not executed), activate changes immediately
# in the current shell without waiting for a new login session.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    set +e  # don't leave errexit active in the user's shell after sourcing
    export XDG_RUNTIME_DIR="${RUNTIME_DIR}"
    alias run="${REPO_DIR}/run.sh"
    alias stop="${REPO_DIR}/stop.sh"
    alias status="${REPO_DIR}/status.sh"
    # shellcheck source=/dev/null
    source "${UTILS_PATH}"
    echo "Shell reloaded — aliases are active."
else
    echo "Tip: run as 'source ./setup-linux.sh' to activate aliases immediately."
fi
