#!/bin/bash
# Mount, unmount, restore operations

# ============================================================
# Mount device (dispatches by filesystem type)
# ============================================================
mount_device() {
    local device="$1"
    local dev="$(dev_path "$device")"

    diskutil info "$dev" &>/dev/null || error "Device $dev not found."

    local fs_kind
    fs_kind="$(detect_fs_type "$dev")" || \
        error "$dev is not a supported filesystem (NTFS or ext4)."

    case "$fs_kind" in
        ntfs) mount_ntfs_device "$device" ;;
        ext4) mount_ext4_device "$device" ;;
    esac
}

# ============================================================
# Mount NTFS device as read-write via ntfs-3g
# ============================================================
mount_ntfs_device() {
    local device="$1"
    local dev="$(dev_path "$device")"

    if mount | grep -q "ntfs-3g.*$(dev_name "$dev")"; then
        warn "Already mounted as read-write via ntfs-3g."
        return 0
    fi

    local vol_name mount_point
    vol_name="$(diskutil info "$dev" 2>/dev/null | grep "Volume Name:" | awk -F': ' '{print $2}')" || true
    vol_name="${vol_name:-$(dev_name "$dev")}"

    mount_point="$(diskutil info "$dev" 2>/dev/null | grep "Mount Point:" | awk -F': ' '{print $2}')" || true

    if [ -n "$mount_point" ]; then
        info "Unmounting macOS read-only mount..."
        sudo umount -f "$dev" 2>/dev/null || \
            sudo diskutil unmount force "$dev" >/dev/null 2>&1 || \
            error "Failed to unmount $dev. Close any apps using this volume and try again."
        ok "Unmounted."
        sleep 0.5
    fi

    sudo mkdir -p "/Volumes/$vol_name"

    local ntfs3g
    ntfs3g="$(find_ntfs3g)" || error "ntfs-3g not found. Run: brew install ntfs-3g-mac"

    info "Mounting $dev as read-write..."
    local mount_args=(
        "$ntfs3g"
        "$dev"
        "/Volumes/$vol_name"
        -o auto_xattr
        -o volname="$vol_name"
        -o local
    )

    local mount_result=0
    if command -v timeout >/dev/null 2>&1; then
        timeout 15 sudo "${mount_args[@]}" 2>&1 || mount_result=$?
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 15 sudo "${mount_args[@]}" 2>&1 || mount_result=$?
    else
        sudo "${mount_args[@]}" 2>&1 &
        local pid=$!
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [ $waited -lt 15 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            sudo kill -9 "$pid" 2>/dev/null
            mount_result=124
        else
            wait "$pid" 2>/dev/null
            mount_result=$?
        fi
    fi

    if [ $mount_result -eq 0 ]; then
        ok "Mounted: /Volumes/$vol_name"
        sudo touch "/tmp/ntfs_mounted_$(dev_name "$dev")" 2>/dev/null || true
    elif [ $mount_result -eq 124 ]; then
        error "Mount timed out (15s). Possible causes:
  - Windows Fast Startup / Hibernation enabled on the drive
  - Corrupted NTFS filesystem
  Fix: Fully shut down Windows (not sleep), or run: ntfsfix /dev/$device"
    else
        error "Mount failed (exit code $mount_result).
  Try: ntfs-3g $dev /Volumes/$vol_name -o force"
    fi
}

# ============================================================
# Mount ext4 device as read-only via ext4fuse
# ============================================================
mount_ext4_device() {
    local device="$1"
    local dev="$(dev_path "$device")"

    local vol_name media_name
    vol_name="$(diskutil info "$dev" 2>/dev/null | grep "Volume Name:" | awk -F': ' '{print $2}' | xargs)" || true
    media_name="$(diskutil info "$dev" 2>/dev/null | grep "Device / Media Name:" | awk -F': ' '{print $2}' | xargs)" || true
    if [ "$vol_name" = "Not applicable (no file system)" ] || [ -z "$vol_name" ]; then
        vol_name="${media_name:-$(dev_name "$dev")}"
    fi

    if mount | grep -qF " on /Volumes/$vol_name ("; then
        warn "Already mounted at /Volumes/$vol_name"
        return 0
    fi

    local ext4fuse
    ext4fuse="$(find_ext4fuse)" || error "ext4fuse not found. Run: brew install ext4fuse-mac"

    info "Mounting $dev as read-only (ext4)..."
    if mount_ext4_fuse "$dev" "/Volumes/$vol_name" "$ext4fuse"; then
        ok "Mounted: /Volumes/$vol_name (read-only)"
        sudo touch "/tmp/ext4_mounted_$(dev_name "$dev")" 2>/dev/null || true
    else
        error "Mount failed. Try: sudo ext4fuse $dev /Volumes/$vol_name -o allow_other -o defer_permissions -o uid=\$(id -u) -o gid=\$(id -g) &"
    fi
}

# ============================================================
# Unmount device
# ============================================================
unmount_device() {
    local device="$1"
    local dev="$(dev_path "$device")"
    local fs_kind
    fs_kind="$(detect_fs_type "$dev")" || fs_kind="unknown"

    if mount | grep -q "ntfs-3g.*$(dev_name "$dev")"; then
        info "Unmounting ntfs-3g mount..."
        sudo umount -f "$dev" 2>/dev/null || error "Failed to unmount $dev."
    elif [ "$fs_kind" = "ext4" ]; then
        local vol_name media_name mount_point
        vol_name="$(diskutil info "$dev" 2>/dev/null | grep "Volume Name:" | awk -F': ' '{print $2}' | xargs)" || true
        media_name="$(diskutil info "$dev" 2>/dev/null | grep "Device / Media Name:" | awk -F': ' '{print $2}' | xargs)" || true
        if [ "$vol_name" = "Not applicable (no file system)" ] || [ -z "$vol_name" ]; then
            vol_name="${media_name:-$(dev_name "$dev")}"
        fi
        mount_point="/Volumes/$vol_name"
        if mount | grep -qF " on $mount_point ("; then
            info "Unmounting ext4fuse mount..."
            unmount_ext4_volume "$mount_point"
            mount | grep -qF " on $mount_point (" && error "Failed to unmount $mount_point."
        else
            info "Unmounting $dev..."
            sudo diskutil unmount force "$dev" >/dev/null 2>&1 || error "Failed to unmount $dev."
        fi
    else
        info "Unmounting $dev..."
        sudo diskutil unmount force "$dev" >/dev/null 2>&1 || error "Failed to unmount $dev."
    fi

    sudo rm -f "/tmp/ntfs_mounted_$(dev_name "$dev")" 2>/dev/null || true
    sudo rm -f "/tmp/ext4_mounted_$(dev_name "$dev")" 2>/dev/null || true
    ok "Unmounted."
}

# ============================================================
# Eject device (physical removal)
# ============================================================
eject_device() {
    local device="$1"
    local dev="$(dev_path "$device")"
    local fs_kind
    fs_kind="$(detect_fs_type "$dev")" || fs_kind="unknown"

    if mount | grep -q "ntfs-3g.*$(dev_name "$dev")"; then
        info "Unmounting ntfs-3g mount..."
        sudo umount -f "$dev" 2>/dev/null || true
        sudo rm -f "/tmp/ntfs_mounted_$(dev_name "$dev")" 2>/dev/null || true
        sleep 0.5
    fi

    if [ "$fs_kind" = "ext4" ]; then
        local vol_name media_name
        vol_name="$(diskutil info "$dev" 2>/dev/null | grep "Volume Name:" | awk -F': ' '{print $2}' | xargs)" || true
        media_name="$(diskutil info "$dev" 2>/dev/null | grep "Device / Media Name:" | awk -F': ' '{print $2}' | xargs)" || true
        if [ "$vol_name" = "Not applicable (no file system)" ] || [ -z "$vol_name" ]; then
            vol_name="${media_name:-$(dev_name "$dev")}"
        fi
        info "Unmounting ext4fuse mount..."
        unmount_ext4_volume "/Volumes/$vol_name"
        mount | grep -qF " on /Volumes/$vol_name (" && error "Failed to unmount /Volumes/$vol_name."
        sudo rm -f "/tmp/ext4_mounted_$(dev_name "$dev")" 2>/dev/null || true
        sleep 0.5
    fi

    info "Ejecting $dev..."
    sudo diskutil eject "$dev" >/dev/null 2>&1 || error "Failed to eject $dev."

    ok "Ejected. Safe to remove."
}

# ============================================================
# Restore to macOS read-only mount (NTFS only)
# ============================================================
restore_readonly() {
    local device="$1"
    local dev="$(dev_path "$device")"

    local fs_kind
    fs_kind="$(detect_fs_type "$dev")" || error "Unknown filesystem on $dev."
    [ "$fs_kind" = "ext4" ] && error "Restore to read-only is only supported for NTFS volumes."

    if mount | grep -q "ntfs-3g.*$(dev_name "$dev")"; then
        info "Unmounting ntfs-3g mount..."
        sudo umount -f "$dev" 2>/dev/null || error "Failed to unmount $dev."

        sudo rm -f "/tmp/ntfs_mounted_$(dev_name "$dev")" 2>/dev/null || true
        sleep 0.5

        info "Waiting for macOS to auto-remount as read-only..."
        local retries=0
        while [ $retries -lt 10 ]; do
            if mount | grep -q "ntfs.*$(dev_name "$dev")"; then
                ok "Restored to macOS read-only mount."
                return 0
            fi
            sleep 1
            retries=$((retries + 1))
        done

        info "Auto-remount didn't trigger, forcing..."
        sudo diskutil mount "$dev" >/dev/null 2>&1 && \
            ok "Restored to macOS read-only mount." || \
            warn "Could not restore. macOS may remount it on reconnection."
    else
        if mount | grep -q "ntfs.*$(dev_name "$dev")"; then
            warn "Already mounted as macOS read-only."
        else
            warn "Device $dev is not currently mounted."
        fi
    fi
}
