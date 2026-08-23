#!/bin/bash
# Device hot-plug detection and auto-mount

# ============================================================
# Cleanup markers for removed devices
# ============================================================
cleanup_markers() {
    for marker in /tmp/ntfs_mounted_* /tmp/ext4_mounted_*; do
        [ -f "$marker" ] || continue
        local dev
        dev="$(basename "$marker" | sed -E 's/(ntfs|ext4)_mounted_//')"
        if ! mount | grep -q "/dev/$dev"; then
            local mount_point
            mount_point="$(mount | grep -E "ext4fuse|fuse-ext2" | grep "$dev" | awk '{print $3}')" || true
            [ -n "$mount_point" ] && mount | grep -q "$mount_point" && continue
            sudo rm -f "$marker" 2>/dev/null || true
        fi
    done
}

# ============================================================
# Polling-based device monitoring
# ============================================================
watch_ntfs_devices() {
    info "Watching for NTFS and ext4 devices (Ctrl+C to stop)..."
    echo ""

    local poll_interval=3
    local use_fswatch=false

    if command -v fswatch >/dev/null 2>&1; then
        info "Using fswatch for instant detection."
        use_fswatch=true
    else
        warn "fswatch not found, using polling every ${poll_interval}s."
        warn "Install fswatch for instant detection: brew install fswatch"
        echo ""
    fi

    trap 'echo ""; info "Stopped."; exit 0' INT TERM

    if [ "$use_fswatch" = true ]; then
        fswatch -r -l 2 --event Created --event Updated \
            /dev /Volumes 2>/dev/null | while read -r _event; do
            handle_new_devices
        done
    else
        while true; do
            cleanup_markers
            handle_new_devices
            sleep "$poll_interval"
        done
    fi
}

# ============================================================
# Handle newly detected devices
# ============================================================
handle_new_devices() {
    # NTFS: auto-mount when macOS mounts read-only
    local ntfs_lines
    ntfs_lines="$(mount | grep ntfs | grep -v ntfs-3g)" || true

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "$line" | grep -q "ntfs-3g" && continue

        local dev vol
        dev="$(echo "$line" | awk '{print $1}')"
        vol="$(echo "$line" | awk '{split($3, a, "/"); print a[3]}')"

        [ -f "/tmp/ntfs_mounted_$(dev_name "$dev")" ] && continue

        echo ""
        info "New NTFS device detected: $vol ($dev)"
        mount_ntfs_device "$(dev_name "$dev")"
        echo ""
    done <<< "$ntfs_lines"

    # ext4: auto-mount when new Linux partition appears (macOS doesn't auto-mount)
    local external_disks
    external_disks="$(diskutil list external 2>/dev/null | grep -oE 'disk[0-9]+' | sort -u)" || true
    [ -z "$external_disks" ] && return 0

    local disk_entry
    while IFS= read -r disk_entry; do
        [ -z "$disk_entry" ] && continue

        local partitions
        partitions="$(diskutil list "/dev/$disk_entry" 2>/dev/null \
            | grep -oE 'disk[0-9]+s[0-9]+' | sort -u)" || true

        while IFS= read -r part; do
            [ -z "$part" ] && continue

            local fs_kind
            fs_kind="$(detect_fs_type "/dev/$part")" || continue
            [ "$fs_kind" != "ext4" ] && continue

            [ -f "/tmp/ext4_mounted_$part" ] && continue
            mount | grep -qE "ext4fuse.*$part|fuse-ext2.*$part" && continue

            echo ""
            info "New ext4 device detected: $part"
            mount_ext4_device "$part"
            echo ""
        done <<< "$partitions"
    done <<< "$external_disks"
}
