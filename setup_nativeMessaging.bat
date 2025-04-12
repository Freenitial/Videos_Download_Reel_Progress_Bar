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
$File_ModuleManifest = "$nativeMessagerName.json"
$installPath        = "$env:programdata\Videos Download - Reel Progress Bar"
$extension_ID       = "hipgpgddfihbabbeomabnkakidlmaean"
$logFile = Join-Path (Get-Location) "setup_nativeMessaging.log"

$module_files = @("$File_ModuleManifest", "freenitial_yt_dlp_wrapper.bat", "freenitial_yt_dlp_script.ps1")
$extension_files = @("manifest.json", "content.js", "background.js", "icon-16.png", "icon-48.png", "icon-128.png")




if (-not (Test-Path $installPath)) {
    try { Write-Host "Creating folder '$installPath'..." ; New-Item -ItemType Directory -Force -Path $installPath -ErrorAction Stop | Out-Null } 
    catch { Write-Host "Error: Failed to create folder '$installPath'" -ForegroundColor "Red" ; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") ; exit 2 }
}
Set-Location $installPath




# ============================ UTILITY FUNCTIONS =============================
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


function Test-FileUpToDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileURL,
        [Parameter(Mandatory = $false)]
        [string]$FileLocal
    )
    try {
        $assetName = Split-Path $FileURL -Leaf
        if (-not $FileLocal) { $FileLocal = Join-Path $(Get-Location) $assetName } else { $destination = $FileLocal }
        $uri = [uri]$FileURL
        $segments = $uri.Segments
        if ($segments.Count -lt 3) { Log "Error: Invalid GitHub URL format." }
        $owner = $segments[1].TrimEnd('/')
        $repo  = $segments[2].TrimEnd('/')
        $apiURL = "https://api.github.com/repos/$owner/$repo/releases/latest"
        $release = Invoke-RestMethod -Uri $apiURL
        $asset = $release.assets | Where-Object { $_.name -eq $assetName }
        if (-not $asset) { Log "Error: Asset '$assetName' not found in the latest release." }
        if (-not (Test-Path $FileLocal)) { Log "Local file '$assetName' does not exist." ; Invoke-Download $FileURL $(if ($destination) {$destination} else {$assetName}) ; return $false }
        $localFile = Get-Item $FileLocal
        if ($localFile.Length -ne $asset.size) { Log "File size mismatch. Local: $($localFile.Length), Online: $($asset.size)" ; Invoke-Download $FileURL $(if ($destination) {$destination} else {$assetName}) ; return $false }
        $localDate = $localFile.LastWriteTime
        $onlineDate = ([datetime]$asset.updated_at).ToLocalTime()
        if ($localDate -lt $onlineDate) { Log "Local file is older. Local: $localDate, Online: $onlineDate" ; Invoke-Download $FileURL $(if ($destination) {$destination} else {$assetName}) ; return $false }
        Log "$assetName is up to date"
        return $true
    }
    catch { Log "Error in Test-FileUpToDate: $($_.Exception.Message)" }
}


function Invoke-Download {
    param([Parameter(Mandatory = $true)][string]$Url, [string]$FileName)
    Log "Downloading $(if ($FileName) {$Filename} else {$Url})..."
    $destination = $(if ([string]::IsNullOrEmpty($FileName)) { Join-Path (Get-Location) [System.IO.Path]::GetFileName($Url) } else { $FileName })
    if (Test-Path $destination) {
        try { Remove-Item -Path $destination -Force -ErrorAction Stop }
        catch { Log "Error deleting existing file '$destination': $($_.Exception.Message)" }
    } 
    else { [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination)) | Out-Null }
    write-host "destination = $destination"
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
    catch { Log "Error: Download failed: $($_.Exception.Message)" }
    finally {
        if ($inputStream) { try { $inputStream.Dispose() } catch {} }
        if ($outputStream) { try { $outputStream.Dispose() } catch {} }
        if ($httpClient) { try { $httpClient.Dispose() } catch {} }
    }
}




# ================= DOWNLOAD NATIVE MESSAGING MANIFEST FILE ==================
foreach ($file in $module_files) { Test-FileUpToDate $("https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/$file") | Out-Null }




# =================== CONNECT NATIVE MESSAGING WITH CHROME ===================
Log "Creating registry keys in HKCU\Software\Google\Chrome\NativeMessagingHosts\$nativeMessagerName..."
try {
    Remove-Item -Path "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$nativeMessagerName" -Force -ErrorAction SilentlyContinue
    New-Item -Path "HKCU:\Software\Google\Chrome\NativeMessagingHosts" -Name "$nativeMessagerName" -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -Path "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$nativeMessagerName" -Name '(default)' -Value "$installPath\$File_ModuleManifest" -ErrorAction Stop
} 
catch { Log "Error: Failed to create registry keys for native messaging." }




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
    Write-Host "" ; Log "Warning: Extension not found for this profile."
    $userInput = Read-Host " Press Enter to open the extension webpage, or type 'manual' to install the unpacked version" -ForegroundColor Yellow ; Write-Host ""
    if ($userInput -eq "manual") {
        Log "Installing unpacked version..."
        foreach ($file in $extension_files) { 
            Test-FileUpToDate `
                $("https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/$file") `
                $(if ($file -match '^icon-.*\.png$') { $(Join-Path (Get-Location) "icons\$file") } else { $file }) `
            | Out-Null
        }
        Log "Asking user to add unpacked extension..." -NoConsole
        $attribs = (Get-Item -Path $env:ProgramData).Attributes
        $wasHidden = $attribs -band [System.IO.FileAttributes]::Hidden
        if ($wasHidden) { (Get-Item -Path $env:ProgramData).Attributes = $attribs -bxor [System.IO.FileAttributes]::Hidden }
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
        if ($wasHidden) { (Get-Item -Path $env:ProgramData).Attributes = (Get-Item -Path $env:ProgramData).Attributes -bor [System.IO.FileAttributes]::Hidden }
        Log "Please wait..."
        $securePreferencesPath = "$latestChromeProfilePath\Secure Preferences" 
        $pathToFind = $installPath
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
                Log "Attempting to update manifest file at '$installPath\$File_ModuleManifest'."
                try {
                    $jsonObject = Get-Content -Path "$installPath\$File_ModuleManifest" -Raw | ConvertFrom-Json
                    $jsonObject.name = $nativeMessagerName
                    $jsonObject.path = "$installPath\$File_ModuleManifest"
                    $jsonObject.allowed_origins = @("chrome-extension://$foundExtensionId/")
                    $jsonObject | ConvertTo-Json | Out-File -FilePath "$installPath\$File_ModuleManifest" -Encoding UTF8
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
Test-FileUpToDate "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" | Out-Null


$ffmpegZIPname = "ffmpeg-master-latest-win64-lgpl.zip"
if (-not (Test-FileUpToDate "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/$ffmpegZIPname" | Out-Null)) {
    Log "Extracting .exe files..."
    try     {
        $zip = [System.IO.Compression.ZipFile]::OpenRead("$installPath\$ffmpegZIPname")
        $zip.Entries.Where({ !$_.PSIsContainer -and $_.Name -like "*.exe" }) | ForEach-Object {
            $destinationPath = Join-Path $installPath $_.Name
            try   {[System.IO.Compression.ZipFileExtensions]::ExtractToFile($_, $destinationPath, $true) ; Log "Extracted: $($_.Name)" } 
            catch { Log "Extraction error: $($_.FullName) - $($_.Exception.Message)" }
        }
    }
    catch   { Log "Error processing ZIP file '$ffmpegZIPname': $($_.Exception.Message)" }
    finally { if ($null -ne $zip) { $zip.Dispose() ; Log "ZIP archive handle released." } }
}




# ================================= ENDING ==================================
Log ""
Log "MODULE FOR EXTENSION IS NOW INSTALLED." 
Write-Host " you can use extension. Type any key to close this window." -ForegroundColor Green
Log ""

$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force
