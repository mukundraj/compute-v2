#!/usr/bin/env bash
#
# install-nvidia-container-toolkit.sh
#
# Installs the NVIDIA driver AND the NVIDIA Container Toolkit on a Debian
# cloud VM (tested on Debian 12 Bookworm and Debian 13 Trixie on Google
# Cloud; should also work on AWS / Azure / bare metal).
#
# DRIVER:  Installed from NVIDIA's official .run installer. This sidesteps
#          APT signature verification entirely, which is necessary on
#          Debian 13 (Trixie) where the new sqv verifier rejects NVIDIA's
#          CUDA repo signing key (SHA1 self-signature).
#
# TOOLKIT: Installed from NVIDIA's apt repository (its key uses modern
#          signatures, so it works fine on Trixie).
#
# Two phases, auto-detected:
#   Phase 1 (no driver yet):  installs kernel headers + NVIDIA driver via
#                             .run installer, then asks you to reboot.
#   Phase 2 (driver loaded):  installs the container toolkit and configures
#                             Docker.
#
# Usage:
#   chmod +x install-nvidia-container-toolkit.sh
#   ./install-nvidia-container-toolkit.sh        # Phase 1 -> reboot
#   sudo reboot
#   ./install-nvidia-container-toolkit.sh        # Phase 2

set -euo pipefail

# ---- Configurable ---------------------------------------------------------

# Pin a known-good driver version. The .run installer for this version is
# fetched directly from NVIDIA's downloads server. The 580 datacenter branch
# builds on Debian 13 with the 6.12 stable-security kernels (6.12.100+ backported
# a pci_resize_resource() signature change that the older 570.133.20 driver could
# NOT compile against — do not downgrade below 580 on Debian 13). It supports the
# T4 (Turing) and is forward-compatible with the image's older CUDA runtime. To
# change it, edit this value or override via the NVIDIA_DRIVER_VERSION env var.
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-580.126.20}"

# ---- Helpers --------------------------------------------------------------

log()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR]\033[0m   %s\n' "$*" >&2; }

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Required command '$1' not found after install. Aborting."
        exit 1
    fi
}

# ---- Sudo handling --------------------------------------------------------

if [[ "${EUID}" -eq 0 ]]; then
    SUDO=""
else
    if ! command -v sudo >/dev/null 2>&1; then
        err "This script needs root or sudo. Please run as root or install sudo."
        exit 1
    fi
    SUDO="sudo"
fi

# ---- Pre-flight: install base tooling -------------------------------------

log "Checking base prerequisites (curl, gnupg, ca-certificates, pciutils)..."
MISSING_PKGS=()
command -v curl  >/dev/null 2>&1 || MISSING_PKGS+=("curl")
command -v gpg   >/dev/null 2>&1 || MISSING_PKGS+=("gnupg")
command -v lspci >/dev/null 2>&1 || MISSING_PKGS+=("pciutils")
dpkg -s ca-certificates >/dev/null 2>&1 || MISSING_PKGS+=("ca-certificates")

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    log "Installing missing base packages: ${MISSING_PKGS[*]}"
    $SUDO apt-get update -y
    $SUDO apt-get install -y "${MISSING_PKGS[@]}"
fi

require_cmd curl
require_cmd gpg
require_cmd lspci

# ---- Detect OS and architecture -------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    err "/etc/os-release not found; cannot detect Debian version."
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" != "debian" ]]; then
    warn "This script is designed for Debian. Detected ID=${ID:-unknown}."
fi

DPKG_ARCH="$(dpkg --print-architecture)"
case "$DPKG_ARCH" in
    amd64) RUN_ARCH="x86_64" ;;
    arm64) RUN_ARCH="aarch64" ;;
    *)     err "Unsupported architecture: $DPKG_ARCH"; exit 1 ;;
esac

log "Detected: Debian ${VERSION_ID:-?} (${VERSION_CODENAME:-?}), arch ${DPKG_ARCH}"

# ---- Detect GPU presence --------------------------------------------------

if ! lspci | grep -qi nvidia; then
    err "No NVIDIA GPU detected via lspci."
    err "On a cloud VM, make sure you launched a GPU-enabled instance type."
    exit 1
fi

log "NVIDIA GPU detected:"
lspci | grep -i nvidia | sed 's/^/         /'

# ===========================================================================
# PHASE 1: Install NVIDIA driver via .run installer
# ===========================================================================

if ! command -v nvidia-smi >/dev/null 2>&1; then
    log "NVIDIA driver not detected. Starting Phase 1: driver installation."

    # Install kernel headers + DKMS so the driver module can build for
    # whatever kernel the cloud image is running.
    #
    # Install BOTH the versioned headers for the running kernel AND the flavour
    # metapackage (e.g. linux-headers-cloud-amd64). The metapackage is
    # load-bearing: without it, an unattended kernel upgrade pulls a new
    # linux-image with no matching headers, DKMS silently can't rebuild the
    # nvidia module, and the GPU breaks on the next reboot. The flavour is
    # derived from the running kernel (e.g. 6.12.100+deb13-cloud-amd64 ->
    # cloud-amd64) so this stays correct on both -cloud- and stock images.
    KERNEL="$(uname -r)"
    KERNEL_FLAVOUR="${KERNEL#*-}"   # strip "<version>-" prefix -> "cloud-amd64"
    log "Installing kernel headers (${KERNEL} + linux-headers-${KERNEL_FLAVOUR} metapackage), build-essential, dkms, pkg-config, libglvnd-dev..."
    $SUDO apt-get update -y
    if ! $SUDO apt-get install -y \
        "linux-headers-${KERNEL}" \
        "linux-headers-${KERNEL_FLAVOUR}" \
        build-essential \
        dkms \
        pkg-config \
        libglvnd-dev; then
        warn "Could not install linux-headers-${KERNEL} / linux-headers-${KERNEL_FLAVOUR} directly."
        warn "Trying arch meta-package linux-headers-${DPKG_ARCH}..."
        $SUDO apt-get install -y \
            "linux-headers-${DPKG_ARCH}" \
            build-essential \
            dkms \
            pkg-config \
            libglvnd-dev
    fi

    # Download the .run installer from NVIDIA.
    RUN_FILE="NVIDIA-Linux-${RUN_ARCH}-${NVIDIA_DRIVER_VERSION}.run"
    RUN_URL="https://us.download.nvidia.com/tesla/${NVIDIA_DRIVER_VERSION}/${RUN_FILE}"
    RUN_PATH="/tmp/${RUN_FILE}"

    log "Downloading driver: ${RUN_URL}"
    if ! curl -fsSL --retry 3 -o "$RUN_PATH" "$RUN_URL"; then
        warn "Tesla path failed. Trying generic XFree86 path..."
        RUN_URL="https://us.download.nvidia.com/XFree86/Linux-${RUN_ARCH}/${NVIDIA_DRIVER_VERSION}/${RUN_FILE}"
        log "Downloading driver: ${RUN_URL}"
        curl -fsSL --retry 3 -o "$RUN_PATH" "$RUN_URL"
    fi
    chmod +x "$RUN_PATH"

    # Make sure nouveau is blacklisted before we try to load nvidia.
    NOUVEAU_BLACKLIST=/etc/modprobe.d/blacklist-nouveau.conf
    if [[ ! -f "$NOUVEAU_BLACKLIST" ]]; then
        log "Blacklisting nouveau..."
        $SUDO tee "$NOUVEAU_BLACKLIST" >/dev/null <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
        $SUDO update-initramfs -u
    fi

    # Run the installer silently with DKMS so the module rebuilds on kernel
    # upgrades. --no-drm avoids pulling Xorg dependencies on a headless VM.
    log "Running NVIDIA installer (silent mode, DKMS)..."
    $SUDO sh "$RUN_PATH" \
        --silent \
        --dkms \
        --no-drm \
        --no-questions \
        --accept-license \
        --no-nouveau-check

    rm -f "$RUN_PATH"

    cat <<'EOF'

=========================================================================
  PHASE 1 COMPLETE - reboot required
=========================================================================

  The NVIDIA driver has been installed but is not yet loaded into the
  running kernel. You must reboot before continuing.

  Reboot now with:

      sudo reboot

  After the VM comes back up, verify the driver works:

      nvidia-smi

  Then re-run this script to finish the container toolkit installation:

      ./install-nvidia-container-toolkit.sh

=========================================================================
EOF
    exit 0
fi

# ===========================================================================
# PHASE 2: Install NVIDIA Container Toolkit
# ===========================================================================

log "NVIDIA driver detected. Starting Phase 2: container toolkit installation."
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | sed 's/^/         /' || true

# ---- Add NVIDIA Container Toolkit repository ------------------------------

KEYRING=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
LIST=/etc/apt/sources.list.d/nvidia-container-toolkit.list

log "Adding NVIDIA Container Toolkit GPG key..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | $SUDO gpg --dearmor --yes -o "$KEYRING"

log "Adding NVIDIA Container Toolkit apt repository..."
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=${KEYRING}] https://#g" \
    | $SUDO tee "$LIST" >/dev/null

# ---- Install --------------------------------------------------------------

log "Updating apt package index..."
$SUDO apt-get update -y

log "Installing nvidia-container-toolkit..."
$SUDO apt-get install -y nvidia-container-toolkit

# ---- Configure Docker runtime --------------------------------------------

if command -v docker >/dev/null 2>&1; then
    log "Configuring Docker to use the NVIDIA runtime..."
    $SUDO nvidia-ctk runtime configure --runtime=docker

    log "Restarting Docker..."
    $SUDO systemctl restart docker
else
    warn "Docker not installed; skipping Docker runtime configuration."
    warn "Install Docker, then run: sudo nvidia-ctk runtime configure --runtime=docker"
fi

# ---- Boot-time module load + /dev/nvidia-uvm ------------------------------
#
# The base nvidia module loads at boot, but nvidia_uvm loads LAZILY — its device
# node /dev/nvidia-uvm isn't created until the first CUDA client runs (or
# nvidia-modprobe -u is called). The CDI spec below hardcodes /dev/nvidia-uvm,
# and podman stats every listed node at container start; so on a freshly booted
# GPU VM where nothing has touched CUDA yet, `--device nvidia.com/gpu=all` fails
# with `failed to stat CDI host device "/dev/nvidia-uvm"`. GPU VMs reboot often
# (GCE requires on_host_maintenance=TERMINATE), so install a oneshot unit that
# loads the modules and creates the uvm node on every boot, before any workload.
log "Installing boot-time NVIDIA module-load unit (compute-v2-nvidia-uvm.service)..."
$SUDO tee /etc/systemd/system/compute-v2-nvidia-uvm.service >/dev/null <<'EOF'
[Unit]
Description=Load NVIDIA modules and create /dev/nvidia-uvm at boot
After=local-fs.target
ConditionPathExistsGlob=/dev/nvidia*

[Service]
Type=oneshot
RemainAfterExit=yes
# ConditionPathExistsGlob only checks that the base nvidia node exists; loading
# nvidia_uvm and creating its node is still needed. `-` prefixes make failures
# non-fatal (e.g. no GPU attached after a machine-type change).
ExecStart=-/sbin/modprobe nvidia
ExecStart=-/sbin/modprobe nvidia_uvm
ExecStart=-/usr/bin/nvidia-modprobe -u -c 0

[Install]
WantedBy=multi-user.target
EOF
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now compute-v2-nvidia-uvm.service || \
    warn "Could not enable compute-v2-nvidia-uvm.service."

# ---- Generate CDI spec ---------------------------------------------------
#
# Runs AFTER the uvm node is created above, so the spec enumerates
# /dev/nvidia-uvm and podman can inject it. Regenerate after any driver upgrade.
log "Generating CDI spec at /etc/cdi/nvidia.yaml..."
$SUDO mkdir -p /etc/cdi
$SUDO nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml || \
    warn "CDI generation failed (this is OK if you only use --gpus all with Docker)."

# ---- Verify ---------------------------------------------------------------

log "Installed toolkit version:"
dpkg -s nvidia-container-toolkit | grep -E '^(Package|Version):' | sed 's/^/         /' || true

cat <<'EOF'

=========================================================================
  Installation complete.

  Test GPU access in a container:

      sudo docker run --rm --gpus all \
          nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi

  You should see your GPU listed in the output.
=========================================================================
EOF
