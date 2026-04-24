# TidyMount 🍏📦

**TidyMount** is a lightweight macOS menu bar utility that ensures your network shares (SMB/AFP/NFS) are always mounted and responsive. It's designed for users who rely on NAS storage and are tired of "Server connection interrupted" errors or empty mount points.

<img width="248" height="323" alt="image" src="https://github.com/user-attachments/assets/9e6c89ad-3ac5-4f9e-b228-07d623b88b86" />

## Features
- **Auto-Mount:** Automatically mounts your configured shares on startup, wake from sleep, or network change.
- **Surgical Cleanup:** Detects and removes "ghost" folders in `/Volumes` that can block new mounts or cause duplicate suffixes (e.g., `-1`, `-2`).
- **Liveness Monitoring:** Periodically checks if shares are responsive and attempts to remount them if they hang.
- **Secure Storage:** Passwords are stored securely and locally only on your machine.
- **Launch at Login:** Option to start TidyMount automatically when you log in.
- **Menu Bar UI:** Quick status overview and manual mount/unmount controls.

## Installation
1. Download the latest `TidyMount.app.zip` from the [Releases](https://github.com/jp2014/TidyMount/releases) page.
2. Unzip and move `TidyMount.app` to your `/Applications` folder.
3. Open the app and configure your shares in **Settings...**.

## Usage
- Click the **TidyMount** icon in your menu bar (a stylized drive with a network link).
- Add a share using its URL (e.g., `smb://server/share`).
- **Optional Credentials:** You can include credentials in the URL format `smb://user:password@server/share`. TidyMount will automatically extract them and store them securely and locally on your machine.

## Build from Source
If you have Swift and Xcode installed, you can build the app locally:
```bash
git clone https://github.com/jp2014/TidyMount.git
cd TidyMount
./build.sh
```

## Requirements
- macOS 13.0 or later.
- Network shares (SMB, AFP, or NFS).

---
*Created by Jordan Petersen.*
