<# ::
    cls & @echo off & chcp 65001 >nul
    copy /y "%~f0" "%TEMP%\%~n0.ps1" >NUL && powershell -Nologo -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\%~n0.ps1"
#>




[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = "Freential Videos Download Module Setup V1.0"
Write-Host ""
Write-Host "------------------------------------------"
Write-Host ""




$nativeMessagerName = "freenitial_yt_dlp_host"
$installPath = "$env:programdata\Videos Download - Reel Progress Bar"
$extension_ID = "hipgpgddfihbabbeomabnkakidlmaean"




if (-not (Test-Path $installPath)) {
    try {
        Write-Host " Creating folder '$installPath'..."
        New-Item -ItemType Directory -Force -Path $installPath -ErrorAction Stop | Out-Null
    } catch {
        Write-Host " Error: Failed to create folder '$installPath'" -ForegroundColor Red
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 2
    }
}
Set-Location $installPath




# ================== DETECT MOST RECENT USED CHROME PROFILE ==================
$chromePaths = @(
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
)
$chromePath = $chromePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
$chromeAppdataPath = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
$latestChromeProfilePath = $null
if (Test-Path $chromeAppdataPath) {
    $latestChromeProfilePath = (Get-ChildItem $chromeAppdataPath -Directory | Where-Object { $_.Name -match '^(Default|Profile \d+)$' } | ForEach-Object {
        $maxTime = (Get-ChildItem $_.FullName -Recurse -Depth 1 -Force -ErrorAction SilentlyContinue | Measure-Object LastWriteTime -Maximum).Maximum
        if (-not $maxTime) { $maxTime = (Get-Item $_.FullName).LastWriteTime }
        [PSCustomObject]@{ Path = $_.FullName; MaxTime = $maxTime }
    } | Sort-Object MaxTime -Descending | Select-Object -First 1).Path
}
$extensionPath = Join-Path -Path $latestChromeProfilePath -ChildPath "Extensions\$extension_ID"
if (Test-Path $extensionPath) { 
    write-host  " Extension found for recent profile : '$latestChromeProfilePath'" -ForegroundColor Green
}
elseif ($chromePath) {
    Write-Host " Extension not found for this profile, opening extension page, you can install it" -ForegroundColor Yellow
    Start-Process "C:\Program Files\Google\Chrome\Application\chrome.exe" "https://chromewebstore.google.com/detail/Video-Download-Reel-ProgressBar-for-Youtube-Facebook-Instagram-TikTok-X/bacegihmkkfgjmemcdejcpgbnldppbkg"
} 
else {
    Write-Host " Chrome not found, please install chrome and launch again" -ForegroundColor Red
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 2
}




# ================= DOWNLOAD NATIVE MESSAGING MANIFEST FILE ==================
Write-Host " Downloading background manifest file..."
try {
    Invoke-WebRequest -Uri "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/freenitial_yt_dlp_host.json" -OutFile "freenitial_yt_dlp_host.json" -ErrorAction Stop
} catch {
    Write-Host " Error: Failed to download background manifest file." -ForegroundColor Red
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 2
}




# =================== CONNECT NATIVE MESSAGING WITH CHROME ===================
Write-Host " Creating registry keys in HKCU\Software\Google\Chrome\NativeMessagingHosts\$nativeMessagerName..."
try {
    Remove-Item -Path "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$nativeMessagerName" -Force -ErrorAction SilentlyContinue
    New-Item -Path "HKCU:\Software\Google\Chrome\NativeMessagingHosts" -Name "$nativeMessagerName" -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -Path "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$nativeMessagerName" -Name '(default)' -Value "$installPath\freenitial_yt_dlp_host.json" -ErrorAction Stop
} catch {
    Write-Host " Error: Failed to create registry keys for native messaging." -ForegroundColor Red
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 2
}




# ==================== DOWNLOAD NATIVE MESSAGING WRAPPER =====================
Write-Host " Downloading background script wrapper..."
try {
    Invoke-WebRequest -Uri "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/freenitial_yt_dlp_wrapper.bat" -OutFile "freenitial_yt_dlp_wrapper.bat" -ErrorAction Stop
} catch {
    Write-Host " Error: Failed to download background script wrapper." -ForegroundColor Red
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 2
}




# ===================== DOWNLOAD NATIVE MESSAGING SCRIPT =====================
Write-Host " Downloading main background script..."
try {
    Invoke-WebRequest -Uri "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/freenitial_yt_dlp_script.ps1" -OutFile "freenitial_yt_dlp_script.ps1" -ErrorAction Stop
} catch {
    Write-Host " Error: Failed to download main background script." -ForegroundColor Red
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 2
}




# ======================= DOWNLOAD AND EXTRACT YT-DLP ========================
Write-Host " Downloading yt-dlp..."
try {
    Invoke-WebRequest -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" -OutFile "yt-dlp.exe" -ErrorAction Stop
} catch {
    Write-Host " Error: Failed to download yt-dlp." -ForegroundColor Red
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 2
}

Write-Host " Downloading ffmpeg..."
$zipfile = "ffmpeg.zip"
try {
    Invoke-WebRequest -Uri "https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip" -OutFile $zipfile -ErrorAction Stop
} catch {
    Write-Host " Error: Failed to download ffmpeg." -ForegroundColor Red
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 2
}

Write-Host " Extracting ffmpeg..."
try {
    New-Item -ItemType Directory -Force -Path "temp_extract" -ErrorAction Stop | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipfile, "temp_extract")
} catch {
    Write-Host " Error: Failed to extract ffmpeg." -ForegroundColor Red
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 2
}

Write-Host " Copying extracted files..."
try {
    Get-ChildItem -Path "temp_extract" -Recurse -Filter *.exe | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination (Get-Location) -ErrorAction Stop
    }
} catch {
    Write-Host " Error: Failed to copy ffmpeg executables." -ForegroundColor Red
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 2
}

Write-Host " Cleaning..."
try {
    Remove-Item -Recurse -Force "temp_extract" -ErrorAction Stop
    Remove-Item -Force $zipfile -ErrorAction Stop
} catch {
    Write-Host " Error: Failed to clean temporary files." -ForegroundColor Red
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 2
}




# ================================= ENDING ==================================
Write-Host ""
Write-Host " EXTENSION IS NOW INSTALLED."
Write-Host " you can close this window and use extension."
Write-Host ""
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force