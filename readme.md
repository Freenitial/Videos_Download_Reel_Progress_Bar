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
- Progress bar for reels with memorized volume
- Download as Video (original)
- Download and convert as MP4
- Download and convert as MP3
- Cut / Trim

![image](https://github.com/user-attachments/assets/a7586200-3f58-4adc-9e0e-79d9a91f4d2d)

---

## Requirements : 
- Windows 10 build 1703 +
- Google Chrome

---

## Installation

### Manual installation :
https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/setup.bat

(**Google did not approve this extension on webstore**)

---

## How to build yourself

1. Clone this repository.
2. Run `build.bat` — it packs `manifest.json`, `content.js`, `background.js` and `icons/` into a signed CRX3 package, written as `ext.crx` at the repository root. Pure PowerShell, no Chrome or external tool required.
3. First build: a signing key is generated automatically in `_signing\videos-download.pem`. The extension ID is derived from that key — **keep it private and back it up**: building with a different key produces a *different* extension ID (build.bat warns you if the ID no longer matches the one expected by `setup.bat`).
4. Run `setup.bat` to install your freshly built `ext.crx` locally — it uses the files sitting next to it when present, and downloads the missing pieces (yt-dlp, ffmpeg, deno) from their official sources.
