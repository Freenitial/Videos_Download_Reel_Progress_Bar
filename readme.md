# Videos Download Reel Progress Bar

__CREDITS TO YT-DLP https://github.com/yt-dlp/yt-dlp/__

__CREDITS TO BtbN FFmpeg BUILDS https://github.com/BtbN/FFmpeg-Builds__

---

## Description

Add controls to Videos for supported websites : 
- Youtube
- Facebook
- Instagram
- TikTok 
- X (Twitter)

## Features : 
- Progress bar for reels with memorized volume, kept in sync with each site's own volume slider
- Same volume on all sites (option)
- Download as Video (original), with quality presets: Best, 1080p, 720p, ≤ 25 MB
- Download and convert as MP4 (H.264 / AAC)
- Download and convert as MP3
- Cut / Trim, with In / Out from the playing position
- Drag a finished download straight into a folder, the desktop or an app (Discord, mail…)
- Downloads history on the toolbar icon: show, copy, retry or drag again
- Download folder and optional subfolder per site
- Downloads keep running when the tab is closed

![image](https://github.com/user-attachments/assets/a7586200-3f58-4adc-9e0e-79d9a91f4d2d)

---

## Requirements : 
- Windows 10/11 Pro, Enterprise or Education
- Google Chrome or Brave

---

## Installation

### Manual installation :
https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/setup.bat

(**Google did not approve this extension on webstore**)

---

## Why a local server ?

Chrome and Brave only install an extension from outside the web store when a browser policy tells them where to fetch it. `setup.bat` adds that policy, pointing to `http://127.0.0.1:47653/updates.xml`, and starts a tiny local server to answer it:
- it listens on `127.0.0.1` only, so it cannot be reached from the network
- it serves two files from the install folder, `updates.xml` and `ext.crx`, and nothing else
- it stops by itself as soon as the browser has installed the extension (3 minutes at most)

It runs again only when there is something to install: at Windows startup (a scheduled task that exits at once when the extension is already up to date) and when you update the extension. `setup.bat /uninstall` removes the policy, the task and the server.

Browsers apply such a policy only on managed computers. `setup.bat` therefore writes the registry keys of a local device management enrollment (`HKLM\SOFTWARE\Microsoft\Enrollments` and `HKLM\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts`, no account and no server behind them). Windows Home ignores them, which is why it is not supported. These keys are left in place by `/uninstall`, since other tools may rely on them.

---

## How to build yourself

1. Clone this repository.
2. Run `build.bat` — it packs `manifest.json`, `volume-lock.js`, `volume-bridge.js`, `content.js`, `background.js`, `popup.html`, `popup.js` and `icons/` into a signed CRX3 package, written as `ext.crx` at the repository root. Pure PowerShell, no Chrome or external tool required.
3. First build: a signing key is generated automatically in `_signing\videos-download.pem`. The extension ID is derived from that key — **keep it private and back it up**: building with a different key produces a *different* extension ID (build.bat warns you if the ID no longer matches the one expected by `setup.bat`).
4. Run `setup.bat` to install your freshly built `ext.crx` locally — it uses the files sitting next to it when present, and downloads the missing pieces (yt-dlp, ffmpeg, deno) from their official sources.
