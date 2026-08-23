#!/bin/bash
# Device discovery and management

# ============================================================
# List all external NTFS and ext4 devices
# ============================================================
list_ntfs_devices() {
    local external_disks
    external_disks="$(diskutil list external 2>/dev/null | grep -oE 'disk[0-9]+' | sort -u)" || true

    if [ -z "$external_disks" ]; then
        info "No external disks found."
        return 0
    fi

    echo ""
    bold "External Devices (NTFS / ext4)"
    echo "─────────────────────────────────────────────────────────────"
    printf "  %-12s %-8s %-20s %-10s %-8s %s\n" "DEVICE" "FS" "VOLUME" "SIZE" "MODE" "MOUNT POINT"
    echo "─────────────────────────────────────────────────────────────"

    local found=0
    local disk_entry
    while IFS= read -r disk_entry; do
        [ -z "$disk_entry" ] && continue

        local partitions
        partitions="$(diskutil list "/dev/$disk_entry" 2>/dev/null \
            | grep -oE 'disk[0-9]+s[0-9]+' \
            | sort -u)" || true

        if [ -z "$partitions" ]; then
            partitions="$disk_entry"
        fi

        while IFS= read -r part; do
            [ -z "$part" ] && continue

            local fs_kind vol_name mount_point size mode fs_label
            fs_kind="$(detect_fs_type "/dev/$part")" || continue
            vol_name="$(diskutil info "/dev/$part" 2>/dev/null \
                | grep "Volume Name:" | awk -F': ' '{print $2}' | xargs)" || true
            if [ "$vol_name" = "Not applicable (no file system)" ] || [ -z "$vol_name" ]; then
                vol_name="$(diskutil info "/dev/$part" 2>/dev/null \
                    | grep "Device / Media Name:" | awk -F': ' '{print $2}' | xargs)"
            fi
            vol_name="${vol_name:-$part}"

            mount_point="$(diskutil info "/dev/$part" 2>/dev/null \
                | grep "Mount Point:" | awk -F': ' '{print $2}' | xargs)" || true
            [ "$mount_point" = "Not mounted" ] && mount_point=""

            size="$(diskutil info "/dev/$part" 2>/dev/null \
                | grep "Disk Size:" | sed -E 's/.*Disk Size:[[:space:]]*//' | sed -E 's/[[:space:]]*\(.*/ /' | awk '{print $1, $2}')" || true

            if [ "$fs_kind" = "ntfs" ]; then
                fs_label="NTFS"
                if mount | grep -q "ntfs-3g.*$part"; then
                    mode="RW"
                elif [ -n "$mount_point" ]; then
                    mode="RO"
                else
                    mode="--"
                fi
            else
                fs_label="ext4"
                if mount | grep -qE "ext4fuse.*$part|fuse-ext2.*$part"; then
                    mode="RO"
                else
                    mode="--"
                fi
            fi

            printf "  ${CYAN}%-12s${NC} %-8s %-20s %-10s %-8s %s\n" \
                "$part" "$fs_label" "$vol_name" "${size:-N/A}" "$mode" "${mount_point:-not mounted}"
            found=1
        done <<< "$partitions"
    done <<< "$external_disks"

    echo "─────────────────────────────────────────────────────────────"

    if [ "$found" -eq 0 ]; then
        info "No NTFS or ext4 partitions found on external disks."
    else
        echo ""
        echo "  NTFS: RO = macOS native, RW = ntfs-3g  |  ext4: RO = ext4fuse (read-only only)"
    fi
    echo ""
}

# ============================================================
# Show device status overview
# ============================================================
show_status() {
    echo ""
    bold "Device Status Overview"
    echo "─────────────────────────────────────────────────────────────"

    local rw_count=0 ro_count=0 ext4_count=0

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local dev part vol
        dev="$(echo "$line" | awk '{print $1}')"
        part="$(dev_name "$dev")"
        vol="$(echo "$line" | awk '{print $3}')"
        ok "  $part -> $vol (NTFS read-write via ntfs-3g)"
        rw_count=$((rw_count + 1))
    done < <(mount | grep "ntfs-3g" || true)

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local dev part vol
        dev="$(echo "$line" | awk '{print $1}')"
        part="$(dev_name "$dev")"
        vol="$(echo "$line" | awk '{print $3}')"
        mount | grep -q "ntfs-3g.*$part" && continue
        warn "  $part -> $vol (NTFS read-only)"
        ro_count=$((ro_count + 1))
    done < <(mount | grep ntfs | grep -v "ntfs-3g" || true)

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local dev part vol
        dev="$(echo "$line" | awk '{print $1}')"
        part="$(dev_name "$dev")"
        vol="$(echo "$line" | awk '{print $3}')"
        ok "  $part -> $vol (ext4 read-only via ext4fuse)"
        ext4_count=$((ext4_count + 1))
    done < <(mount | grep -E "ext4fuse|fuse-ext2" || true)

    echo "─────────────────────────────────────────────────────────────"
    echo "  NTFS read-write (ntfs-3g): $rw_count"
    echo "  NTFS read-only (macOS):    $ro_count"
    echo "  ext4 mounted (ext4fuse):   $ext4_count"
    echo ""
}
