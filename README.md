# NTFS4Mac

A lightweight macOS tool for NTFS read/write and ext4 read-only support. Built with SwiftUI for macOS 14+ (Sonoma, Sequoia, Tahoe).

<p align="center">
English | <a href="README_CN.md">简体中文</a>
</p>

![Screenshot](assets/NTFS.png)

## Features

- **One-click read-write mount** - Remount NTFS volumes via ntfs-3g with a single click
- **ext4 read-only mount** - Mount Linux ext4 drives via ext4fuse (macOS has no native ext4 support)
- **Auto device detection** - File system watcher + polling detects new drives in real time
- **Open in Finder** - Quick access to mounted volumes
- **Native macOS experience** - SwiftUI, dark mode, minimal UI
- **CLI included** - Full-featured command-line tool for scripts and automation

## How It Works

macOS natively mounts NTFS volumes as read-only and does not support ext4 at all. This tool remounts NTFS in read-write mode using [ntfs-3g](https://github.com/tuxera/ntfs-3g), and mounts ext4 in read-only mode using [ext4fuse](https://github.com/gerard/ext4fuse), both via [fuse-t](https://github.com/macos-fuse-t/fuse-t).

## Requirements

| OS | Status |
|---|---|
| **macOS 26 (Tahoe)** | Tested |
| **macOS 15 (Sequoia)** | Compatible (untested) |
| **macOS 14 (Sonoma)** | Compatible (untested) |

## Installation

### One-Click Setup

Run this command in Terminal to automatically install all dependencies:

```bash
curl -fsSL https://raw.githubusercontent.com/zhouyeyu/NTFS4Mac/main/setup.sh | bash
```

### Manual Setup

| Dependency | Purpose | Install |
|---|---|---|
| **macOS 14+** | Required | System Settings > Software Update |
| **fuse-t** | File system framework | Download from [fuse-t releases](https://github.com/macos-fuse-t/fuse-t/releases) |
| **ntfs-3g** | NTFS read-write driver | `brew tap gromgit/fuse && brew install ntfs-3g-mac` |
| **ext4fuse** | ext4 read-only driver | `brew tap gromgit/fuse && brew install ext4fuse-mac` |

### Install fuse-t

1. Download `fuse-t-macos-installer-X.X.X.pkg` from [fuse-t releases](https://github.com/macos-fuse-t/fuse-t/releases)
2. Double-click to install
3. Grant **Full Disk Access** to `fuse-t.app` in System Settings > Privacy & Security

### Link fuse-t library

After installing fuse-t, link the library for ntfs-3g:

```bash
sudo mv /usr/local/lib/libfuse.2.dylib /usr/local/lib/libfuse.2.dylib.bak
sudo ln -sf libfuse-t.dylib /usr/local/lib/libfuse.2.dylib
```

### Install Application

Download the latest [DMG from Releases](../../releases) and drag `NTFS4Mac.app` to `/Applications`.

Or build from source:

```bash
git clone https://github.com/zhouyeyu/NTFS4Mac.git
cd NTFS4Mac
bash build-dmg.sh
```

### Install CLI Tool

```bash
git clone https://github.com/zhouyeyu/NTFS4Mac.git
cd NTFS4Mac
make install
```

## Usage

### GUI

Launch `NTFS4Mac.app`. Insert an NTFS or ext4 drive.

- **NTFS**: Click **Mount RW** for read-write access
- **ext4**: Click **Mount** for read-only access (ext4 write support is not available on macOS)

- **RW** (green) = Read-write mode (NTFS via ntfs-3g)
- **RO** (orange) = Read-only mode
- **--** (gray) = Not mounted

Click the folder icon to open the volume in Finder.

### CLI

```bash
ntfs-cli list               # List all NTFS and ext4 devices
ntfs-cli mount disk4s1      # Mount (NTFS: RW, ext4: RO)
ntfs-cli unmount disk4s1    # Unmount
ntfs-cli eject disk4s1      # Eject (safe to remove)
ntfs-cli restore disk4s1    # Restore NTFS to macOS read-only
ntfs-cli watch              # Auto-mount new devices
ntfs-cli status             # Show mount status
ntfs-cli deps               # Check dependencies
```

## Build

```bash
swift build -c release      # Build GUI app
bash build-dmg.sh           # Build and package DMG
make install PREFIX=/usr/local  # Build CLI only
```

## Project Structure

```
NTFS4Mac/
├── NTFS4Mac/                    # SwiftUI macOS app
│   ├── App/NTFS4MacApp.swift
│   ├── Models/NTFSDevice.swift
│   ├── Services/
│   │   ├── Shell.swift
│   │   ├── DeviceService.swift
│   │   ├── MountService.swift
│   │   └── DeviceWatcher.swift
│   └── Views/
│       ├── DeviceListView.swift
│       └── DeviceRow.swift
├── lib/                         # CLI scripts
├── ntfs-cli.sh                  # CLI entry point
├── setup.sh                     # One-click setup script
├── Package.swift
├── build-dmg.sh
└── Makefile
```

## Known Issues

- **First launch on macOS**: You may need to right-click > Open the app on first launch since it's not signed.
- **ntfs-3g needs macFUSE to start**: the `ntfs-3g-mac` formula links macFUSE's `MFMount.framework` without using it. `setup.sh` points that link at an empty stub so macFUSE (and its kernel extension / Reduced Security) is not needed. Re-run `bash lib/unlink-mfmount.sh` after `brew upgrade ntfs-3g-mac`. Installing macFUSE afterwards replaces the fuse-t `libfuse.2.dylib` link; re-run `setup.sh` to restore it.

## License

MIT License

Copyright (c) 2026 zhouyeyu

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
