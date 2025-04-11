<# ::
    cls & @echo off & chcp 65001 >nul
    copy /y "%~f0" "%TEMP%\%~n0.ps1" >NUL && powershell -Nologo -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\%~n0.ps1"
#>



Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Net.Http

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = "Freential Videos Download Module Setup V1.1"
Write-Host ""

$nativeMessagerName = "freenitial_yt_dlp_host"
$ModuleManifestFile = "$nativeMessagerName.json"
$installPath        = "$env:programdata\Videos Download - Reel Progress Bar"
$extension_ID       = "hipgpgddfihbabbeomabnkakidlmaean"
$logFile = Join-Path (Get-Location) "setup_nativeMessaging.log"


if (-not (Test-Path $installPath)) {
    try { Log "Creating folder '$installPath'..." ; New-Item -ItemType Directory -Force -Path $installPath -ErrorAction Stop | Out-Null } 
    catch { Log "Error: Failed to create folder '$installPath'" }
}
Set-Location $installPath




function Log {
    param([string]$message, [switch]$NoNewline, [switch]$NoConsole)
    $isError = $message.ToLower().Contains("error")
    $color = if ($isError) { "Red" } elseif ($message.ToLower().Contains("warning")) { "Yellow" } else { $null }
    if (-not $NoConsole.IsPresent) { if ($color) { Write-Host (" {0}" -f $message) -ForegroundColor $color -NoNewline:$NoNewline } 
                                     else { Write-Host (" {0}" -f $message) -NoNewline:$NoNewline }
    }
    if (-not $NoNewline) {
        $logMessage = if ([string]::IsNullOrEmpty($message)) { "" } else { "[$('{0:yyyy/MM/dd - HH:mm:ss}' -f (Get-Date))] - $message" }
        try { Add-Content -Path $logFile -Value $logMessage -ErrorAction Stop }
        catch { Write-Host "Error writing to logfile: $($_.Exception.Message)"; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown"); exit 3 }
    }
    if ($isError) { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown"); exit 2 }
}
if (Test-Path $logFile) { Log "" ; Log " --------------------------------" -NoConsole ; Log "" -NoConsole }



function Invoke-Download {
    param([Parameter(Mandatory = $true)][string]$Url, [string]$FileName)
    $destination = Join-Path (Get-Location) $(if ([string]::IsNullOrEmpty($FileName)) { [System.IO.Path]::GetFileName($Url) } else { $FileName })
    if (Test-Path $destination) {
        try { Remove-Item -Path $destination -Force -ErrorAction Stop }
        catch { Log "Error deleting existing file '$destination': $($_.Exception.Message)" }
    }
    $httpClient = [System.Net.Http.HttpClient]::new()
    $inputStream = $outputStream = $null
    $progressSymbol = "-"
    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
        $response = $httpClient.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
        if (-not $response.IsSuccessStatusCode) { Log "Error: HTTP $($response.StatusCode) $($response.ReasonPhrase)" }
        $totalBytes = $response.Content.Headers.ContentLength
        if (-not $totalBytes) { Log "Error: Unable to determine file size." }
        $inputStream = $response.Content.ReadAsStreamAsync().Result
        $outputStream = [System.IO.File]::OpenWrite($destination)
        $buffer = New-Object byte[] 8192
        $totalRead = 0
        $lastUpdateTime = Get-Date
        $lastBytes = 0
        $barLength = 30
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $totalRead += $read
            $now = Get-Date
            $elapsed = ($now - $lastUpdateTime).TotalMilliseconds
            if ($elapsed -ge 100) {
                $percent = [math]::Round(($totalRead / $totalBytes) * 100, 2)
                $speedMB = ($totalRead - $lastBytes) / 1MB / ($elapsed / 1000)
                $filledLength = [math]::Floor($percent * $barLength / 100)
                $bar = ($progressSymbol * $filledLength).PadRight($barLength)
                $line = ("[{0}] {1}% {2} MB/s" -f $bar, $percent, [math]::Round($speedMB,2))
                Log "`r$line" -NoNewline
                $lastUpdateTime = $now
                $lastBytes = $totalRead
            }
        }
        $line = ("[{0}] 100% - Download complete" -f ($progressSymbol * $barLength))
        Log "`r$line"
    }
    catch { Log "Download failed: $($_.Exception.Message)" }
    finally {
        if ($inputStream) { try { $inputStream.Dispose() } catch {} }
        if ($outputStream) { try { $outputStream.Dispose() } catch {} }
        if ($httpClient) { try { $httpClient.Dispose() } catch {} }
    }
}



# ================= DOWNLOAD NATIVE MESSAGING MANIFEST FILE ==================
Log "Downloading background manifest file..."
Invoke-Download "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/$ModuleManifestFile"




# =================== CONNECT NATIVE MESSAGING WITH CHROME ===================
Log "Creating registry keys in HKCU\Software\Google\Chrome\NativeMessagingHosts\$nativeMessagerName..."
try {
    Remove-Item -Path "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$nativeMessagerName" -Force -ErrorAction SilentlyContinue
    New-Item -Path "HKCU:\Software\Google\Chrome\NativeMessagingHosts" -Name "$nativeMessagerName" -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -Path "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$nativeMessagerName" -Name '(default)' -Value "$installPath\$ModuleManifestFile" -ErrorAction Stop
} 
catch { Log "Error: Failed to create registry keys for native messaging." }




# ==================== DOWNLOAD NATIVE MESSAGING WRAPPER =====================
Log "Downloading background script wrapper..."
Invoke-Download "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/freenitial_yt_dlp_wrapper.bat"




# ===================== DOWNLOAD NATIVE MESSAGING SCRIPT =====================
Log "Downloading main background script..."
Invoke-Download "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/freenitial_yt_dlp_script.ps1"



# ================== DETECT MOST RECENT USED CHROME PROFILE ==================
$chromePaths = @(
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
)
if (-not ($chromePaths | Where-Object { Test-Path $_ } | Select-Object -First 1)) { Log "Error: Chrome not found, please install chrome and launch again" }
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


# ====================== OPTIONNAL MANUAL INSTALLATION =======================
if (Test-Path $extensionPath) { Log  "Extension found for recent profile : '$latestChromeProfilePath'" }
else {
    Log "Warning: Extension not found for this profile."
    $userInput = Read-Host " Press Enter to open the extension webpage, or type 'manual' to install the unpacked version"
    if ($userInput -eq "manual") {
        Log "Installing unpacked version..."
        Log "Downloading manifest.js..."
        Invoke-Download "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/manifest.json"
        Log "Downloading content.js..."
        Invoke-Download "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/content.js"
        Log "Downloading background.js..."
        Invoke-Download "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/background.js"
        Log "Creating icons folder..."
        New-Item -Path "$installPath\icons" -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Log "Downloading icons..."
        Invoke-Download "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/icon-16.png"  "icons\icon-16.png"
        Invoke-Download "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/icon-48.png"  "icons\icon-48.png"
        Invoke-Download "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/icon-128.png" "icons\icon-128.png"
        Log "Asking user to add unpacked extension..." -NoConsole
        Write-Host ""
        Write-Host "  1)" -ForegroundColor Green -NoNewline
        Write-Host "  OPEN CHROME, COPY-PASTE THIS IN YOUR ADDRESS BAR : " -ForegroundColor Yellow -NoNewline
        Write-Host "chrome://extensions" -ForegroundColor White -BackgroundColor DarkRed
        Write-Host "  2)" -ForegroundColor Green -NoNewline
        Write-Host "  IN THE TOP-RIGHT CORNER,                ACTIVATE : " -ForegroundColor Yellow -NoNewline
        Write-Host '"Developer mode"' -ForegroundColor White -BackgroundColor DarkRed
        Write-Host "  3)" -ForegroundColor Green -NoNewline
        Write-Host "  IN THE TOP-LEFT CORNER,                    CLICK : " -ForegroundColor Yellow -NoNewline
        Write-Host '"Load unpacked"' -ForegroundColor White -BackgroundColor DarkRed
        Write-Host "  4)" -ForegroundColor Green -NoNewline
        Write-Host "  NAVIGATE INTO THIS FOLDER TO LOAD THE EXTENSION  : " -ForegroundColor Yellow -NoNewline
        Write-Host "$installPath" -ForegroundColor White -BackgroundColor DarkRed
        Write-Host ""
        Write-Host " AFTER THIS, press any key to continue installation."
        Write-Host ""
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        Write-Host ""
        Write-Host " Are you sure ? Did you follow the steps " -ForegroundColor Yellow -NoNewline
        Write-Host "1, 2, 3, 4 " -ForegroundColor Green -NoNewline
        Write-Host "?" -ForegroundColor Yellow
        Write-Host " press any key to continue"
        Write-Host ""
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        Log "Please wait..."
        $securePreferencesPath = "$env:localappdata\Google\Chrome\User Data\Default\Secure Preferences" 
        $pathToFind = "" 
        if (Test-Path $securePreferencesPath) {
            Log "Secure preferences file found at '$securePreferencesPath'. Attempting to read and parse..."
            try { $json = Get-Content -Path $securePreferencesPath -Raw | ConvertFrom-Json ; Log "Secure preferences parsed successfully." } 
            catch { Log "Error parsing secure preferences: $_" }
            $foundExtensionId = $null
            if ($json -and $json.extensions -and $json.extensions.settings) {
                Log "Searching for extension path in settings..."
                try {
                    foreach ($id in $json.extensions.settings.PSObject.Properties.Name) {
                        $ext = $json.extensions.settings.$id
                        if ($ext.path -eq $pathToFind) {
                            $foundExtensionId = $id
                            Log "Extension ID '$foundExtensionId' found for path '$pathToFind'."
                            break 
                        }
                    }
                    if (-not $foundExtensionId) { Log "Error: Extension path '$pathToFind' not found in secure preferences." }
                } 
                catch { Log "Error while iterating extension settings: $_" }
            } 
            else { Log "Error: Extension settings not found or invalid in secure preferences." }
            if ($foundExtensionId) {
                Log "Attempting to update manifest file at '$manifestPath'."
                try {
                    $jsonObject = Get-Content -Path "$installPath\$ModuleManifestFile" -Raw | ConvertFrom-Json
                    $jsonObject.name = $nativeMessagerName
                    $jsonObject.path = "$installPath\$ModuleManifestFile"
                    $jsonObject.allowed_origins = @("chrome-extension://$foundExtensionId/")
                    $jsonObject | ConvertTo-Json | Out-File -FilePath $manifestPath -Encoding UTF8
                    Log "Manifest file updated successfully."
                } 
                catch { Log "Error updating manifest file: $_"  }
            }
        } 
        else { Log "Error: Secure preferences file '$securePreferencesPath' not found." }
    } 
    else {
        Log "Opening the extension web page..."
        Start-Process "C:\Program Files\Google\Chrome\Application\chrome.exe" "https://chromewebstore.google.com/detail/Video-Download-Reel-ProgressBar-for-Youtube-Facebook-Instagram-TikTok-X/$extension_ID"
    }
}




# ======================= DOWNLOAD AND EXTRACT YT-DLP ========================
Log "Downloading yt-dlp..."
Invoke-Download "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe"

Log "Downloading ffmpeg..."
$zipfile = "ffmpeg.zip"
Invoke-Download "https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip" $zipfile

Log "Extracting .exe files..."
try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipfile)
    $zip.Entries.Where({ !$_.PSIsContainer -and $_.Name -like "*.exe" }) | ForEach-Object {
        $destinationPath = Join-Path (Get-Location).Path $_.Name
        try {[System.IO.Compression.ZipFileExtensions]::ExtractToFile($_, $destinationPath, $true) ; Log "Extracted: $($_.Name)" } 
        catch { Log "Extraction error: $($_.FullName) - $($_.Exception.Message)" }
    }
}
catch { Log "Error processing ZIP file '$zipfile': $($_.Exception.Message)" }
finally {
    if ($null -ne $zip) { $zip.Dispose() ; Log "ZIP archive handle released." }
    try { Remove-Item -Path $zipfile -Force -ErrorAction Stop ; Log "ZIP file deleted: $zipfile"}
    catch { Log "Warning: Could not delete ZIP file '$zipfile': $($_.Exception.Message)" }
}




# ================================= ENDING ==================================
Log ""
Log "MODULE FOR EXTENSION IS NOW INSTALLED." 
Write-Host "you can use extension. Type any key to close this window." -ForegroundColor Green
Log ""

$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force
