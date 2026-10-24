#!/bin/bash
# Point ntfs-3g's leftover MFMount (macFUSE) link at an empty stub so it runs with
# fuse-t alone. ntfs-3g-mac links MFMount.framework but imports no symbols from it.
# Re-run after `brew reinstall` / `brew upgrade` of ntfs-3g-mac.

set -euo pipefail

MFMOUNT="/Library/Filesystems/macfuse.fs/Contents/Frameworks/MFMount.framework/Versions/A/MFMount"

prefix="$(brew --prefix ntfs-3g-mac 2>/dev/null)" || { echo "ntfs-3g-mac is not installed"; exit 1; }
cellar="$(cd "$prefix" && pwd -P)"
stub="$cellar/lib/libmfmount-stub.dylib"

if [ ! -f "$stub" ]; then
    echo 'void ntfs4mac_mfmount_stub(void) {}' \
        | clang -dynamiclib -x c - -install_name "$stub" -o "$stub"
fi

for bin in "$cellar"/bin/*; do
    if [ -L "$bin" ] || [ ! -f "$bin" ]; then
        continue
    fi
    otool -L "$bin" | grep -qF "$MFMOUNT" || continue
    install_name_tool -change "$MFMOUNT" "$stub" "$bin" 2>/dev/null
    codesign -f -s - "$bin" 2>/dev/null
    echo "patched: $bin"
done
