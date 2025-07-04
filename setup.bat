<# ::
    cls & @echo off
    copy /y "%~f0" "%TEMP%\%~n0.ps1" >NUL && powershell -Nologo -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\%~n0.ps1"
#>



Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Net.Http

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = "Freential Videos Download Module Setup V1.2"
Write-Host ""

$nativeMessagerName  = "freenitial_yt_dlp_host"
$File_ModuleManifest = "$nativeMessagerName.json"
$installPath         = "$env:programdata\Videos Download - Reel Progress Bar"
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
                                     else { Write-Host (" {0}" -f $message) -NoNewline:$NoNewline } }
    if (-not $NoNewline) {
        $logMessage = if ([string]::IsNullOrEmpty($message)) { "" } else { "[$('{0:yyyy/MM/dd - HH:mm:ss}' -f (Get-Date))] - $message" }
        try {
            $utf8 = New-Object System.Text.UTF8Encoding $false
            $sw = New-Object System.IO.StreamWriter -ArgumentList $logFile, $true, $utf8
            $sw.WriteLine($logMessage)
            $sw.Close()
        } catch {
            Write-Host "Error writing to logfile: $($_.Exception.Message)"; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown"); exit 3
        }
    }
    if ($isError) { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown"); exit 2 }
}
if (Test-Path $logFile) { Log "" ; Log " --------------------------------" -NoConsole ; Log "" -NoConsole }


$WTS = Add-Type -MemberDefinition @'
    [DllImport("wtsapi32.dll", SetLastError=true)]
    public static extern IntPtr WTSOpenServer(string pServerName);
    [DllImport("wtsapi32.dll", SetLastError=true)]
    public static extern void WTSCloseServer(IntPtr hServer);
    [DllImport("wtsapi32.dll", SetLastError=true)]
    public static extern bool WTSSendMessage(IntPtr hServer, int SessionId, String pTitle, int TitleLength, String pMessage, int MessageLength, int Style, int Timeout, out int pResponse, bool bWait);
'@ -Name WTSApi -Namespace Win32 -PassThru
$WTShandle = $WTS::WTSOpenServer($give_null_variable_because_its_local)

function Send-WtsMessage {
    param([string]$Title,[string]$Message,[string]$Style="ok",[int]$TimeoutSeconds=0,[switch]$NoWait)
    $styleBase=switch($Style.ToLower()){"yesno"{0x4}"ok"{0x0}default{throw"Unsupported style '$Style'. Use 'ok' or 'yesno'."}}
    $icon=if($Message -like "*?*"){0x20}else{0x40}
    $finalStyle=$styleBase -bor $icon
    $response=0
    [void]$WTS::WTSSendMessage($WTShandle,(Get-Process -Id $PID).SessionId,$Title,$Title.Length,$Message,$Message.Length,$finalStyle,$TimeoutSeconds,[ref]$response,-not $NoWait)
    if($styleBase -eq 0x0){$null=$response}else{return $response}
}


function Test-FileUpToDate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$FileURL,
        [Parameter(Mandatory=$false)][string]$FileLocal
    )
    try {
        $assetName=Split-Path $FileURL -Leaf
        if(-not $FileLocal){$FileLocal=Join-Path (Get-Location) $assetName}
        if(-not[System.IO.Path]::GetDirectoryName($FileLocal)){$FileLocal=Join-Path (Get-Location) $FileLocal}
        $uri=[uri]$FileURL;$segments=$uri.Segments;if($segments.Count -lt 3){Log "Error: Invalid GitHub URL format."}
        $owner=$segments[1].TrimEnd('/');$repo=$segments[2].TrimEnd('/')
        $apiURL="https://api.github.com/repos/$owner/$repo/releases/latest"
        $release=Invoke-RestMethod -Uri $apiURL -Headers @{'User-Agent'='PS-FileChecker'}
        $asset=$release.assets|Where-Object{$_.name -eq $assetName}
        if(-not $asset){Log "Error: Asset '$assetName' not found in the latest release."}
        if(-not(Test-Path -LiteralPath $FileLocal)){Log "Local file '$assetName' does not exist.";Invoke-Download $FileURL $FileLocal;return $false}
        $localFile=Get-Item -LiteralPath $FileLocal -Force
        $localSize=[int64]$localFile.Length;$onlineSize=[int64]$asset.size
        if($localSize -ne $onlineSize){Log "File size mismatch. Local: $localSize, Online: $onlineSize";Invoke-Download $FileURL $FileLocal;return $false}
        $localDate=$localFile.LastWriteTime;$onlineDate=([datetime]$asset.updated_at).ToLocalTime()
        if($localDate -lt $onlineDate){Log "Local file is older. Local: $localDate, Online: $onlineDate";Invoke-Download $FileURL $FileLocal;return $false}
        Log "$assetName is up to date";return $true
    } catch {
        if ($_.Exception.Response -and ($_.Exception.Response.StatusCode -eq 403)) {
            Log "Warning: API rate limit hit (403). Treating file as not up to date."
            return $false
        }
        Log "Error in Test-FileUpToDate: $($_.Exception.Message)"
    }
}


function Invoke-Download {
    param([Parameter(Mandatory = $true)][string]$Url, [string]$FileName)
    Log "Downloading $(if ($FileName) {$Filename} else {$Url})..."
    $destination = $(if ([string]::IsNullOrEmpty($FileName)) { Join-Path (Get-Location) [System.IO.Path]::GetFileName($Url) } else { $FileName })
    if (Test-Path $destination) { try { Remove-Item -Path $destination -Force -ErrorAction Stop } catch { Log "Error deleting existing file '$destination': $($_.Exception.Message)" } } 
    elseif ([System.IO.Path]::GetDirectoryName($destination)) { [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($destination)) | Out-Null }
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



# ====================== MANUAL INSTALLATION =======================
Log "Installing unpacked version..."
foreach ($file in $extension_files) { 
    Test-FileUpToDate `
        $("https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/$file") `
        $(if ($file -match '^icon-.*\.png$') { $(Join-Path (Get-Location) "icons\$file") } else { $file }) `
    | Out-Null
}
Log "Asking user to add unpacked extension..." -NoConsole
$attribs = (Get-Item -Path $env:ProgramData -Force).Attributes
$wasHidden = $attribs -band [System.IO.FileAttributes]::Hidden
if ($wasHidden) { (Get-Item -Path $env:ProgramData -Force).Attributes = $attribs -bxor [System.IO.FileAttributes]::Hidden }

$message = @"
  1)  OPEN CHROME, TYPE THIS IN YOUR ADDRESS BAR :
      chrome://extensions

  2)  IN THE TOP-RIGHT CORNER, ACTIVATE :
      "Developer mode"

  3)  IN THE TOP-LEFT CORNER, CLICK :
      "Load unpacked"

  4)  NAVIGATE INTO THIS FOLDER TO LOAD THE EXTENSION  :
      $installPath

  AFTER THIS, press OK.
"@
Send-WtsMessage "LOAD EXTENSION IN CHROME" $message

$message = @"
  1)  OPEN CHROME, TYPE THIS IN YOUR ADDRESS BAR :
      chrome://extensions
  2)  IN THE TOP-RIGHT CORNER, ACTIVATE :
      "Developer mode"
  3)  IN THE TOP-LEFT CORNER, CLICK :
      "Load unpacked"
  4)  NAVIGATE INTO THIS FOLDER TO LOAD THE EXTENSION  :
      $installPath

      ARE YOU SURE ? DID YOU FOLLOW THE STEPS 1,2,3,4 ?
"@
Send-WtsMessage "ARE YOU SURE ?" $message

if ($wasHidden) { (Get-Item -Path $env:ProgramData).Attributes = (Get-Item -Path $env:ProgramData).Attributes -bor [System.IO.FileAttributes]::Hidden }
Log "Please wait..."
$securePreferencesPath = "$latestChromeProfilePath\Secure Preferences" 
$pathToFind = $installPath
if (Test-Path $securePreferencesPath) {
    Log "Secure preferences file found at '$securePreferencesPath'. Attempting to read and parse..."
    try { $json = Get-Content -Path $securePreferencesPath -Raw | ConvertFrom-Json ; Log "Secure preferences parsed successfully." }
    catch { Log "Error parsing secure preferences: $_" }
    $foundExtensionId = $null
    if (Test-Path $securePreferencesPath) {
        Log "Monitoring secure preferences for extension path..."
        $loops = 15
        for ($i = 0; $i -lt $loops; $i++) {
            try { $json = Get-Content -Path $securePreferencesPath -Raw | ConvertFrom-Json }
            catch { Start-Sleep -Seconds 2 ; continue }
            if ($json -and $json.extensions -and $json.extensions.settings) {
                foreach ($id in $json.extensions.settings.PSObject.Properties.Name) {
                    $ext = $json.extensions.settings.$id
                    if ($ext.path -eq $pathToFind) {
                        $foundExtensionId = $id
                        Log "Extension ID '$foundExtensionId' found for path '$pathToFind'."
                        break
                    }
                }
            }
            if ($foundExtensionId) { break }
            Start-Sleep -Seconds 2
        }
        if (-not $foundExtensionId) { Log "Error: Extension path '$pathToFind' not found in secure preferences after waiting $loops seconds." }
    }
    else { Log "Error: Extension settings not found or invalid in secure preferences." }
    if ($foundExtensionId) {
        Log "Attempting to update manifest file at '$installPath\$File_ModuleManifest'."
        try {
            $jsonObject = Get-Content -Path "$installPath\$File_ModuleManifest" -Raw | ConvertFrom-Json
            $jsonObject.name = $nativeMessagerName
            $jsonObject.path = "$installPath\freenitial_yt_dlp_wrapper.bat"
            $jsonObject.allowed_origins = @("chrome-extension://$foundExtensionId/")
            $jsonObject | ConvertTo-Json | Out-File -FilePath "$installPath\$File_ModuleManifest" -Encoding UTF8
            Log "Manifest file updated successfully."
        } 
        catch { Log "Error updating manifest file: $_"  }
    }
} 
else { Log "Error: Secure preferences file '$securePreferencesPath' not found." }



# ======================= DOWNLOAD AND EXTRACT YT-DLP ========================
Test-FileUpToDate "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" | Out-Null

$ffmpegZIPname = "ffmpeg-master-latest-win64-lgpl.zip"
$zipExist = Test-FileUpToDate "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/$ffmpegZIPname"
if (-not ($zipExist)) {
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
Send-WtsMessage "End" "MODULE FOR EXTENSION IS NOW INSTALLED."
$WTS::WTSCloseServer($WTShandle)

Log ""
Log "MODULE FOR EXTENSION IS NOW INSTALLED." 
Log ""

Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force
