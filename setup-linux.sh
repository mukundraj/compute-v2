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
mkdir -p "${DATA_DIR}/tmp"
mkdir -p "${DATA_DIR}/storage"
export XDG_RUNTIME_DIR="${RUNTIME_DIR}"
echo "Set XDG_RUNTIME_DIR=${RUNTIME_DIR} (local /tmp — required for network namespaces)"

# 2. Raise file descriptor limit (needed for large container layers)
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true

# 3. Install fuse-overlayfs and OCI runtime if missing
PKGS=()
command -v fuse-overlayfs &>/dev/null || PKGS+=(fuse-overlayfs)
command -v crun &>/dev/null || command -v runc &>/dev/null || PKGS+=(crun runc)
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

# 5. Reset Podman storage to pick up new config
podman system reset --force 2>/dev/null || true
echo "Reset Podman storage"

# 6. Source utils.sh for all users via system-wide bashrc
UTILS_PATH="$(realpath "$(dirname "${BASH_SOURCE[0]}")/utils.sh")"
BASHRC_LINE="[ -f \"${UTILS_PATH}\" ] && source \"${UTILS_PATH}\""
if ! grep -qF "$UTILS_PATH" /etc/bash.bashrc 2>/dev/null; then
    echo "$BASHRC_LINE" | sudo tee -a /etc/bash.bashrc > /dev/null
    echo "Added utils.sh to /etc/bash.bashrc"
else
    echo "utils.sh already present in /etc/bash.bashrc — skipping"
fi

echo ""
echo "Setup complete. Run: ./build.sh all"
