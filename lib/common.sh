#!/bin/bash
# Common utilities: colors, logging, path helpers

# ============================================================
# Colors (auto-detect terminal support)
# ============================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# ============================================================
# Logging
# ============================================================
info()  { echo -e "${BLUE}i${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }
bold()  { echo -e "${BOLD}$*${NC}"; }

# ============================================================
# Device path helpers
# ============================================================
# Normalize device input: accept "disk4s1" or "/dev/disk4s1"
dev_path() {
    local d="$1"
    [[ "$d" == /* ]] && echo "$d" || echo "/dev/$d"
}

dev_name() {
    local d="$1"
    echo "${d#/dev/}"
}

# ============================================================
# macOS version check
# ============================================================
check_macos() {
    local ver
    ver="$(sw_vers -productVersion 2>/dev/null)" || true
    local major="${ver%%.*}"

    if [ -z "$major" ] || [ "$major" -lt 14 ]; then
        warn "macOS $ver detected. This tool requires macOS 14 (Sonoma) or later."
        echo "  Some features may not work. Continue anyway..."
    fi
}

# ============================================================
# Find ntfs-3g binary
# ============================================================
find_ntfs3g() {
    local path
    path="$(which ntfs-3g 2>/dev/null)" || true
    [ -n "$path" ] && echo "$path" && return 0

    for p in /opt/homebrew/bin/ntfs-3g /usr/local/bin/ntfs-3g; do
        [ -f "$p" ] && echo "$p" && return 0
    done

    return 1
}

# ============================================================
# Find ntfsfix binary
# ============================================================
find_ntfsfix() {
    local path
    path="$(which ntfsfix 2>/dev/null)" || true
    [ -n "$path" ] && echo "$path" && return 0

    for p in /opt/homebrew/bin/ntfsfix /usr/local/bin/ntfsfix; do
        [ -f "$p" ] && echo "$p" && return 0
    done

    return 1
}

# Safely unmount ntfs-3g and clear NTFS dirty flag for Linux/Windows
unmount_ntfs3g_volume() {
    local dev="$1"
    local mount_path="${2:-}"
    local raw_dev ntfsfix

    if [ -z "$mount_path" ]; then
        local vol_name
        vol_name="$(diskutil info "$dev" 2>/dev/null | grep "Volume Name:" | awk -F': ' '{print $2}' | xargs)" || true
        mount_path="/Volumes/${vol_name:-$(dev_name "$dev")}"
    fi

    sync
    if mount | grep -qF " on $mount_path ("; then
        umount "$mount_path" 2>/dev/null || true
        sleep 1
        umount -f "$mount_path" 2>/dev/null || true
    fi
    pkill -f "ntfs-3g.*$mount_path" 2>/dev/null || true
    pkill -f "ntfs-3g.*$(dev_name "$dev")" 2>/dev/null || true
    sleep 0.5
    if mount | grep -qF " on $mount_path ("; then
        diskutil unmount force "$mount_path" 2>/dev/null || true
    fi
    umount -f "$dev" 2>/dev/null || true
    diskutil unmount force "$dev" 2>/dev/null || true
    sync
    sleep 0.5

    run_ntfsfix "$dev"
}

# Clear NTFS dirty flag (-d) so Linux/Windows can mount the volume
run_ntfsfix() {
    local dev="$1"
    local raw_dev="${dev/disk/rdisk}"
    local ntfsfix

    ntfsfix="$(find_ntfsfix)" || return 0
    [ -e "$raw_dev" ] || raw_dev="$dev"
    "$ntfsfix" -d "$raw_dev" 2>/dev/null || "$ntfsfix" -d "$dev" 2>/dev/null || true
}

# Mount NTFS read-write via ntfs-3g (background daemon)
mount_ntfs3g_volume() {
    local dev="$1"
    local mount_path="$2"
    local ntfs3g="$3"
    local vol_name="$4"
    local fuse_pid

    [ -d "$mount_path" ] || mkdir -p "$mount_path"
    run_ntfsfix "$dev"

    "$ntfs3g" "$dev" "$mount_path" \
        -o auto_xattr -o "volname=$vol_name" -o local -o remove_hiberfile -o sync &
    fuse_pid=$!

    if wait_for_mount_point "$mount_path" "$fuse_pid"; then
        return 0
    fi

    kill "$fuse_pid" 2>/dev/null || true
    return 1
}

# ============================================================
# Find ext4fuse binary
# ============================================================
find_ext4fuse() {
    local path
    path="$(which ext4fuse 2>/dev/null)" || true
    [ -n "$path" ] && echo "$path" && return 0

    for p in /opt/homebrew/bin/ext4fuse /usr/local/bin/ext4fuse; do
        [ -f "$p" ] && echo "$p" && return 0
    done

    return 1
}

# ============================================================
# Detect filesystem type from diskutil info
# Returns: ntfs, ext4, or empty
# ============================================================
detect_fs_type() {
    local dev="$1"
    local fs_type partition_type content
    fs_type="$(diskutil info "$dev" 2>/dev/null | grep "Type (Bundle):" | awk -F': ' '{print $2}')" || true
    partition_type="$(diskutil info "$dev" 2>/dev/null | grep "Partition Type:" | awk -F': ' '{print $2}')" || true
    content="$(diskutil info "$dev" 2>/dev/null | grep "Content (IOContent):" | awk -F': ' '{print $2}' | xargs)" || true

    if [[ "$fs_type" == *NTFS* || "$fs_type" == *ntfs* \
        || "$partition_type" == *NTFS* || "$partition_type" == *ntfs* ]]; then
        echo "ntfs"
        return 0
    fi

    if [[ "$fs_type" == *ext4* || "$partition_type" == *ext4* ]]; then
        echo "ext4"
        return 0
    fi

    if [[ "$partition_type" == *Linux* && "$partition_type" != *Swap* && "$partition_type" != *LVM* ]]; then
        echo "ext4"
        return 0
    fi

    if [[ "$content" == "None" || -z "$content" ]]; then
        local raw_dev="${dev/disk/rdisk}"
        [ ! -e "$raw_dev" ] && raw_dev="$dev"
        local magic
        magic="$(dd if="$raw_dev" bs=1 skip=1080 count=2 2>/dev/null | xxd -p)" || true
        if [ "$magic" = "53ef" ]; then
            echo "ext4"
            return 0
        fi
        magic="$(dd if="$raw_dev" bs=1 skip=3 count=5 2>/dev/null)" || true
        if [ "$magic" = "NTFS " ]; then
            echo "ntfs"
            return 0
        fi
        if diskutil info "$dev" 2>/dev/null | grep -q "Device Location:.*External"; then
            echo "ext4"
            return 0
        fi
    fi

    return 1
}

# ============================================================
# Force-unmount ext4 FUSE volume (umount alone often fails)
# ============================================================
unmount_ext4_volume() {
    local mount_path="$1"
    diskutil unmount force "$mount_path" 2>/dev/null || true
    pkill -f "ext4fuse.*$mount_path" 2>/dev/null || true
    sleep 0.5
    umount -f "$mount_path" 2>/dev/null || true
    diskutil unmount force "$mount_path" 2>/dev/null || true
}

# Returns 0 when mount_path is active in the mount table
is_mount_path_active() {
    local mount_path="$1"
    mount | grep -qF " on $mount_path (" && return 0
    mount | grep -qF " on $mount_path," && return 0
    return 1
}

# Wait until a mount point appears (FUSE daemons may fork and exit early)
wait_for_mount_point() {
    local mount_path="$1"
    local _fuse_pid="${2:-}"
    local attempt

    for attempt in $(seq 1 30); do
        if is_mount_path_active "$mount_path"; then
            return 0
        fi
        sleep 0.5
    done

    is_mount_path_active "$mount_path"
}

# Mount ext4 via ext4fuse (must run as root)
mount_ext4_fuse() {
    local dev="$1"
    local mount_path="$2"
    local ext4fuse="$3"
    local console_user console_uid console_gid fuse_pid

    console_user="$(stat -f '%Su' /dev/console)"
    console_uid="$(id -u "$console_user")"
    console_gid="$(id -g "$console_user")"

    unmount_ext4_volume "$mount_path"
    [ -d "$mount_path" ] || mkdir -p "$mount_path"

    "$ext4fuse" "$dev" "$mount_path" \
        -o allow_other -o defer_permissions -o "uid=$console_uid" -o "gid=$console_gid" &
    fuse_pid=$!

    if wait_for_mount_point "$mount_path" "$fuse_pid"; then
        return 0
    fi

    kill "$fuse_pid" 2>/dev/null || true
    return 1
}
