# TidyMount 🍏📦

**TidyMount** is a lightweight macOS menu bar utility that ensures your network shares (SMB/AFP/NFS) are always mounted and responsive. It's designed for users who rely on NAS storage and are tired of "Server connection interrupted" errors or empty mount points.

## Features
- **Auto-Mount:** Automatically mounts your configured shares on startup, wake from sleep, or network change.
- **Surgical Cleanup:** Detects and removes "ghost" folders in `/Volumes` that can block new mounts.
- **Liveness Monitoring:** Periodically checks if shares are responsive and attempts to remount them if they hang.
- **Secure Storage:** Uses the **macOS Keychain** to store your NAS credentials securely.
- **Launch at Login:** Option to start TidyMount automatically when you log in.
- **Menu Bar UI:** Quick status overview and manual mount/unmount controls.

## Installation
1. Download the latest `TidyMount.app.zip` from the [Releases](https://github.com/yourusername/TidyMount/releases) page.
2. Unzip and move `TidyMount.app` to your `/Applications` folder.
3. Open the app and configure your shares in **Settings...**.

## Usage
- Click the drive icon in your menu bar (`externaldrive.badge.plus`).
- Add a share using the format: `smb://user:password@server/share`.
- TidyMount will extract the credentials to your Keychain and keep the share mounted.

## Build from Source
If you have Swift and Xcode installed, you can build the app locally:
```bash
git clone https://github.com/yourusername/TidyMount.git
cd TidyMount
./build.sh
```

## Requirements
- macOS 13.0 or later.
- Network shares (SMB, AFP, or NFS).

---
*Created by Jordan Petersen.*
