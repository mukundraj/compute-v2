#!/usr/bin/env bash
# utils.sh — helper functions for compute-v2

makeuser() {
    # Usage: makeuser [username] [uid:gid] [pubkey-source]
    #   username      default: "${whoami}ai"
    #   uid:gid       default: owner of /mnt/disks/home/<username>
    #   pubkey-source path to a pubkey/authorized_keys file, OR a literal
    #                 "ssh-..." string. If omitted, tries (in order):
    #                   1. /home/$USER/.ssh/authorized_keys
    #                   2. google_authorized_keys $USER  (GCP OS Login)
    local current_user
    current_user="$(whoami)"
    local new_user="${1:-${current_user}ai}"
    local uidgid_arg="$2"
    local pubkey_arg="$3"
    local home_dir="/mnt/disks/home/${new_user}"

    # Check that the home directory already exists on a mounted disk
    if [[ ! -d "$home_dir" ]]; then
        echo "Error: ${home_dir} does not exist or is not a directory." >&2
        echo "Create it on the mounted disk first, then re-run." >&2
        return 1
    fi

    # Resolve target uid/gid: explicit argument wins, else read from the home dir
    local target_uid target_gid
    if [[ -n "$uidgid_arg" ]]; then
        if [[ ! "$uidgid_arg" =~ ^[0-9]+:[0-9]+$ ]]; then
            echo "Error: uid:gid must look like '1234:5678' (got '${uidgid_arg}')." >&2
            return 1
        fi
        target_uid="${uidgid_arg%:*}"
        target_gid="${uidgid_arg#*:}"
    else
        target_uid=$(stat -c '%u' "$home_dir")
        target_gid=$(stat -c '%g' "$home_dir")
        if [[ -z "$target_uid" || -z "$target_gid" ]]; then
            echo "Error: could not read uid/gid from ${home_dir}." >&2
            return 1
        fi
    fi

    # If the user already exists (e.g. auto-provisioned by GCP OS Login on first SSH),
    # renumber them in place instead of failing.
    if id "$new_user" &>/dev/null; then
        echo "User '${new_user}' already exists; adjusting to uid=${target_uid}, gid=${target_gid}..."

        # GCP grants logged-in users sudo via google-sudoers — drop the new account from it
        if id -nG "$new_user" | tr ' ' '\n' | grep -qx google-sudoers; then
            echo "Removing '${new_user}' from google-sudoers..."
            sudo gpasswd -d "$new_user" google-sudoers
        fi

        local current_uid current_gid current_pgroup
        current_uid=$(id -u "$new_user")
        current_gid=$(id -g "$new_user")
        current_pgroup=$(id -gn "$new_user")

        # Update primary gid if changing
        if [[ "$current_gid" != "$target_gid" ]]; then
            local target_gid_group
            target_gid_group=$(getent group "$target_gid" | cut -d: -f1)
            if [[ -n "$target_gid_group" ]]; then
                # Some group already owns target_gid — point the user at it
                sudo usermod -g "$target_gid" "$new_user"
            else
                # Renumber the user's current primary group
                sudo groupmod -g "$target_gid" "$current_pgroup"
            fi
        fi

        # Update uid if changing
        if [[ "$current_uid" != "$target_uid" ]]; then
            local target_uid_user
            target_uid_user=$(getent passwd "$target_uid" | cut -d: -f1)
            if [[ -n "$target_uid_user" && "$target_uid_user" != "$new_user" ]]; then
                echo "Error: uid ${target_uid} is already used by '${target_uid_user}'." >&2
                return 1
            fi
            sudo usermod -u "$target_uid" "$new_user"
        fi

        # Point home_dir at the mounted-disk path (without moving files)
        sudo usermod -d "$home_dir" "$new_user"

        sudo chown -R "${target_uid}:${target_gid}" "$home_dir"
        sudo chmod 750 "$home_dir"

        echo "Adjusted '${new_user}': uid=${target_uid}, gid=${target_gid}, home=${home_dir}."
    else
        # === Create new user ===

        local existing_uid_user
        existing_uid_user=$(getent passwd "$target_uid" | cut -d: -f1)
        if [[ -n "$existing_uid_user" ]]; then
            echo "Error: uid ${target_uid} is already used by '${existing_uid_user}'." >&2
            return 1
        fi

        # Create a matching group if that gid isn't already taken
        if ! getent group "$target_gid" >/dev/null; then
            sudo groupadd --gid "$target_gid" "$new_user"
        fi

        echo "Creating user '${new_user}' (uid=${target_uid}, gid=${target_gid}) with home ${home_dir}..."

        # Create user without a default home dir, pointing at the mounted-disk path
        sudo useradd --no-create-home --shell /bin/bash --home-dir "$home_dir" \
            --uid "$target_uid" --gid "$target_gid" "$new_user"

        # Copy default shell config files
        sudo cp /etc/skel/.bash* "$home_dir"/
        sudo chown "${target_uid}:${target_gid}" "$home_dir"/.*

        # Set ownership on the home directory
        sudo chown -R "${target_uid}:${target_gid}" "$home_dir"
        sudo chmod 750 "$home_dir"
    fi

    # Seed SSH access. Never clobbers an existing authorized_keys.
    local dst_ssh="${home_dir}/.ssh"

    if [[ -f "${dst_ssh}/authorized_keys" ]]; then
        echo "${dst_ssh}/authorized_keys already present — leaving SSH config alone."
    else
        # Resolve pubkey content from: explicit arg, ~/.ssh/authorized_keys,
        # or google_authorized_keys (works under GCP OS Login).
        local pubkey_content="" pubkey_src_desc=""

        if [[ -n "$pubkey_arg" ]]; then
            if [[ -f "$pubkey_arg" ]]; then
                pubkey_content=$(cat "$pubkey_arg")
                pubkey_src_desc="$pubkey_arg"
            elif [[ "$pubkey_arg" =~ ^(ssh-|ecdsa-|sk-) ]]; then
                pubkey_content="$pubkey_arg"
                pubkey_src_desc="argument"
            else
                echo "Error: pubkey arg '${pubkey_arg}' is neither a readable file nor an 'ssh-…' string." >&2
                return 1
            fi
        fi

        if [[ -z "$pubkey_content" && -s "/home/${current_user}/.ssh/authorized_keys" ]]; then
            pubkey_content=$(sudo cat "/home/${current_user}/.ssh/authorized_keys")
            pubkey_src_desc="/home/${current_user}/.ssh/authorized_keys"
        fi

        if [[ -z "$pubkey_content" ]] && command -v google_authorized_keys >/dev/null 2>&1; then
            pubkey_content=$(sudo google_authorized_keys "$current_user" 2>/dev/null || true)
            [[ -n "$pubkey_content" ]] && pubkey_src_desc="google_authorized_keys ${current_user}"
        fi

        if [[ -z "$pubkey_content" ]]; then
            echo "Error: no public key found to seed SSH access for '${new_user}'." >&2
            echo "Tried:" >&2
            echo "  - /home/${current_user}/.ssh/authorized_keys" >&2
            echo "  - google_authorized_keys ${current_user}" >&2
            echo "Pass an explicit pubkey file or 'ssh-…' string as the 3rd argument:" >&2
            echo "  makeuser ${new_user} ${target_uid}:${target_gid} /path/to/pubkey" >&2
            return 1
        fi

        echo "Seeding ${dst_ssh}/authorized_keys from ${pubkey_src_desc}..."
        sudo install -d -m 700 -o "$target_uid" -g "$target_gid" "$dst_ssh"
        printf '%s\n' "$pubkey_content" | sudo tee "${dst_ssh}/authorized_keys" >/dev/null
        sudo chown "${target_uid}:${target_gid}" "${dst_ssh}/authorized_keys"
        sudo chmod 600 "${dst_ssh}/authorized_keys"
    fi

    # Symlink the shared service-account key into the new user's home dir
    local sa_key_src="/opt/claude-default-sa-key.json"
    local sa_key_link="${home_dir}/claude-default-sa-key.json"
    if [[ ! -e "$sa_key_src" ]]; then
        echo "Note: ${sa_key_src} not present — skipping SA key symlink."
    elif [[ -e "$sa_key_link" || -L "$sa_key_link" ]]; then
        echo "${sa_key_link} already exists — leaving it alone."
    else
        sudo ln -s "$sa_key_src" "$sa_key_link"
        sudo chown -h "${target_uid}:${target_gid}" "$sa_key_link"
        echo "Linked ${sa_key_link} -> ${sa_key_src}"
    fi

    # Copy the shared config.env into the new user's home dir
    local config_src="/opt/compute-v2/config.env"
    local config_dst="${home_dir}/config.env"
    if [[ ! -f "$config_src" ]]; then
        echo "Note: ${config_src} not present — skipping config.env copy."
    elif [[ -e "$config_dst" ]]; then
        echo "${config_dst} already exists — leaving it alone."
    else
        sudo cp "$config_src" "$config_dst"
        sudo chown "${target_uid}:${target_gid}" "$config_dst"
        echo "Copied ${config_src} -> ${config_dst}"
    fi

    # Symlink setup.sh -> /opt/compute-v2/setup-linux.sh so the new user can just run ./setup.sh
    local setup_src="/opt/compute-v2/setup-linux.sh"
    local setup_link="${home_dir}/setup.sh"
    if [[ ! -e "$setup_src" ]]; then
        echo "Note: ${setup_src} not present — skipping setup symlink."
    elif [[ -e "$setup_link" || -L "$setup_link" ]]; then
        echo "${setup_link} already exists — leaving it alone."
    else
        sudo ln -s "$setup_src" "$setup_link"
        sudo chown -h "${target_uid}:${target_gid}" "$setup_link"
        echo "Linked ${setup_link} -> ${setup_src}"
    fi

    # Resolve the machine's public IP (GCP metadata first, then external services)
    local public_ip=""
    if command -v curl >/dev/null 2>&1; then
        public_ip=$(curl -sf --max-time 2 -H "Metadata-Flavor: Google" \
            "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" 2>/dev/null || true)
        if [[ -z "$public_ip" ]]; then
            public_ip=$(curl -sf --max-time 3 https://ifconfig.me 2>/dev/null \
                || curl -sf --max-time 3 https://icanhazip.com 2>/dev/null \
                || true)
            public_ip="${public_ip//$'\n'/}"
        fi
    fi

    if [[ -n "$public_ip" ]]; then
        echo "Done. '${new_user}' can SSH in: ssh ${new_user}@${public_ip}"
    else
        echo "Done. '${new_user}' can SSH in: ssh ${new_user}@<host>"
        echo "(Could not determine public IP automatically.)"
    fi
}

# Resolve a disk identifier to its whole-disk /dev path. Accepts, in order:
#   1. a block-device path (e.g. /dev/sdb, /dev/disk/by-id/google-home)
#   2. a GCP device name → /dev/disk/by-id/google-<name>
#   3. a mount point (e.g. /mnt/disks/home)
#   4. an lsblk SERIAL match (GCP sets serial == device name; useful when
#      the by-id symlink is missing on some images)
# Always returns the whole-disk device, never a partition — partition-aware
# callers (refreshdisk) walk back down via lsblk.
_resolve_disk() {
    local arg="$1"
    local dev=""

    if [[ -b "$arg" ]]; then
        dev=$(readlink -f "$arg")
    elif [[ -L "/dev/disk/by-id/google-${arg}" ]]; then
        dev=$(readlink -f "/dev/disk/by-id/google-${arg}")
    elif [[ -d "$arg" ]] && mountpoint -q "$arg" 2>/dev/null; then
        dev=$(findmnt -no SOURCE --target "$arg" 2>/dev/null)
    else
        local match
        match=$(lsblk -ndo NAME,SERIAL 2>/dev/null \
            | awk -v s="$arg" '$2 == s {print "/dev/"$1; exit}')
        [[ -n "$match" && -b "$match" ]] && dev="$match"
    fi

    if [[ -z "$dev" || ! -b "$dev" ]]; then
        echo "Error: no disk found matching '${arg}'." >&2
        echo "Tried: block-device path, /dev/disk/by-id/google-${arg}, mount point, lsblk SERIAL." >&2
        if compgen -G "/dev/disk/by-id/google-*" >/dev/null; then
            echo "Available GCP device names (under /dev/disk/by-id/):" >&2
            ls /dev/disk/by-id/google-* 2>/dev/null \
                | sed 's|.*/google-|  |' \
                | grep -v '\-part[0-9]*$' >&2
        fi
        return 1
    fi

    # Walk up to the whole-disk device in case we landed on a partition.
    local pkname
    pkname=$(lsblk -nro PKNAME "$dev" 2>/dev/null | head -n1)
    if [[ -n "$pkname" ]]; then
        echo "/dev/${pkname}"
    else
        echo "$dev"
    fi
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

    # Add to /etc/fstab so the disk mounts automatically on boot.
    local uuid
    uuid=$(sudo blkid -s UUID -o value "$disk_dev")
    if [[ -z "$uuid" ]]; then
        echo "Warning: could not read UUID for ${disk_dev} — skipping fstab entry." >&2
        return 0
    fi

    local fstab_entry="UUID=${uuid} ${mount_point} ext4 defaults,nofail 0 2"
    if grep -qsF "UUID=${uuid}" /etc/fstab; then
        echo "fstab already has an entry for UUID=${uuid} — skipping."
    else
        echo "$fstab_entry" | sudo tee -a /etc/fstab > /dev/null
        echo "Added fstab entry: ${fstab_entry}"
    fi
}

unmountdisk() {
    if [[ -z "$1" ]]; then
        echo "Usage: unmountdisk <disk_name>" >&2
        return 1
    fi

    local disk_name="$1"
    local disk_dev
    disk_dev=$(_resolve_disk "$disk_name") || return 1

    echo "Detected '${disk_name}' at ${disk_dev}"

    if ! mount | grep -q "^${disk_dev} "; then
        echo "Error: '${disk_dev}' is not currently mounted." >&2
        return 1
    fi

    sudo umount "$disk_dev"
    if [[ $? -ne 0 ]]; then
        echo "Error while unmounting '${disk_name}' at ${disk_dev}." >&2
        return 1
    fi

    echo "Unmounted '${disk_name}' (${disk_dev})."

    # Remove the matching UUID line from /etc/fstab.
    local uuid
    uuid=$(sudo blkid -s UUID -o value "$disk_dev")
    if [[ -z "$uuid" ]]; then
        echo "Warning: could not read UUID for ${disk_dev} — fstab entry not removed." >&2
        return 0
    fi

    if grep -qsF "UUID=${uuid}" /etc/fstab; then
        sudo sed -i "/UUID=${uuid}/d" /etc/fstab
        echo "Removed fstab entry for UUID=${uuid}."
    else
        echo "No fstab entry found for UUID=${uuid}."
    fi
}

# Pick up extra space after a cloud-side disk resize: grows the partition
# (if there is one) and the ext4 filesystem in place. Online-safe — the
# disk can stay mounted. Handles raw ext4 (no partition table, as written
# by formatdisk) and single-partition disks.
refreshdisk() {
    if [[ -z "$1" ]]; then
        echo "Usage: refreshdisk <disk_name>" >&2
        return 1
    fi

    local disk_name="$1"
    local disk_dev
    disk_dev=$(_resolve_disk "$disk_name") || return 1

    echo "Detected '${disk_name}' at ${disk_dev}"

    # Resize target: a unique resizable partition, else the raw device.
    # "Resizable" = mounted AND ext2/3/4. That picks /dev/sda1 cleanly on a
    # GCP boot disk (sda1 ext4 root, sda14 BIOS-boot no-FS, sda15 vfat EFI).
    local target="$disk_dev"
    local parts
    parts=$(lsblk -nrpo NAME "$disk_dev" | tail -n +2)
    if [[ -n "$parts" ]]; then
        local part_count
        part_count=$(echo "$parts" | wc -l)
        if [[ "$part_count" -eq 1 ]]; then
            target=$(echo "$parts" | tail -n1)
        else
            local candidates
            candidates=$(lsblk -nrpo NAME,FSTYPE,MOUNTPOINT "$disk_dev" \
                | awk '$2 ~ /^ext[234]$/ && $3 != "" {print $1}')
            local cand_count
            cand_count=$(echo "$candidates" | grep -c .)
            if [[ "$cand_count" -eq 1 ]]; then
                target="$candidates"
            else
                echo "Error: '${disk_name}' has multiple partitions and ${cand_count} mounted ext2/3/4 candidates — can't pick one safely." >&2
                echo "Partition layout:" >&2
                lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT "$disk_dev" | sed 's/^/  /' >&2
                echo "Resize the specific partition manually: sudo growpart <disk> <num> && sudo resize2fs <partition>" >&2
                return 1
            fi
        fi
        local part_num="${target##*[!0-9]}"

        if ! command -v growpart >/dev/null 2>&1; then
            echo "Error: 'growpart' not installed (needed to extend the partition). Install cloud-guest-utils and retry." >&2
            return 1
        fi

        echo "Growing partition ${target} (number ${part_num}) on ${disk_dev}..."
        # growpart exits 1 with "NOCHANGE" when there's nothing to do — that's fine.
        local gp_out
        if ! gp_out=$(sudo growpart "$disk_dev" "$part_num" 2>&1); then
            if [[ "$gp_out" == *NOCHANGE* ]]; then
                echo "Partition already at max size — nothing to grow."
            else
                echo "Error: growpart failed: ${gp_out}" >&2
                return 1
            fi
        else
            echo "$gp_out"
        fi
    fi

    local mountpt
    mountpt=$(lsblk -nro MOUNTPOINT "$target" | head -n1)
    if [[ -n "$mountpt" ]]; then
        echo "Before:"
        df -h "$mountpt" | sed 's/^/  /'
    fi

    echo "Running resize2fs on ${target}..."
    if ! sudo resize2fs "$target"; then
        echo "Error: resize2fs failed for ${target}." >&2
        return 1
    fi

    if [[ -n "$mountpt" ]]; then
        echo "After:"
        df -h "$mountpt" | sed 's/^/  /'
    fi

    echo "Refreshed '${disk_name}' (${target})."
}
