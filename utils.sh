#!/usr/bin/env bash
# utils.sh — helper functions for compute-v2

makeuser() {
    local current_user
    current_user="$(whoami)"
    local new_user="${current_user}ai"
    local home_dir="/mnt/disks/home/${new_user}"

    # Check that the home directory already exists on a mounted disk
    if [[ ! -d "$home_dir" ]]; then
        echo "Error: ${home_dir} does not exist or is not a directory." >&2
        echo "Create it on the mounted disk first, then re-run." >&2
        return 1
    fi

    # Check that new user doesn't already exist
    if id "$new_user" &>/dev/null; then
        echo "Error: user '${new_user}' already exists." >&2
        return 1
    fi

    echo "Creating user '${new_user}' with home ${home_dir}..."

    # Create user without a default home dir, pointing at the mounted-disk path
    sudo useradd --no-create-home --shell /bin/bash --home-dir "$home_dir" "$new_user"

    # Copy default shell config files
    sudo cp /etc/skel/.bash* "$home_dir"/
    sudo chown "${new_user}:${new_user}" "$home_dir"/.*

    # Set ownership on the home directory
    sudo chown -R "${new_user}:${new_user}" "$home_dir"
    sudo chmod 750 "$home_dir"

    # Copy current user's .ssh directory so SSH login works
    local src_ssh="/home/${current_user}/.ssh"
    local dst_ssh="${home_dir}/.ssh"

    if [[ ! -d "$src_ssh" ]]; then
        echo "Warning: ${src_ssh} not found — skipping SSH key copy." >&2
    else
        sudo cp -r "$src_ssh" "$dst_ssh"
        sudo chown -R "${new_user}:${new_user}" "$dst_ssh"
        sudo chmod 700 "$dst_ssh"
        sudo chmod 600 "$dst_ssh"/*
        # Ensure authorized_keys is present and has correct perms
        if [[ -f "${dst_ssh}/authorized_keys" ]]; then
            sudo chmod 644 "${dst_ssh}/authorized_keys"
        fi
    fi

    echo "Done. User '${new_user}' can now SSH in: ssh ${new_user}@<host>"
}

# Resolve a GCP persistent disk name to its /dev/<id> path.
# Uses the exact symlink /dev/disk/by-id/google-<name> to avoid
# false matches against disks that share a common prefix.
_resolve_disk() {
    local disk_name="$1"
    local by_id="/dev/disk/by-id/google-${disk_name}"

    if [[ ! -L "$by_id" ]]; then
        echo "Error: no disk found with name '${disk_name}' (looked for ${by_id})." >&2
        return 1
    fi

    readlink -f "$by_id"
}

formatdisk() {
    if [[ -z "$1" ]]; then
        echo "Usage: formatdisk <disk_name>" >&2
        return 1
    fi

    local disk_name="$1"
    local disk_dev
    disk_dev=$(_resolve_disk "$disk_name") || return 1

    echo "Detected '${disk_name}' at ${disk_dev}"

    if mount | grep -q "^${disk_dev} "; then
        echo "Error: '${disk_dev}' is currently mounted. Unmount it first." >&2
        return 1
    fi

    sudo mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard "$disk_dev"
    if [[ $? -ne 0 ]]; then
        echo "Error while formatting '${disk_name}' at ${disk_dev}." >&2
        return 1
    fi

    echo "Formatted '${disk_name}' at ${disk_dev}."
}

status() {
    # Resolve host IP (same logic as run.sh)
    local host_ip
    if [[ "$(uname)" == "Darwin" ]]; then
        host_ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "localhost")
    else
        host_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    host_ip=${host_ip:-localhost}

    local public_ip
    public_ip=$(curl -sf --max-time 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')

    local running
    running=$(podman ps --filter "name=ds-" --format "{{.Names}}\t{{.Ports}}" 2>/dev/null)

    if [[ -z "$running" ]]; then
        echo "No ds-env containers running."
        return 0
    fi

    echo "Running containers:"
    while IFS=$'\t' read -r name ports; do
        # Extract host port from patterns like "0.0.0.0:8888->8888/tcp"
        local host_port
        host_port=$(echo "$ports" | grep -oE '0\.0\.0\.0:[0-9]+' | head -1 | cut -d: -f2)
        if [[ -n "$host_port" ]]; then
            if [[ -n "$public_ip" ]]; then
                printf "  %-25s http://%s:%s\n" "$name" "$public_ip" "$host_port"
            else
                printf "  %-25s http://%s:%s\n" "$name" "$host_ip" "$host_port"
            fi
        else
            printf "  %-25s (no port mapping)\n" "$name"
        fi
    done <<< "$running"
}

mountdisk() {
    if [[ -z "$1" || -z "$2" ]]; then
        echo "Usage: mountdisk <disk_name> <mount_location>" >&2
        return 1
    fi

    local disk_name="$1"
    local mount_point="$2"
    local disk_dev
    disk_dev=$(_resolve_disk "$disk_name") || return 1

    echo "Detected '${disk_name}' at ${disk_dev}"

    if mount | grep -q "^${disk_dev} "; then
        echo "Error: '${disk_dev}' is already mounted." >&2
        return 1
    fi

    if [[ ! -d "$mount_point" ]]; then
        echo "Mount point '${mount_point}' does not exist. Creating it..."
        sudo mkdir -p "$mount_point"
    fi

    sudo mount "$disk_dev" "$mount_point"
    if [[ $? -ne 0 ]]; then
        echo "Error while mounting '${disk_name}' at ${mount_point}." >&2
        return 1
    fi

    echo "Mounted '${disk_name}' (${disk_dev}) at ${mount_point}."
}
