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

# 5. Reset Podman storage to pick up new config, then migrate to clear stale runtime state
timeout 15 podman system reset --force 2>/dev/null || true
podman system migrate 2>/dev/null || true
echo "Reset Podman storage"

# 6 & 7. Add utils.sh, XDG_RUNTIME_DIR, and run/stop aliases to /etc/bash.bashrc
#        Skipped silently if the current user lacks passwordless sudo — a privileged
#        user should run this script once to configure the system for all users.
UTILS_PATH="$(realpath "$(dirname "${BASH_SOURCE[0]}")/utils.sh")"
REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
SYSTEM_BASHRC="/etc/bash.bashrc"

if sudo -n true 2>/dev/null; then
    # utils.sh — keyed on a fixed marker so path differences between users don't re-add it
    if ! grep -qF "compute-v2/utils.sh" "$SYSTEM_BASHRC" 2>/dev/null; then
        echo "[ -f \"${UTILS_PATH}\" ] && source \"${UTILS_PATH}\"" | sudo tee -a "$SYSTEM_BASHRC" > /dev/null
        echo "Added utils.sh to ${SYSTEM_BASHRC}"
    else
        echo "utils.sh already present in ${SYSTEM_BASHRC} — skipping"
    fi

    # XDG_RUNTIME_DIR — single-quoted so ${USER} expands per-user at login time
    XDG_LINE='export XDG_RUNTIME_DIR="/tmp/${USER}-podman-runtime"'
    if ! grep -qF 'XDG_RUNTIME_DIR="/tmp/${USER}-podman-runtime"' "$SYSTEM_BASHRC" 2>/dev/null; then
        echo "$XDG_LINE" | sudo tee -a "$SYSTEM_BASHRC" > /dev/null
        echo "Pinned XDG_RUNTIME_DIR in ${SYSTEM_BASHRC}"
    else
        echo "XDG_RUNTIME_DIR already set in ${SYSTEM_BASHRC} — skipping"
    fi

    # Aliases for run and stop
    for alias_entry in "run:${REPO_DIR}/run.sh" "stop:${REPO_DIR}/stop.sh"; do
        alias_name="${alias_entry%%:*}"
        alias_target="${alias_entry##*:}"
        alias_line="alias ${alias_name}='${alias_target}'"
        if ! grep -qF "alias ${alias_name}='${alias_target}'" "$SYSTEM_BASHRC" 2>/dev/null; then
            echo "$alias_line" | sudo tee -a "$SYSTEM_BASHRC" > /dev/null
            echo "Added alias to ${SYSTEM_BASHRC}: ${alias_line}"
        else
            echo "Alias '${alias_name}' already present in ${SYSTEM_BASHRC} — skipping"
        fi
    done
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
    # shellcheck source=/dev/null
    source "${UTILS_PATH}"
    echo "Shell reloaded — aliases are active."
else
    echo "Tip: run as 'source ./setup-linux.sh' to activate aliases immediately."
fi
