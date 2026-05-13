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
mkdir -p "${RUNTIME_DIR}/tmp"          # engine tmp_dir — must be wiped together with runRoot on reboot
mkdir -p "${DATA_DIR}/storage"
mkdir -p "${DATA_DIR}/tmp"             # TMPDIR — podman load stages decompressed blobs here, off / and /var/tmp
export XDG_RUNTIME_DIR="${RUNTIME_DIR}"
export TMPDIR="${DATA_DIR}/tmp"
echo "Set XDG_RUNTIME_DIR=${RUNTIME_DIR} (local /tmp — required for network namespaces)"
echo "Set TMPDIR=${DATA_DIR}/tmp (keeps podman blob staging off the root disk)"

# 2. Raise file descriptor limit (needed for large container layers)
ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true

# Native rootless overlay requires kernel >= 5.13 and unprivileged userns enabled.
# This script no longer configures fuse-overlayfs as a fallback.
KERNEL_VER="$(uname -r | cut -d. -f1,2)"
KERNEL_MAJOR="${KERNEL_VER%.*}"
KERNEL_MINOR="${KERNEL_VER#*.}"
if [[ "${KERNEL_MAJOR}" -lt 5 ]] || { [[ "${KERNEL_MAJOR}" -eq 5 ]] && [[ "${KERNEL_MINOR}" -lt 13 ]]; }; then
    echo "Error: kernel ${KERNEL_VER} is too old for rootless native overlay (need >= 5.13)." >&2
    exit 1
fi
if [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo 0)" != "1" ]]; then
    echo "Error: unprivileged_userns_clone is not enabled." >&2
    echo "  Enable with: sudo sysctl -w kernel.unprivileged_userns_clone=1" >&2
    exit 1
fi

# 3. Install Podman and OCI runtime if missing
PKGS=()
command -v podman &>/dev/null || PKGS+=(podman)
command -v crun &>/dev/null || command -v runc &>/dev/null || PKGS+=(crun runc)
command -v rsync &>/dev/null || PKGS+=(rsync)
command -v tmux &>/dev/null || PKGS+=(tmux)
command -v htop &>/dev/null || PKGS+=(htop)
command -v git &>/dev/null || PKGS+=(git)
command -v unzip &>/dev/null || PKGS+=(unzip)
command -v growpart &>/dev/null || PKGS+=(cloud-guest-utils)
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

# Storage: native kernel overlay under home directory, runRoot on local /tmp
cat > ~/.config/containers/storage.conf << EOF
[storage]
  driver = "overlay"
  graphRoot = "${DATA_DIR}/storage"
  runRoot = "${RUNTIME_DIR}/containers"
EOF
echo "Configured native overlay storage at ${DATA_DIR}/storage"
echo "Configured runRoot at ${RUNTIME_DIR}/containers"

# Engine: cgroupfs manager + writable tmp_dir + explicit OCI runtime.
# tmp_dir lives under RUNTIME_DIR (on /tmp) so its boot-ID cache is wiped on
# reboot in lockstep with runRoot — otherwise Podman errors with
# "current system boot ID differs from cached boot ID".
cat > ~/.config/containers/containers.conf << EOF
[engine]
  cgroup_manager = "cgroupfs"
  tmp_dir = "${RUNTIME_DIR}/tmp"
  runtime = "${OCI_RUNTIME}"
EOF
echo "Configured cgroup_manager=cgroupfs, tmp_dir, and runtime=${OCI_RUNTIME}"

# 5. Reset Podman storage to pick up new config, then migrate to clear stale runtime state
EXISTING_IMAGES="$(podman images -q 2>/dev/null | wc -l)"
EXISTING_VOLUMES="$(podman volume ls -q 2>/dev/null | wc -l)"
if [[ "${EXISTING_IMAGES}" -gt 0 || "${EXISTING_VOLUMES}" -gt 0 ]]; then
    echo ""
    echo "==> WARNING: existing Podman storage detected."
    echo "    ${EXISTING_IMAGES} image(s), ${EXISTING_VOLUMES} volume(s) will be DELETED."
    echo "    This includes ds-claude-config-* (you'll need to /login again)"
    echo "    and ds-conda-envs-* (auto-rebuilt on first run, but slow)."
    echo ""
    read -r -p "Continue and wipe existing storage? [y/N] " ans
    case "${ans}" in
        y|Y|yes|YES) ;;
        *) echo "Aborted. No changes made to Podman storage."; exit 1 ;;
    esac
fi
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
export TMPDIR="\${HOME}/.podman-data/tmp"
alias run='${REPO_DIR}/run.sh'
alias stop='${REPO_DIR}/stop.sh'
alias status='${REPO_DIR}/status.sh'
EOF
    sudo chmod +x "${PROFILE_D}"
    echo "Wrote ${PROFILE_D}"

    # systemd-tmpfiles drop-in: recreate Podman's runtime dirs on every boot.
    # Without this, /tmp is wiped on reboot and the next `podman` invocation fails
    # with "lstat /tmp/${USER}-podman-runtime: no such file or directory".
    TMPFILES_CONF="/etc/tmpfiles.d/podman-${USER}.conf"
    sudo tee "${TMPFILES_CONF}" > /dev/null << EOF
# Managed by setup-linux.sh — recreates rootless Podman runtime dirs on boot
d ${RUNTIME_DIR}            0700 ${USER} ${USER} -
d ${RUNTIME_DIR}/libpod     0700 ${USER} ${USER} -
d ${RUNTIME_DIR}/libpod/tmp 0700 ${USER} ${USER} -
d ${RUNTIME_DIR}/containers 0700 ${USER} ${USER} -
d ${RUNTIME_DIR}/tmp        0700 ${USER} ${USER} -
EOF
    sudo systemd-tmpfiles --create "${TMPFILES_CONF}" 2>/dev/null || true
    echo "Wrote ${TMPFILES_CONF} (recreates runtime dirs on reboot)"

    # Enable lingering so `systemd --user` runs at boot and provides a session
    # D-Bus over SSH — silences Podman's "couldn't determine address of session
    # bus" WARN. Side effect: user processes survive logout.
    sudo loginctl enable-linger "${USER}"
    echo "Enabled systemd linger for ${USER}"
else
    echo "No passwordless sudo — falling back to per-user config."
    echo "  (Ask an admin to run this script once with sudo for the system-wide bits:"
    echo "   /etc/profile.d aliases, /etc/tmpfiles.d, loginctl enable-linger.)"

    # Per-user systemd-tmpfiles equivalent — runs whenever `systemd --user` starts.
    # Without lingering, that's on first SSH login after each reboot — recreating
    # /tmp/$USER-podman-runtime before the user runs podman.
    mkdir -p ~/.config/user-tmpfiles.d
    cat > ~/.config/user-tmpfiles.d/podman.conf << EOF
d ${RUNTIME_DIR}            0700 - - -
d ${RUNTIME_DIR}/libpod     0700 - - -
d ${RUNTIME_DIR}/libpod/tmp 0700 - - -
d ${RUNTIME_DIR}/containers 0700 - - -
d ${RUNTIME_DIR}/tmp        0700 - - -
EOF
    systemd-tmpfiles --user --create ~/.config/user-tmpfiles.d/podman.conf 2>/dev/null || true
    echo "Wrote ~/.config/user-tmpfiles.d/podman.conf"

    # Per-user shell config — append XDG_RUNTIME_DIR + aliases to ~/.bashrc
    # if not already present. Guarded by a marker so re-runs are idempotent.
    BASHRC_MARKER="# >>> compute-v2 setup-linux.sh >>>"
    if ! grep -qF "${BASHRC_MARKER}" ~/.bashrc 2>/dev/null; then
        cat >> ~/.bashrc << EOF

${BASHRC_MARKER}
[ -f "${UTILS_PATH}" ] && source "${UTILS_PATH}"
export XDG_RUNTIME_DIR="/tmp/\${USER}-podman-runtime"
export TMPDIR="\${HOME}/.podman-data/tmp"
alias run='${REPO_DIR}/run.sh'
alias stop='${REPO_DIR}/stop.sh'
alias status='${REPO_DIR}/status.sh'
# <<< compute-v2 setup-linux.sh <<<
EOF
        echo "Appended XDG_RUNTIME_DIR + aliases to ~/.bashrc"
    else
        echo "~/.bashrc already configured — skipping"
    fi
    echo "Note: 'session bus' WARN from Podman will persist — needs sudo loginctl enable-linger."
fi

echo ""
echo "Setup complete. Run: ./build.sh all"

# If the script is being sourced (not executed), activate changes immediately
# in the current shell without waiting for a new login session.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    set +e  # don't leave errexit active in the user's shell after sourcing
    export XDG_RUNTIME_DIR="${RUNTIME_DIR}"
    export TMPDIR="${DATA_DIR}/tmp"
    alias run="${REPO_DIR}/run.sh"
    alias stop="${REPO_DIR}/stop.sh"
    alias status="${REPO_DIR}/status.sh"
    # shellcheck source=/dev/null
    source "${UTILS_PATH}"
    echo "Shell reloaded — aliases are active."
else
    echo "Tip: run as 'source ./setup-linux.sh' to activate aliases immediately."
fi
