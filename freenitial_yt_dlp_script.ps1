#--------------------------
# Utility Functions
#--------------------------
$script:portDead = $false

function Remove-OldFiles {
    param ([string]$Path, [string]$Pattern, [int]$MaxCount = 15)
    try {
        $files = @(Get-ChildItem -LiteralPath $Path -Filter $Pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
        if ($files.Count -gt $MaxCount) {
            $files | Select-Object -First ($files.Count - $MaxCount) | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}

function Log {
    param ([string]$message)
    try {
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
        [System.IO.File]::AppendAllText($scriptLogFile, "$timestamp - $message`r`n", [System.Text.Encoding]::UTF8)
    } catch { }
}

# Length-prefixed native message writer. On a broken pipe (Chrome closed the port)
# it flips $script:portDead so the caller can stop instead of throwing.
function Send-NativeMessage {
    param ([PSObject]$Message)
    if ($script:portDead) { return }
    try {
        $out = [Console]::OpenStandardOutput()
        $json = [Text.Encoding]::UTF8.GetBytes(($Message | ConvertTo-Json -Compress -Depth 6))
        $length = $json.Length
        $lengthBytes = [byte[]]::new(4)
        $lengthBytes[0] = $length -band 0xFF
        $lengthBytes[1] = ($length -shr 8) -band 0xFF
        $lengthBytes[2] = ($length -shr 16) -band 0xFF
        $lengthBytes[3] = ($length -shr 24) -band 0xFF
        $out.Write($lengthBytes, 0, 4)
        $out.Write($json, 0, $json.Length)
        $out.Flush()
    } catch { $script:portDead = $true }
}

function Send-Progress {
    param ([string]$Stage, [string]$Message, $Percent = $null, $Speed = $null, $Eta = $null, $Downloaded = $null, $Total = $null)
    $m = @{ type = 'progress'; stage = $Stage; message = $Message }
    if ($null -ne $Percent) { $m.percent = [int]$Percent }
    if ($Speed) { $m.speed = [string]$Speed }
    if ($Eta)   { $m.eta   = [string]$Eta }
    if ($null -ne $Downloaded) { $m.downloaded = [int64]$Downloaded }
    if ($null -ne $Total)      { $m.total      = [int64]$Total }
    Send-NativeMessage $m
}

function Send-Meta {
    param ($Title, $Uploader, $Duration, $Thumbnail)
    $m = @{ type = 'meta' }
    if ($Title)     { $m.title     = [string]$Title }
    if ($Uploader)  { $m.uploader  = [string]$Uploader }
    if ($null -ne $Duration -and $Duration -ne '') { $m.duration = $Duration }
    if ($Thumbnail) { $m.thumbnail = [string]$Thumbnail }
    Send-NativeMessage $m
}

# Terminal message of a download. $Extra adds fields (finalPaths, size, detail, logPath).
function Send-Done {
    param ([bool]$Success, [string]$Message = $null, [string]$FinalPath = $null, [hashtable]$Extra = $null)
    $m = @{ type = 'done'; success = $Success }
    if ($Message)   { $m.message   = $Message }
    if ($FinalPath) { $m.finalPath = $FinalPath }
    if ($Extra) { foreach ($k in $Extra.Keys) { if ($null -ne $Extra[$k]) { $m[$k] = $Extra[$k] } } }
    Send-NativeMessage $m
}

# One-shot response (sendNativeMessage, single message expected).
function Send-Legacy {
    param ([bool]$Success, [string]$Message = $null, [string]$FinalPath = $null)
    $m = @{ success = $Success }
    if ($Message)   { $m.message   = $Message }
    if ($FinalPath) { $m.finalPath = $FinalPath }
    Send-NativeMessage $m
}

# Windows (CommandLineToArgvW) argument quoting for a single safe command line.
function Quote-Arg {
    param ([string]$a)
    if ($null -eq $a) { $a = '' }
    if ($a -eq '') { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $s = [regex]::Replace($a, '(\\*)"', '$1$1\"')
    $s = [regex]::Replace($s, '(\\+)$', '$1$1')
    return '"' + $s + '"'
}

function Test-SafeUrl {
    param ([string]$u)
    if ([string]::IsNullOrWhiteSpace($u)) { return $false }
    if ($u.Length -ge 2048) { return $false }
    return ($u -match '^https://[^\s"''<>|^`\\]+$')
}

# yt-dlp section spec: "*START-END", either bound optional but not both, each as
# SS, MM:SS or HH:MM:SS with up to 3 decimals.
function Test-SafeCut {
    param ([string]$c)
    if ($c -eq '*-') { return $false }
    return ($c -match '^\*(\d+(:\d+){0,2}(\.\d{1,3})?)?-(\d+(:\d+){0,2}(\.\d{1,3})?)?$')
}

# Robust boolean from JSON (a producer sending the string "false" must not read $true).
function AsBool {
    param ($v)
    if ($v -is [bool])   { return $v }
    if ($null -eq $v)    { return $false }
    if ($v -is [string]) { return ($v -match '^(?i:true|1|yes|on)$') }
    return [bool]$v
}

# Kill a process AND its children (yt-dlp spawns ffmpeg). Process.Kill($true) is
# .NET Core only; PS 5.1 uses taskkill /T.
function Stop-ProcessTree {
    param ([int]$ProcessId)
    if ($ProcessId -gt 0) {
        try { & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null } catch { }
    }
}

# Map frequent yt-dlp errors to a human-friendly message. The raw line is sent
# separately as the error detail.
function Translate-YtDlpError {
    param ([string]$raw)
    if ([string]::IsNullOrWhiteSpace($raw)) { return "The download failed. Try again in a moment." }
    $map = @(
        @('HTTP Error 429|rate.?limit|Too Many Requests',                                        'Too many requests (429) — wait a few minutes and try again.'),
        @('IP address is blocked|blocked your IP|blocking requests from your',                  'The site is blocking this network for now — try again later or from another network.'),
        @('is private|login required|Sign in to|requires authentication|Private video',       'Private video or restricted to logged-in accounts — cannot be downloaded without signing in.'),
        @('Video unavailable|video is unavailable|has been removed|no longer available|Content isn|This video is not available', 'Video unavailable or removed.'),
        @('confirm your age|age-restricted|inappropriate for some',                             'Age-restricted video.'),
        @('not available in your country|geo.?restricted|blocked it in your country',           'Video blocked in your country.'),
        @('Requested format is not available|No video formats|Requested format',               'Requested format unavailable for this video.'),
        @('HTTP Error 403|Forbidden|403:',                                                      'Access denied by the server (403) — try again in a few minutes.'),
        @('HTTP Error 404|Not Found|404:',                                                      'Video not found (404).'),
        @('This live event|is live|will begin in|Premieres in',                                 'Live or upcoming broadcast — not downloadable yet.'),
        @('Unsupported URL|Unable to extract|no suitable extractor',                            'Link not supported for download.'),
        @('Unable to download|Unable to connect|getaddrinfo|Temporary failure|timed out|Connection refused|Network is unreachable|Read timed out', 'Network connection problem — check your connection and try again.')
    )
    foreach ($entry in $map) { if ($raw -match $entry[0]) { return $entry[1] } }
    $clean = ($raw -replace '^\s*ERROR:\s*', '').Trim()
    if ($clean.Length -gt 220) { $clean = $clean.Substring(0, 220) + '…' }
    return "Failed: $clean"
}

# Wait for a process to exit while staying cancelable (port dead / user cancel) and
# optionally polling. Kills the tree on cancel — or past TimeoutSec (0 = unbounded) —
# and returns $false. Callers distinguish cancel from timeout via $script:cancelFlag.
function Wait-ProcCancelable {
    param ($Process, [scriptblock]$OnPoll = $null, [int]$TimeoutSec = 0)
    $deadline = if ($TimeoutSec -gt 0) { (Get-Date).AddSeconds($TimeoutSec) } else { $null }
    while (-not $Process.HasExited) {
        if (($script:cancelFlag -and $script:cancelFlag.stop) -or $script:portDead) {
            try { Stop-ProcessTree $Process.Id } catch { }
            return $false
        }
        if ($deadline -and ((Get-Date) -gt $deadline)) {
            try { Stop-ProcessTree $Process.Id } catch { }   # a hung ffmpeg must not keep file handles open
            return $false
        }
        if ($OnPoll) { try { & $OnPoll } catch { } }
        Start-Sleep -Milliseconds 150
    }
    return $true
}

function Test-Cancelled { return (($script:cancelFlag -and $script:cancelFlag.stop) -or $script:portDead) }

# Each run gets a PRIVATE yt-dlp temp dir (--paths temp:), so cleanup can wipe
# it wholesale without ever touching a concurrent download's partials/state
# (up to 3 downloads share the same Downloads folder).
function Remove-DownloadTemp {
    param ($tempDir, $meta, $pathf)
    try { if ($meta)  { Remove-Item -LiteralPath $meta  -Force -ErrorAction SilentlyContinue } } catch { }
    try { if ($pathf) { Remove-Item -LiteralPath $pathf -Force -ErrorAction SilentlyContinue } } catch { }
    # taskkill returns before the killed tree releases its file handles: retry
    # briefly so the recursive delete doesn't fail silently on a sharing violation.
    try {
        if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
            for ($i = 0; $i -lt 10; $i++) {
                Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $tempDir)) { break }
                Start-Sleep -Milliseconds 200
            }
        }
    } catch { }
}

# Read one length-prefixed message from stdin (loops until the full buffer is read).
function Read-NativeStdin {
    $stdin = [Console]::OpenStandardInput()
    $lenBuf = New-Object byte[] 4
    $read = 0
    while ($read -lt 4) {
        $r = $stdin.Read($lenBuf, $read, 4 - $read)
        if ($r -le 0) { return $null }
        $read += $r
    }
    $len = [System.BitConverter]::ToInt32($lenBuf, 0)
    if ($len -le 0 -or $len -gt 67108864) { throw "Invalid message length: $len" }
    $buf = New-Object byte[] $len
    $read = 0
    while ($read -lt $len) {
        $r = $stdin.Read($buf, $read, $len - $read)
        if ($r -le 0) { throw "Unexpected EOF while reading message body" }
        $read += $r
    }
    return [System.Text.Encoding]::UTF8.GetString($buf)
}

# Background runspace that blocks reading stdin. EOF (Chrome closed the native port
# = tab closed / SW killed / user cancel) OR any inbound byte flips the shared flag.
function Start-PortWatcher {
    $cf = [hashtable]::Synchronized(@{ stop = $false })
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('cf', $cf)
    $psw = [powershell]::Create()
    $psw.Runspace = $rs
    [void]$psw.AddScript({
        try {
            $sin = [Console]::OpenStandardInput()
            $b = New-Object byte[] 64
            while ($true) {
                $r = $sin.Read($b, 0, 64)
                if ($r -le 0) { $cf.stop = $true; break }   # EOF = port closed
                $cf.stop = $true; break                     # any data = explicit cancel
            }
        } catch { $cf.stop = $true }
    })
    [void]$psw.BeginInvoke()
    return $cf
}

# Runs an executable hidden, captures stdout, and gives up after TimeoutMs.
function Invoke-Captured {
    param ([string]$FilePath, [string[]]$Arguments, [int]$TimeoutMs = 30000)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($Arguments | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    try { $p.StandardInput.Close() } catch { }
    $errTask = $p.StandardError.ReadToEndAsync()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        Stop-ProcessTree $p.Id
        return @{ ExitCode = -1; Out = ''; Err = 'timeout' }
    }
    $p.WaitForExit()
    return @{ ExitCode = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
}


#--------------------------
# Initialization
#--------------------------
$localPath     = $MyInvocation.MyCommand.Path
$currentDate   = Get-Date -Format "ddMMyyyy"
$basePath      = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ytDlpPathEXE  = Join-Path $basePath "yt-dlp.exe"
$ffmpegPath    = Join-Path $basePath "ffmpeg.exe"
$ffprobePath   = Join-Path $basePath "ffprobe.exe"
$denoPath      = Join-Path $basePath "deno.exe"
$versionFile     = Join-Path $basePath "version.txt"        # written by setup.bat = installed CRX version
$updateStateFile = Join-Path $basePath "update_state.txt"   # cached online-version verdict (throttled)
$lastUpdateFile  = Join-Path $basePath "lastupdate.txt"     # stamped after a yt-dlp/deno/ffmpeg update pass
$updateLockFile  = Join-Path $basePath "update.lock"
$encoderFile     = Join-Path $basePath "encoder.txt"
$RepoOwnerRepo   = 'Freenitial/Videos_Download_Reel_Progress_Bar'
$RepoApiLatest   = "https://api.github.com/repos/$RepoOwnerRepo/releases/latest"
$SetupDlUrl      = "https://github.com/$RepoOwnerRepo/releases/latest/download/setup.bat"
$FfmpegZipUrl    = 'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-lgpl.zip'
$MediaExtensions = @('.mp4','.webm','.mkv','.gif','.mp3','.m4a','.aac','.opus','.mov','.flv','.wav','.ogg','.3gp','.webp')

$logsDirectory = Join-Path $basePath "Logs"
if (-Not (Test-Path -LiteralPath $logsDirectory)) { New-Item -ItemType Directory -Path $logsDirectory | Out-Null }
$scriptLogFile = Join-Path $logsDirectory "script-ps1_$currentDate.log"
if (Test-Path -LiteralPath $scriptLogFile) { Add-Content -LiteralPath $scriptLogFile -Value "`r`n--------`r`n" -Encoding UTF8 }

Remove-OldFiles -Path $logsDirectory -Pattern 'script-ps1_*.log' -MaxCount 15
Remove-OldFiles -Path $logsDirectory -Pattern 'ytdlp_*.log'     -MaxCount 20
Remove-OldFiles -Path $logsDirectory -Pattern 'path_*.txt'      -MaxCount 4
Remove-OldFiles -Path $logsDirectory -Pattern 'meta_*.txt'      -MaxCount 4
Remove-OldFiles -Path $logsDirectory -Pattern 'palette_*.png'   -MaxCount 4
Remove-OldFiles -Path $logsDirectory -Pattern 'ffprog_*.txt'    -MaxCount 4

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------------------
# Online-update helpers. Compare the INSTALLED extension version (version.txt,
# written by setup.bat) against the latest GitHub release TAG (e.g. "v1.3").
# Throttled + cached (update_state.txt) so GitHub is hit at most once / 4h.
# Every function is failure-tolerant: the UI must never break on a network hiccup.
# ---------------------------------------------------------------------------
# Always four components, so "2.1" and "2.1.0" compare equal.
function ConvertTo-VersionSafe {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $t = $s.Trim().TrimStart('vV')
    $m = [regex]::Match($t, '^\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    try { return [version]($parts -join '.') } catch { return $null }
}
function Format-Version {
    param($v)
    if ($null -eq $v) { return $null }
    $s = '{0}.{1}' -f $v.Major, $v.Minor
    if ($v.Build -gt 0 -or $v.Revision -gt 0) { $s += '.' + $v.Build }
    if ($v.Revision -gt 0) { $s += '.' + $v.Revision }
    return $s
}
function Get-InstalledVersion {
    try { if (Test-Path -LiteralPath $versionFile) { return (ConvertTo-VersionSafe ([IO.File]::ReadAllText($versionFile))) } } catch { }
    return $null
}
function Get-UpdateStatus {
    param([switch]$ForceRefresh)
    $cur = Get-InstalledVersion
    $curStr = Format-Version $cur
    $cache = $null
    try { if (Test-Path -LiteralPath $updateStateFile) { $cache = ([IO.File]::ReadAllText($updateStateFile) | ConvertFrom-Json) } } catch { $cache = $null }
    $fromCache = {
        $latestC = ConvertTo-VersionSafe ([string]$cache.latest)
        return @{ available = [bool]($null -ne $latestC -and $null -ne $cur -and $latestC -gt $cur); latest = (Format-Version $latestC); current = $curStr }
    }
    if (-not $ForceRefresh -and $cache -and $cache.checkedAt) {
        try {
            $age = ((Get-Date) - [datetime]::Parse([string]$cache.checkedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalHours
            if ($age -lt 4) { return (& $fromCache) }
        } catch { }
    }
    $latest = $null
    try {
        $rel = Invoke-RestMethod -Uri $RepoApiLatest -TimeoutSec 15 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
        if ($rel -and $rel.tag_name) { $latest = ConvertTo-VersionSafe ([string]$rel.tag_name) }
    } catch {
        if ($cache) { return (& $fromCache) }
        return @{ available = $false; latest = $null; current = $curStr }
    }
    $available = ($null -ne $latest -and $null -ne $cur -and $latest -gt $cur)
    $latestStr = Format-Version $latest
    try {
        $obj = [ordered]@{ checkedAt = (Get-Date).ToString('o'); available = [bool]$available; latest = $latestStr; current = $curStr }
        [IO.File]::WriteAllText($updateStateFile, ($obj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    return @{ available = [bool]$available; latest = $latestStr; current = $curStr }
}
function Update-FfmpegIfMissing {
    # ffmpeg has no version API; only ensure it is PRESENT (repair a deleted/corrupt copy).
    if ((Test-Path -LiteralPath $ffmpegPath) -and (Test-Path -LiteralPath $ffprobePath)) { return }
    try {
        $zip = Join-Path $basePath 'ffmpeg_repair.zip'
        Invoke-WebRequest -Uri $FfmpegZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $za = [IO.Compression.ZipFile]::OpenRead($zip)
        try { foreach ($entry in $za.Entries) { if (@('ffmpeg.exe','ffprobe.exe','ffplay.exe') -contains $entry.Name) { [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $basePath $entry.Name), $true) } } } finally { $za.Dispose() }
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Log "ffmpeg repaired (was missing)"
    } catch { Log ("ffmpeg repair failed: {0}" -f $_.Exception.Message) }
}

# ---------------------------------------------------------------------------
# Tool updates (yt-dlp, deno, ffmpeg). Serialized across every host process and
# Windows session by an exclusive lock file in the install folder.
# ---------------------------------------------------------------------------
function Enter-UpdateLock {
    param([int]$TimeoutMs = 0)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try { return [IO.File]::Open($updateLockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { }
        if ($sw.ElapsedMilliseconds -ge $TimeoutMs -or (Test-Cancelled)) { return $null }
        Start-Sleep -Milliseconds 500
    }
}
function Test-UpdateDue {
    param([double]$Hours = 4)
    try {
        if (-not (Test-Path -LiteralPath $lastUpdateFile)) { return $true }
        return (((Get-Date) - (Get-Item -LiteralPath $lastUpdateFile).LastWriteTime).TotalHours -ge $Hours)
    } catch { return $true }
}
# Returns $true when an update pass ran. -Force ignores the 4 h throttle.
function Invoke-ToolUpdate {
    param([switch]$Force, [switch]$Report)
    $lock = Enter-UpdateLock 0
    if (-not $lock) { return $false }
    try {
        if (-not $Force -and -not (Test-UpdateDue 4)) { return $false }
        if ($Report) { Send-Progress 'update' 'Updating yt-dlp…' }
        try {
            $up = Start-Process -FilePath $ytDlpPathEXE -ArgumentList @("--update-to", "stable") -WindowStyle Hidden -PassThru
            if (-not $up.WaitForExit(60000)) { try { Stop-ProcessTree $up.Id } catch { }; Log "yt-dlp update timed out" }
            else { Log ("yt-dlp update ExitCode: {0}" -f $up.ExitCode) }
        } catch { Log ("yt-dlp update failed: {0}" -f $_) }
        if (Test-Cancelled) { return $true }
        if ($Report) { Send-Progress 'update' 'Updating JavaScript engine (deno)…' }
        try {
            if (Test-Path -LiteralPath $denoPath) {
                $dn = Start-Process -FilePath $denoPath -ArgumentList @("upgrade", "--quiet") -WindowStyle Hidden -PassThru
                if (-not $dn.WaitForExit(90000)) { try { Stop-ProcessTree $dn.Id } catch { } }
            } else {
                Log "deno.exe missing; downloading standalone runtime"
                $denoZip = Join-Path $basePath "deno_download.zip"
                $denoUrl = "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip"
                Invoke-WebRequest -Uri $denoUrl -OutFile $denoZip -UseBasicParsing -TimeoutSec 90 -Headers @{ "User-Agent" = "Mozilla/5.0" }
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $za = [System.IO.Compression.ZipFile]::OpenRead($denoZip)
                try { foreach ($entry in $za.Entries) { if ($entry.Name -eq 'deno.exe') { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $denoPath, $true) } } } finally { $za.Dispose() }
                Remove-Item -LiteralPath $denoZip -Force -ErrorAction SilentlyContinue
            }
        } catch { Log ("deno update failed: {0}" -f $_) }
        if (Test-Cancelled) { return $true }
        if ($Report) { Send-Progress 'update' 'Checking ffmpeg…' }
        Update-FfmpegIfMissing
        try { Set-Content -LiteralPath $lastUpdateFile -Value (Get-Date).ToString('o') -Encoding UTF8 } catch { }
        return $true
    } finally {
        try { $lock.Dispose() } catch { }
    }
}
# A download never starts yt-dlp while another host is replacing it: wait (bounded,
# cancel-aware) until the update lock is free.
function Wait-ToolsQuiescent {
    $lock = Enter-UpdateLock 0
    if ($lock) { $lock.Dispose(); return }
    Send-Progress 'update' 'Waiting for a tool update to finish…'
    $lock = Enter-UpdateLock 300000
    if ($lock) { $lock.Dispose() }
}

# ---------------------------------------------------------------------------
# Update of the extension and of this script without elevation. Possible when the
# install made by setup.bat is intact: the current user can replace the served files,
# a browser policy already points the extension at the loopback server, and the
# loopback server script is present. Otherwise the caller falls back to setup.bat.
# ---------------------------------------------------------------------------
$ExtId      = 'olmpldphnohichgojfebcgbciknbmpfm'
$ServerPort = 47653
$ReleaseDownloadBase = "https://github.com/$RepoOwnerRepo/releases/latest/download"
$BrowserPolicies = @(
    @{ Root = 'HKLM:\SOFTWARE\Policies\Google\Chrome';        Detect = 'C:\Users\*\AppData\Local\Google\Chrome\User Data\*\Extensions' },
    @{ Root = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave';  Detect = 'C:\Users\*\AppData\Local\BraveSoftware\Brave-Browser\User Data\*\Extensions' }
)
function Get-CrxVersion {
    param([string]$CrxPath)
    try {
        $bytes = [IO.File]::ReadAllBytes($CrxPath)
        if ($bytes.Length -lt 16 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'Cr24') { return $null }
        $zipOffset = 12 + [BitConverter]::ToUInt32($bytes, 8)
        Add-Type -AssemblyName System.IO.Compression
        $ms = New-Object System.IO.MemoryStream(, [byte[]]$bytes[$zipOffset..($bytes.Length - 1)])
        $za = New-Object System.IO.Compression.ZipArchive($ms)
        try {
            $entry = $za.GetEntry('manifest.json'); if (-not $entry) { return $null }
            $sr = New-Object System.IO.StreamReader($entry.Open())
            $v = [string](($sr.ReadToEnd() | ConvertFrom-Json).version); $sr.Close(); return $v
        } finally { $za.Dispose(); $ms.Dispose() }
    } catch { return $null }
}
function Test-PolicyPointsToLoopback {
    param([string]$Root)
    try {
        $settings = (Get-ItemProperty -Path $Root -Name 'ExtensionSettings' -ErrorAction Stop).ExtensionSettings | ConvertFrom-Json
        $entry = $settings.PSObject.Properties[$ExtId]
        if ($entry -and ([string]$entry.Value.update_url) -like "http://127.0.0.1:$ServerPort/*") { return $true }
    } catch { }
    try {
        $list = Get-ItemProperty -Path (Join-Path $Root 'ExtensionInstallForcelist') -ErrorAction Stop
        foreach ($p in $list.PSObject.Properties) { if ([string]$p.Value -like "$ExtId;http://127.0.0.1:$ServerPort/*") { return $true } }
    } catch { }
    return $false
}
function Invoke-InPlaceUpdate {
    $result = @{ Ok = $false; Reason = ''; Version = $null }
    $served = @('ext.crx', 'freenitial_yt_dlp_script.ps1', 'updates.xml', 'version.txt')
    foreach ($name in $served) {
        $path = Join-Path $basePath $name
        try { $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite); $fs.Dispose() }
        catch { $result.Reason = "cannot write $name"; return $result }
    }
    $serverScript = Join-Path $basePath 'localserver.ps1'
    if (-not (Test-Path -LiteralPath $serverScript)) { $result.Reason = 'loopback server script missing'; return $result }
    $detect = @($BrowserPolicies | Where-Object { Test-PolicyPointsToLoopback $_.Root } | ForEach-Object { $_.Detect })
    if ($detect.Count -eq 0) { $result.Reason = 'no browser policy for the extension'; return $result }

    $stageDir = Join-Path $env:TEMP ('vdrpb_inplace_' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
        $crx = Join-Path $stageDir 'ext.crx'
        $ps1 = Join-Path $stageDir 'freenitial_yt_dlp_script.ps1'
        Invoke-WebRequest -Uri "$ReleaseDownloadBase/ext.crx" -OutFile $crx -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
        Invoke-WebRequest -Uri "$ReleaseDownloadBase/freenitial_yt_dlp_script.ps1" -OutFile $ps1 -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
        $newVer = Get-CrxVersion $crx
        $newV = ConvertTo-VersionSafe $newVer
        $curV = Get-InstalledVersion
        if (-not $newV) { $result.Reason = 'downloaded extension is not a valid package'; return $result }
        if ($curV -and -not ($newV -gt $curV)) { $result.Reason = "downloaded version $newVer is not newer"; return $result }
        $ps1Text = [IO.File]::ReadAllText($ps1)
        if ($ps1Text.Length -lt 20000 -or $ps1Text -notmatch 'function Send-NativeMessage' -or $ps1Text -notmatch 'function Test-SafeUrl') { $result.Reason = 'downloaded script is not valid'; return $result }

        # The running host already parsed this script: replacing the file is safe.
        Copy-Item -LiteralPath $crx -Destination (Join-Path $basePath 'ext.crx') -Force
        Copy-Item -LiteralPath $ps1 -Destination (Join-Path $basePath 'freenitial_yt_dlp_script.ps1') -Force
        $updatesXml = "<?xml version='1.0' encoding='UTF-8'?>`r`n" +
                      "<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>`r`n" +
                      "  <app appid='$ExtId'>`r`n" +
                      "    <updatecheck codebase='http://127.0.0.1:$ServerPort/ext.crx' version='$newVer' />`r`n" +
                      "  </app>`r`n</gupdate>`r`n"
        [IO.File]::WriteAllText((Join-Path $basePath 'updates.xml'), $updatesXml, (New-Object System.Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $basePath 'version.txt'), $newVer, (New-Object System.Text.ASCIIEncoding))
        try { Remove-Item -LiteralPath $updateStateFile -Force -ErrorAction SilentlyContinue } catch { }

        # Loopback server as the current user; it stops by itself once every browser has the version.
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Arg $serverScript), '-ExtId', $ExtId, '-Port', [string]$ServerPort, '-Dir', (Quote-Arg $basePath), '-Detect', (Quote-Arg ($detect -join ';')), '-Version', $newVer)
        $ready = $false
        for ($i = 0; $i -lt 25 -and -not $ready; $i++) {
            try {
                $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$ServerPort/updates.xml" -UseBasicParsing -TimeoutSec 2
                $ready = ($resp.StatusCode -eq 200 -and $resp.Content -match [regex]::Escape("version='$newVer'"))
            } catch { }
            if (-not $ready) { Start-Sleep -Milliseconds 300 }
        }
        if (-not $ready) { $result.Reason = 'loopback server did not start'; return $result }
        $result.Ok = $true
        $result.Version = $newVer
        return $result
    } catch {
        $result.Reason = $_.Exception.Message
        return $result
    } finally {
        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# H.264 encoder selection. The bundled LGPL ffmpeg has no libx264: the first
# hardware or system encoder that works on this machine is used, libopenh264 last.
# The result is cached with ffmpeg's timestamp and probed again when ffmpeg changes.
# ---------------------------------------------------------------------------
$H264Candidates = @(
    'h264_nvenc -preset p2 -rc vbr -cq 23 -b:v 0',
    'h264_qsv -global_quality 23',
    'h264_amf -rc cqp -qp_i 22 -qp_p 23',
    'h264_mf -rate_control quality -quality 75',
    'h264_mf -b:v 6M',
    'libopenh264 -b:v 6M -maxrate 8M -bufsize 12M'
)
function Test-H264Encoder {
    param([string]$Candidate)
    $tmp = Join-Path $logsDirectory ('encprobe_' + [guid]::NewGuid().ToString('N') + '.mp4')
    try {
        $a = @('-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=256x256:rate=10', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '1', '-c:v') + @($Candidate -split ' ') + @('-c:a', 'aac', '-b:a', '160k', '-pix_fmt', 'yuv420p', '-y', $tmp)
        $r = Invoke-Captured -FilePath $ffmpegPath -Arguments $a -TimeoutMs 20000
        return ($r.ExitCode -eq 0 -and (Test-Path -LiteralPath $tmp) -and (Get-Item -LiteralPath $tmp).Length -gt 1000)
    } catch { return $false }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
# Working encoders in preference order (cached).
function Get-H264Encoders {
    if (-not (Test-Path -LiteralPath $ffmpegPath)) { return @() }
    # The candidate list is part of the stamp: editing it probes again.
    $stamp = [string](Get-Item -LiteralPath $ffmpegPath).LastWriteTimeUtc.Ticks + '|' + [string]([string]::Join(';', $H264Candidates)).GetHashCode()
    try {
        if (Test-Path -LiteralPath $encoderFile) {
            $lines = @([IO.File]::ReadAllLines($encoderFile) | Where-Object { $_ -ne '' })
            if ($lines.Count -ge 2 -and $lines[0] -eq $stamp) { return @($lines | Select-Object -Skip 1) }
        }
    } catch { }
    $working = @($H264Candidates | Where-Object { Test-H264Encoder $_ })
    Log ("H.264 encoders available: " + ($working -join ' ; '))
    try { [IO.File]::WriteAllLines($encoderFile, [string[]](@($stamp) + $working)) } catch { }
    return $working
}

# "SS", "MM:SS" or "HH:MM:SS" with optional decimals -> seconds ($null when empty).
function ConvertFrom-Clock {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $total = 0.0
    foreach ($part in $Text.Split(':')) {
        $v = 0.0
        if (-not [double]::TryParse($part, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $null }
        $total = $total * 60 + $v
    }
    return $total
}

# Streams of a media file: @{ Video = codec; Audio = codec; Duration = seconds }.
function Get-MediaInfo {
    param([string]$Path)
    $info = @{ Video = $null; Audio = $null; Duration = 0.0 }
    if (-not (Test-Path -LiteralPath $ffprobePath)) { return $info }
    try {
        $r = Invoke-Captured -FilePath $ffprobePath -Arguments @('-v', 'error', '-show_entries', 'stream=codec_type,codec_name:format=duration', '-of', 'json', $Path) -TimeoutMs 30000
        $j = $r.Out | ConvertFrom-Json
        foreach ($s in @($j.streams)) {
            if ($s.codec_type -eq 'video' -and -not $info.Video -and $s.codec_name -notin @('mjpeg', 'png')) { $info.Video = [string]$s.codec_name }
            elseif ($s.codec_type -eq 'audio' -and -not $info.Audio) { $info.Audio = [string]$s.codec_name }
        }
        $d = 0.0
        if ($j.format -and [double]::TryParse([string]$j.format.duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $info.Duration = $d }
    } catch { Log "ffprobe failed on ${Path}: $_" }
    return $info
}


#--------------------------
# Detached tool update (started by the checkupdate mode after it answered)
#--------------------------
if ($args -contains '-SelfUpdate') {
    Log "Self-update pass started"
    try { [void](Invoke-ToolUpdate) } catch { Log "Self-update failed: $_" }
    Log "Self-update pass finished"
    [Environment]::Exit(0)
}


#--------------------------
# Read the incoming command
#--------------------------
try {
    $inputJson = Read-NativeStdin
} catch {
    Log "Error reading stdin: $_"
    Send-Done $false "Failed to read the request: $_"
    exit
}
if ($null -eq $inputJson) { exit }
try {
    $inputData = $inputJson | ConvertFrom-Json
} catch {
    Log "Error parsing JSON: $_"
    Send-Done $false "Unreadable request: $_"
    exit
}

if     ($inputData.URL)         { $mode = 'download';    $url = [string]$inputData.URL; Log "Input URL = $url" }
elseif ($inputData.SHOW)        { $mode = 'show';        $fileToShow = [string]$inputData.SHOW; Log "File to show = $fileToShow" }
elseif ($inputData.COPY)        { $mode = 'copy';        $fileToCopy = [string]$inputData.COPY; Log "File to copy = $fileToCopy" }
elseif ($inputData.SERVE)       { $mode = 'serve';       $fileToServe = [string]$inputData.SERVE; Log "File to serve = $fileToServe" }
elseif ($inputData.OPENLOG)     { $mode = 'openlog';     $logToOpen = [string]$inputData.OPENLOG; Log "Log to open = $logToOpen" }
elseif ($null -ne $inputData.STAT) { $mode = 'stat' }
elseif ($inputData.PICKFOLDER)  { $mode = 'pickfolder';  Log "Folder picker request" }
elseif ($inputData.checkUpdate) { $mode = 'checkupdate'; Log "Check-update request" }
elseif ($inputData.doUpdate)    { $mode = 'doupdate';    Log "Do-update request" }
else   { Log "No valid parameter provided."; Send-Done $false "No valid command received."; exit }


#==========================================================================
# DOWNLOAD
#==========================================================================
if ($mode -eq 'download') {

    if (-not (Test-SafeUrl $url)) {
        Log "Rejected unsafe URL: $url"
        Send-Done $false "Invalid or unsafe URL."
        exit
    }
    $cut = $null
    if ($inputData.cut) {
        $cut = [string]$inputData.cut
        if (-not (Test-SafeCut $cut)) {
            Log "Rejected unsafe cut spec: $cut"
            Send-Done $false "Invalid cut range."
            exit
        }
    }
    $isGif = AsBool $inputData.isGIF
    $isMp3 = (-not $isGif) -and (AsBool $inputData.mp3)
    $convertMp4 = (-not $isGif) -and (-not $isMp3) -and (AsBool $inputData.convertMP4)
    # Older callers do not send the field: precise (re-encoded) cuts stay the default.
    $preciseCut = if ($null -eq $inputData.preciseCut) { $true } else { AsBool $inputData.preciseCut }
    $preset = [string]$inputData.preset
    if ($preset -notin @('best', '1080', '720', 'size25')) { $preset = '' }
    $playlistItem = 0
    if ($null -ne $inputData.playlistItem) { [void][int]::TryParse([string]$inputData.playlistItem, [ref]$playlistItem); if ($playlistItem -lt 1 -or $playlistItem -gt 50) { $playlistItem = 0 } }

    Send-Progress 'prepare' 'Preparing download…'

    # Watch the port from the very start so the waits below are cancelable too.
    $script:cancelFlag = Start-PortWatcher

    #---------------------- Destination ----------------------
    $downloadDir = Join-Path $env:USERPROFILE "Downloads"
    if ($inputData.downloadDir) {
        $dd = ([string]$inputData.downloadDir).Trim()
        if (-not [IO.Path]::IsPathRooted($dd) -or $dd -match '(^|[\\/])\.\.([\\/]|$)' -or $dd.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) {
            Log "Rejected download folder: $dd"
            Send-Done $false "Invalid download folder: $dd"
            [Environment]::Exit(0)
        }
        $downloadDir = $dd
    }
    $subfolder = [string]$inputData.subfolder
    if ($subfolder -match '^[A-Za-z]{1,20}$') { $downloadDir = Join-Path $downloadDir $subfolder }
    if (-not (Test-Path -LiteralPath $downloadDir -PathType Container)) {
        try { New-Item -ItemType Directory -Path $downloadDir -Force -ErrorAction Stop | Out-Null }
        catch {
            Log "Download folder not available: $downloadDir ($_)"
            Send-Done $false "Download folder not found: $downloadDir"
            [Environment]::Exit(0)
        }
    }

    # Never launch yt-dlp while another host replaces it.
    Wait-ToolsQuiescent
    if (Test-Cancelled) { Log "Cancelled while waiting for a tool update"; [Environment]::Exit(0) }

    #---------------------- Cut strategy ----------------------
    # yt-dlp reads a section through ffmpeg, which sites throttle to about twice the
    # playback speed. When the whole video is short, or the clip is most of it, the
    # full file is downloaded at full speed and cut locally instead.
    $cutStart = 0.0; $cutEnd = $null; $localCut = $false
    $mediaDurationHint = 0.0
    if ($null -ne $inputData.mediaDuration) { [void][double]::TryParse([string]$inputData.mediaDuration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$mediaDurationHint) }
    if ($cut) {
        $bounds = $cut.Substring(1).Split('-')
        $s0 = ConvertFrom-Clock $bounds[0]; if ($null -ne $s0) { $cutStart = $s0 }
        $cutEnd = ConvertFrom-Clock $bounds[1]
        if ($mediaDurationHint -gt 0 -and $mediaDurationHint -lt 86400) {
            $clipLength = $(if ($null -ne $cutEnd) { [math]::Min($cutEnd, $mediaDurationHint) } else { $mediaDurationHint }) - $cutStart
            $localCut = ($mediaDurationHint -le 600) -or ($clipLength -ge $mediaDurationHint * 0.5)
        }
    }
    # Share of the progress bar used by yt-dlp's own download (the local cut takes the rest).
    $script:dlMax = if ($localCut) { 48 } else { 90 }
    $script:ppMin = if ($localCut) { 50 } else { 93 }
    $script:sectionLength = if ($cut -and -not $localCut -and $null -ne $cutEnd) { $cutEnd - $cutStart } else { 0.0 }
    $script:cutLabel = if ($preciseCut) { 'Cutting…' } else { 'Downloading clip…' }
    Log ("Cut: " + $(if (-not $cut) { 'none' } elseif ($localCut) { "local ($cut, media $mediaDurationHint s)" } else { "section ($cut)" }))

    #---------------------- Build yt-dlp arguments ----------------------
    # Clips and reduced-quality copies of the same video keep distinct names (yt-dlp
    # would otherwise return the file already on disk).
    $nameSuffix = ''
    if ($cut -and -not $localCut) { $nameSuffix += ' (clip %(section_start)d-%(section_end)ds)' }
    if ((-not $isMp3) -and (-not $isGif) -and $preset -in @('1080', '720')) { $nameSuffix += " ($($preset)p)" }
    elseif ((-not $isMp3) -and (-not $isGif) -and $preset -eq 'size25') { $nameSuffix += ' (25MB)' }
    $outTemplate = '%(uploader,channel,uploader_id|unknown).30B - %(title|video).70B [%(id)s]' + $nameSuffix + '.%(ext)s'
    $uniq        = [guid]::NewGuid().ToString('N')
    $pathFile    = Join-Path $logsDirectory ("path_" + $uniq + ".txt")
    $metaFile    = Join-Path $logsDirectory ("meta_" + $uniq + ".txt")
    $ffprog      = Join-Path $logsDirectory ("ffprog_" + $uniq + ".txt")
    # Private temp dir on the SAME volume as the final file (cheap final move);
    # cleanup deletes it recursively without touching sibling downloads.
    $tempDir     = Join-Path $downloadDir ('.vdrpb_tmp_' + $uniq)
    try { if (-not (Test-Path -LiteralPath $tempDir)) { New-Item -ItemType Directory -Path $tempDir -Force | Out-Null } } catch { }
    # Sweep temp dirs orphaned by a hard host death (crash/shutdown mid-download);
    # the 24h age guard keeps concurrent live runs untouched.
    try {
        Get-ChildItem -LiteralPath $downloadDir -Directory -Filter '.vdrpb_tmp_*' -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-24) } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }

    $PresetArgs = @{
        'best'   = @('-S', 'res,fps,vcodec:h264,acodec:aac')
        '1080'   = @('-S', 'res:1080,fps,vcodec:h264,acodec:aac')
        '720'    = @('-S', 'res:720,fps,vcodec:h264,acodec:aac')
        # Largest known size that fits 25 MB; unknown sizes fall back to 480p-class, then worst.
        'size25' = @('-f', 'bv[filesize<20M]+ba[filesize<5M]/bv[filesize_approx<20M]+ba[filesize_approx<5M]/b[filesize<25M]/b[filesize_approx<25M]/wv[filesize>0]+wa[filesize>0]/bv[height<=854][width<=854]+ba/b[height<=854][width<=854]/wv+wa/w', '-S', 'vcodec:h264,acodec:aac')
    }

    $tokens = @(
        '--no-mtime', '--newline', '--no-playlist', '--windows-filenames', '--no-warnings',
        '--socket-timeout', '30', '--retries', '10', '--fragment-retries', '10',
        '--progress-template', 'download:[[PROG]]|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s',
        '--print-to-file', 'before_dl:%(.{title,uploader,duration,thumbnail})j', $metaFile,
        '--print-to-file', 'after_move:%(filepath)s', $pathFile,
        # Hashtags removed from titles, spaces collapsed, never an empty title.
        '--replace-in-metadata', 'title', '(?:^|\s)#\S+', '',
        '--replace-in-metadata', 'title', '\s{2,}', ' ',
        '--replace-in-metadata', 'title', '^\s+|\s+$', '',
        '--replace-in-metadata', 'title', '^$', 'video',
        # A file cut locally is downloaded into the private temp folder: never onto a
        # file of the same name already in the download folder.
        '--paths', $(if ($localCut) { $tempDir } else { $downloadDir }),
        '--paths', ('temp:' + $tempDir),
        '--output', $outTemplate
    )
    if (Test-Path -LiteralPath $ffmpegPath) { $tokens += @('--ffmpeg-location', $ffmpegPath) }
    if (Test-Path -LiteralPath $denoPath)   { $tokens += @('--js-runtimes', "deno:$denoPath") }
    if ($playlistItem -gt 0) { $tokens += @('--playlist-items', [string]$playlistItem) }
    if ((-not $isMp3) -and (-not $isGif) -and $preset) { $tokens += $PresetArgs[$preset] }
    if ($cut -and -not $localCut) {
        $tokens += @('--download-sections', $cut, '--hls-use-mpegts')
        if ($preciseCut) {
            $tokens += @('--force-keyframes-at-cuts')
            # Without libx264 ffmpeg would fall back to low-quality mpeg4 for the re-encoded section.
            if (-not $isMp3) {
                $enc = @(Get-H264Encoders) | Select-Object -First 1
                if ($enc) { $tokens += @('--downloader-args', "ffmpeg_o:-c:v $enc -pix_fmt yuv420p -c:a aac -b:a 160k") }
            }
        }
    }
    if ($isMp3) { $tokens += @('-x', '--audio-format', 'mp3', '--audio-quality', '0') }
    elseif ($convertMp4 -or ($cut -and $preciseCut -and -not $localCut -and -not $isGif)) { $tokens += @('--merge-output-format', 'mp4') }
    if (AsBool $inputData.useChromeCookies) { $tokens += @('--cookies-from-browser', 'chrome') }
    if (AsBool $inputData.keepConsoleOpen)  { $tokens += @('-v') }
    $tokens += @('--', $url)

    $argString = ($tokens | ForEach-Object { Quote-Arg $_ }) -join ' '
    Log "yt-dlp args: $argString"

    #---------------------- Run yt-dlp with live progress ----------------------
    $ytLog = Join-Path $logsDirectory ("ytdlp_" + $uniq + ".log")
    # Monotonic clock for the progress throttle. NOT [Environment]::TickCount:
    # it is an Int32 that goes negative past ~25 days of uptime.
    $script:progSw   = [System.Diagnostics.Stopwatch]::StartNew()
    $script:globalPct = 0
    $script:metaSent = $false
    $dlStart = Get-Date

    $readMeta = {
        if ($script:metaSent -or -not (Test-Path -LiteralPath $metaFile)) { return }
        try {
            # One JSON line per item (playlists): the first item describes the card.
            $first = @([System.IO.File]::ReadAllLines($metaFile, [System.Text.Encoding]::UTF8) | Where-Object { $_.TrimStart().StartsWith('{') }) | Select-Object -First 1
            if ($first) {
                $md = $first | ConvertFrom-Json
                if ($md.duration) { $script:mediaDuration = [double]$md.duration }
                Send-Meta $md.title $md.uploader $md.duration $md.thumbnail
                $script:metaSent = $true
            }
        } catch { }
    }

    # Runs yt-dlp once. Returns @{ ExitCode; Aborted; Reason }.
    function Invoke-YtDlpRun {
        $script:streamCount = 1
        $script:streamsSeen = 0
        $script:itemIndex   = 1
        $script:itemCount   = 1
        $script:analyzed    = $false
        $script:postprocessing = $false
        $script:errLines    = New-Object System.Collections.ArrayList
        $script:lastProgSent = [long]-1000000
        $script:lastSentPct  = -1
        $script:ytLogWriter = $null
        try {
            $script:ytLogWriter = New-Object System.IO.StreamWriter($ytLog, $true, (New-Object System.Text.UTF8Encoding($false)))
            $script:ytLogWriter.AutoFlush = $true
        } catch { $script:ytLogWriter = $null }
        $result = @{ ExitCode = -1; Aborted = $false; Reason = '' }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $ytDlpPathEXE
        $psi.Arguments              = $argString
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
        $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
        # Give yt-dlp its OWN stdin (closed) instead of inheriting our native-messaging
        # pipe, which the port-watcher runspace is reading — otherwise they contend and
        # yt-dlp can stall producing no output.
        $psi.RedirectStandardInput = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        $queue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
        $outEvt = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -MessageData $queue -Action {
            if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
        }
        $errEvt = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $queue -Action {
            if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue('[[ERR]]' + $EventArgs.Data) }
        }

        try {
            [void]$proc.Start()
            try { $proc.StandardInput.Close() } catch { }   # empty stdin, immediate EOF for yt-dlp
            $proc.BeginOutputReadLine()
            $proc.BeginErrorReadLine()

            $handleLine = {
                param($line)
                if ([string]::IsNullOrEmpty($line)) { return }
                $isErr = $false
                if ($line.StartsWith('[[ERR]]')) { $isErr = $true; $line = $line.Substring(7) }

                if ($line.StartsWith('[[PROG]]')) {
                    # yt-dlp prints a last progress line for the merged file: the card stays on Processing.
                    if ($script:postprocessing) { return }
                    $p = $line.Split('|')
                    $filePct = $null; $dl = $null; $tot = $null
                    if ($p.Length -ge 6) {
                        $dlv = [int64]0; $totv = [int64]0
                        [void][int64]::TryParse($p[4].Trim(), [ref]$dlv)
                        [void][int64]::TryParse($p[5].Trim(), [ref]$totv)
                        if ($totv -le 0 -and $p.Length -ge 7) { [void][int64]::TryParse($p[6].Trim(), [ref]$totv) }
                        if ($totv -gt 0) { $filePct = ($dlv / $totv) * 100.0; $dl = $dlv; $tot = $totv }
                    }
                    if ($null -eq $filePct -and $p.Length -ge 2) {
                        $mm = [regex]::Match($p[1].Trim(), '^([\d.]+)%')
                        if ($mm.Success) { $filePct = [double]$mm.Groups[1].Value }
                    }
                    if ($null -ne $filePct) {
                        $n = [math]::Max($script:streamCount, [math]::Max(1, $script:streamsSeen))
                        $idx = [math]::Max(0, $script:streamsSeen - 1)
                        $itemFrac = [math]::Min(1.0, ($idx + ($filePct / 100.0)) / $n)
                        $overall = (($script:itemIndex - 1) + $itemFrac) / [math]::Max(1, $script:itemCount)
                        $g = [int][math]::Floor($overall * $script:dlMax)
                        if ($g -gt $script:globalPct) { $script:globalPct = $g }
                        # Throttle: send on integer-percent change OR every 250ms (keeps speed/ETA live).
                        $nowMs = $script:progSw.ElapsedMilliseconds
                        if (($script:globalPct -ne $script:lastSentPct) -or (($nowMs - $script:lastProgSent) -ge 250)) {
                            $script:lastSentPct  = $script:globalPct
                            $script:lastProgSent = $nowMs
                            $msg = if ($script:itemCount -gt 1) { "Downloading $($script:itemIndex) of $($script:itemCount)…" } else { 'Downloading…' }
                            Send-Progress -Stage 'download' -Message $msg -Percent $script:globalPct -Speed ($p[2].Trim()) -Eta ($p[3].Trim()) -Downloaded $dl -Total $tot
                        }
                    }
                    return
                }

                if ($script:ytLogWriter) { try { $script:ytLogWriter.WriteLine($line) } catch { } }

                # A section is fetched by ffmpeg, which reports its own position
                # ("time=00:01:29.51 ... speed=1.4x") instead of yt-dlp's progress lines.
                if ($line -match '^(?:frame|size)=.*\btime=(\d+):(\d{2}):(\d{2}(?:\.\d+)?)') {
                    $pos = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [double]::Parse($Matches[3], [Globalization.CultureInfo]::InvariantCulture)
                    if ($script:sectionLength -le 0 -and $script:mediaDuration) { $script:sectionLength = [double]$script:mediaDuration - $cutStart }
                    $speedX = 0.0
                    $sm = [regex]::Match($line, 'speed=\s*([\d.]+)x')
                    if ($sm.Success) { [void][double]::TryParse($sm.Groups[1].Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$speedX) }
                    $eta = $null
                    if ($script:sectionLength -gt 0) {
                        $frac = [math]::Min(1.0, $pos / $script:sectionLength)
                        $g = [int][math]::Floor($frac * $script:dlMax)
                        if ($g -gt $script:globalPct) { $script:globalPct = $g }
                        if ($speedX -gt 0) {
                            $left = [int][math]::Max(0, ($script:sectionLength - $pos) / $speedX)
                            $eta = '{0:00}:{1:00}' -f [math]::Floor($left / 60), ($left % 60)
                        }
                    }
                    $nowMs = $script:progSw.ElapsedMilliseconds
                    if (($script:globalPct -ne $script:lastSentPct) -or (($nowMs - $script:lastProgSent) -ge 1000)) {
                        $script:lastSentPct  = $script:globalPct
                        $script:lastProgSent = $nowMs
                        $pctArg = if ($script:sectionLength -gt 0) { $script:globalPct } else { $null }
                        $speedArg = if ($speedX -gt 0) { $speedX.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + 'x' } else { $null }
                        Send-Progress -Stage 'download' -Message $script:cutLabel -Percent $pctArg -Speed $speedArg -Eta $eta
                    }
                    return
                }

                if ($isErr) { [void]$script:errLines.Add($line) }

                if ($line -match '^\[download\] Downloading (?:item|video) (\d+) of (\d+)') {
                    $script:itemIndex = [int]$Matches[1]; $script:itemCount = [int]$Matches[2]
                    $script:streamsSeen = 0; $script:streamCount = 1
                }
                elseif ($line -match '^\[info\].*Downloading\s+\d+\s+format') {
                    $fm = [regex]::Match($line, ':\s*([0-9a-zA-Z+\-\.]+)\s*$')
                    if ($fm.Success) { $c = ($fm.Groups[1].Value -split '\+').Count; if ($c -gt $script:streamCount) { $script:streamCount = $c } }
                }
                elseif ($line -match '^\[download\]\s+Destination:') { $script:streamsSeen++; $script:postprocessing = $false }
                elseif ($line -match 'Retrying|Got server error|timed out|Temporary failure|Unable to connect') {
                    Send-Progress -Stage 'download' -Message 'Unstable connection, retrying…' -Percent $script:globalPct
                }
                elseif ($line -match '^\[Merger\]')       { $script:postprocessing = $true; if ($script:itemCount -le 1 -and $script:globalPct -lt $script:ppMin) { $script:globalPct = $script:ppMin }; Send-Progress -Stage 'postprocess' -Message 'Merging audio/video tracks…' -Percent $script:globalPct }
                elseif ($line -match '^\[ExtractAudio\]') { $script:postprocessing = $true; if ($script:itemCount -le 1 -and $script:globalPct -lt $script:ppMin) { $script:globalPct = $script:ppMin }; Send-Progress -Stage 'postprocess' -Message "Extracting audio…" -Percent $script:globalPct }
                elseif ($line -match '^\[(VideoConvertor|VideoRemuxer|Recode)\]') { $script:postprocessing = $true; if ($script:globalPct -lt ($script:ppMin + 2)) { $script:globalPct = $script:ppMin + 2 }; Send-Progress -Stage 'postprocess' -Message 'Converting format…' -Percent $script:globalPct }
                elseif ($line -match '^\[(youtube|info|generic|facebook|instagram|tiktok|twitter)') { if (-not $script:analyzed) { $script:analyzed = $true; Send-Progress -Stage 'prepare' -Message 'Analyzing video…' } }
            }

            $lastActivity = Get-Date
            $loopN = 0
            while ((-not $proc.HasExited) -or ($queue.Count -gt 0)) {
                if (Test-Cancelled) { $result.Aborted = $true; $result.Reason = 'cancel'; break }
                # Meta polling gated to every 8th iteration.
                $loopN++
                if (-not $script:metaSent -and ($loopN % 8 -eq 0)) { & $readMeta }
                if ($queue.Count -gt 0) {
                    $lastActivity = Get-Date
                    & $handleLine ($queue.Dequeue())
                } else {
                    # Inactivity watchdog. Download phase: 120s. Post-processing is legitimately
                    # SILENT on stdout, so it gets a 30 min ceiling.
                    $idleLimit = if ($script:postprocessing) { 1800 } else { 120 }
                    if (((Get-Date) - $lastActivity).TotalSeconds -gt $idleLimit) {
                        $result.Aborted = $true
                        $result.Reason = if ($script:postprocessing) { 'pp-timeout' } else { 'timeout' }
                        break
                    }
                    Start-Sleep -Milliseconds 120
                }
            }

            if (-not $result.Aborted) {
                $proc.WaitForExit()
                # PS 5.1: the event queue is only pumped while the script sleeps, so the
                # last lines (after_move path) need a short drain after the exit.
                $flushDeadline = (Get-Date).AddMilliseconds(400)
                while ((Get-Date) -lt $flushDeadline) {
                    while ($queue.Count -gt 0) { & $handleLine ($queue.Dequeue()) }
                    Start-Sleep -Milliseconds 50
                }
                while ($queue.Count -gt 0) { & $handleLine ($queue.Dequeue()) }
                & $readMeta
                $result.ExitCode = $proc.ExitCode
            } else {
                try { if (-not $proc.HasExited) { Stop-ProcessTree $proc.Id } } catch { }
            }
        } finally {
            try { Unregister-Event -SourceIdentifier $outEvt.Name -ErrorAction SilentlyContinue } catch { }
            try { Unregister-Event -SourceIdentifier $errEvt.Name -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job -Job $outEvt -Force -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job -Job $errEvt -Force -ErrorAction SilentlyContinue } catch { }
            try { if ($script:ytLogWriter) { $script:ytLogWriter.Close(); $script:ytLogWriter = $null } } catch { }
        }
        return $result
    }

    $lastErrorLine = {
        $l = ($script:errLines | Where-Object { $_ -match '^ERROR' } | Select-Object -Last 1)
        if (-not $l) { $l = ($script:errLines | Select-Object -Last 1) }
        return [string]$l
    }
    $failExtra = {
        param([string]$detail)
        if ($detail.Length -gt 600) { $detail = $detail.Substring(0, 600) }
        return @{ detail = $detail; logPath = $ytLog }
    }

    Send-Progress 'prepare' 'Analyzing video…'
    try {
        $run = Invoke-YtDlpRun
        # Site changes break extractors until yt-dlp is updated: when the binary is older
        # than a day, update it now and try once more.
        if (-not $run.Aborted -and $run.ExitCode -ne 0) {
            $errLine = & $lastErrorLine
            $ytAgeH = 0
            try { $ytAgeH = ((Get-Date) - (Get-Item -LiteralPath $ytDlpPathEXE).LastWriteTime).TotalHours } catch { }
            if ($errLine -match 'Unable to extract|Unsupported URL|HTTP Error 400|Requested format is not available|nsig extraction|Signature extraction|Failed to extract' -and $ytAgeH -ge 24) {
                Log "Extractor error with a $([int]$ytAgeH) h old yt-dlp: updating then retrying"
                if (-not (Invoke-ToolUpdate -Force -Report)) { Wait-ToolsQuiescent }
                if (Test-Cancelled) { Remove-DownloadTemp $tempDir $metaFile $pathFile; [Environment]::Exit(0) }
                Remove-Item -LiteralPath $pathFile -Force -ErrorAction SilentlyContinue
                Send-Progress 'prepare' 'Analyzing video…'
                $run = Invoke-YtDlpRun
            }
        }
    } catch {
        Log "Error executing yt-dlp: $_"
        Remove-DownloadTemp $tempDir $metaFile $pathFile
        Send-Done $false ("Error during download: {0}" -f $_) $null (& $failExtra ([string]$_))
        [Environment]::Exit(0)
    }

    if ($run.Aborted) {
        Remove-DownloadTemp $tempDir $metaFile $pathFile
        if ($run.Reason -eq 'timeout') {
            Log "Watchdog: no output for 120s -> aborting"
            Send-Done $false "Download stalled (no response from the server). Check your connection and try again." $null (& $failExtra 'No output from yt-dlp for 120 s')
        } elseif ($run.Reason -eq 'pp-timeout') {
            Log "Watchdog: post-processing silent for 30 min -> aborting"
            Send-Done $false "Video processing (conversion/merge) appears stuck. Try again." $null (& $failExtra 'Post-processing silent for 30 min')
        } else {
            Log "Aborted by port close / cancel"
        }
        [Environment]::Exit(0)
    }

    Log "yt-dlp exit code: $($run.ExitCode)"

    if ($run.ExitCode -ne 0) {
        $lastErr = & $lastErrorLine
        Remove-DownloadTemp $tempDir $metaFile $pathFile
        Send-Done $false (Translate-YtDlpError $lastErr) $null (& $failExtra $lastErr)
        [Environment]::Exit(0)
    }

    # Final paths (UTF-8 from print-to-file, one line per item), fallback to the
    # single fresh media file of this run.
    $finalPaths = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $pathFile) {
        try {
            foreach ($ln in [System.IO.File]::ReadAllLines($pathFile, [System.Text.Encoding]::UTF8)) {
                $pth = $ln.Trim()
                if ($pth -and (Test-Path -LiteralPath $pth) -and -not $finalPaths.Contains($pth)) { [void]$finalPaths.Add($pth) }
            }
        } catch { Log "path file read error: $_" }
    }
    if ($finalPaths.Count -eq 0) {
        $cand = @(Get-ChildItem -LiteralPath $(if ($localCut) { $tempDir } else { $downloadDir }) -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -ge $dlStart -and ($MediaExtensions -contains $_.Extension.ToLower()) } |
                  Sort-Object LastWriteTime -Descending)
        # Only trust the fallback when it is unambiguous (exactly one fresh media file of
        # this run), so a concurrent download in the same folder can't be mistaken for ours.
        if ($cand.Count -eq 1) { [void]$finalPaths.Add($cand[0].FullName) }
    }
    Remove-Item -LiteralPath $pathFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $metaFile -Force -ErrorAction SilentlyContinue
    # The file to cut locally is still in the temp folder: it is removed after the cut.
    if (-not $localCut) { try { if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }

    if ($finalPaths.Count -eq 0) {
        Remove-DownloadTemp $tempDir $null $null
        Send-Done $false "Download finished but the file could not be found." $null (& $failExtra 'No output file reported by yt-dlp')
        [Environment]::Exit(0)
    }
    foreach ($pth in @($finalPaths)) {
        if ((Get-Item -LiteralPath $pth).Length -lt 1024) {
            Remove-Item -LiteralPath $pth -Force -ErrorAction SilentlyContinue
            [void]$finalPaths.Remove($pth)
        }
    }
    if ($finalPaths.Count -eq 0) {
        Remove-DownloadTemp $tempDir $null $null
        Send-Done $false "The downloaded file is empty or corrupted. Try again." $null (& $failExtra 'Output file smaller than 1 KB')
        [Environment]::Exit(0)
    }

    $doneMsg = if ($finalPaths.Count -gt 1) { "Download complete ($($finalPaths.Count) files)." } else { "Download complete." }

    # Progress file polling shared by the ffmpeg post-steps: maps ffmpeg's position
    # onto [$script:ppFrom, $script:ppTo].
    $script:lastPpSent = [long]-1000000
    $ppPoll = {
        $prevPct = $script:globalPct
        if ($script:ppDuration -gt 0 -and (Test-Path -LiteralPath $ffprog)) {
            try {
                # ffmpeg keeps the file open for writing: read it with shared access.
                $fsProg = [IO.File]::Open($ffprog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                try { $t = (New-Object IO.StreamReader($fsProg)).ReadToEnd() } finally { $fsProg.Dispose() }
                $ms = [regex]::Matches($t, 'out_time_us=(\d+)')
                if ($ms.Count -gt 0) {
                    $frac = [math]::Min(1.0, ([double]$ms[$ms.Count - 1].Groups[1].Value / 1e6) / $script:ppDuration)
                    $gp = [int]($script:ppFrom + $frac * ($script:ppTo - $script:ppFrom))
                    if ($gp -gt $script:globalPct) { $script:globalPct = $gp }
                }
            } catch { }
        }
        $nowMs = $script:progSw.ElapsedMilliseconds
        if (($script:globalPct -ne $prevPct) -or (($nowMs - $script:lastPpSent) -ge 2000)) {
            $script:lastPpSent = $nowMs
            Send-Progress 'postprocess' $script:ppLabel $script:globalPct
        }
    }

    #---------------------- Local cut ----------------------
    # The full file is in the temp folder: the clip is written into the download
    # folder (re-encoded when precise, stream copy from the previous keyframe when
    # fast), then the temp folder goes. A failed cut keeps the full video.
    if ($localCut) {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $cutFailed = 0
        for ($i = 0; $i -lt $finalPaths.Count; $i++) {
            $src = [string]$finalPaths[$i]
            $info = Get-MediaInfo $src
            $srcDuration = if ($info.Duration -gt 0) { $info.Duration } elseif ($script:mediaDuration) { [double]$script:mediaDuration } else { 0.0 }
            $endAt = if ($null -ne $cutEnd -and ($srcDuration -le 0 -or $cutEnd -lt $srcDuration)) { $cutEnd } else { $srcDuration }
            $length = if ($endAt -gt $cutStart) { $endAt - $cutStart } else { 0.0 }
            $ext = [IO.Path]::GetExtension($src).ToLowerInvariant()
            $stem = [IO.Path]::GetFileNameWithoutExtension($src)
            $done = $false
            if ($srcDuration -gt 0 -and $cutStart -ge $srcDuration) {
                Log "Cut start $cutStart s is past the end ($srcDuration s)"
            } else {
                $reencode = $preciseCut -and (-not $isMp3) -and ($null -ne $info.Video)
                $outExt = if ($reencode) { '.mp4' } else { $ext }
                $label = ' (clip {0}-{1}s)' -f [int][math]::Floor($cutStart), [int][math]::Floor($endAt)
                $target = Join-Path $downloadDir ($stem + $label + $outExt)
                for ($k = 2; (Test-Path -LiteralPath $target) -and $k -lt 100; $k++) { $target = Join-Path $downloadDir ($stem + $label + " ($k)" + $outExt) }
                $script:ppDuration = $length
                $script:ppFrom = [math]::Min(98, $script:ppMin + [int]($i * 49 / $finalPaths.Count))
                $script:ppTo = [math]::Min(99, $script:ppMin + [int](($i + 1) * 49 / $finalPaths.Count))
                $script:ppLabel = 'Cutting…'
                if ($script:globalPct -lt $script:ppFrom) { $script:globalPct = $script:ppFrom }
                Send-Progress 'postprocess' $script:ppLabel $script:globalPct
                $encoders = if ($reencode) { @(Get-H264Encoders) } else { @('copy') }
                foreach ($enc in $encoders) {
                    $a = @('-y', '-nostdin', '-hide_banner', '-loglevel', 'error', '-progress', $ffprog, '-ss', $cutStart.ToString('0.###', $inv), '-i', $src)
                    if ($null -ne $cutEnd -and $length -gt 0) { $a += @('-t', $length.ToString('0.###', $inv)) }
                    if ($enc -eq 'copy') { $a += @('-map', '0', '-c', 'copy', '-avoid_negative_ts', 'make_zero') }
                    else { $a += @('-map', '0:v:0', '-map', '0:a:0?', '-c:v') + @($enc -split ' ') + @('-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '160k') }
                    if ($outExt -eq '.mp4') { $a += @('-movflags', '+faststart') }
                    $a += @($target)
                    Log "ffmpeg cut: $enc -> $target"
                    $pc = Start-Process -FilePath $ffmpegPath -ArgumentList ($a | ForEach-Object { Quote-Arg $_ }) -WindowStyle Hidden -PassThru
                    $null = $pc.Handle
                    $okc = Wait-ProcCancelable $pc $ppPoll -TimeoutSec 7200
                    Remove-Item -LiteralPath $ffprog -Force -ErrorAction SilentlyContinue
                    if (-not $okc) {
                        Start-Sleep -Milliseconds 300
                        Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                        if (Test-Cancelled) { Log "Cancelled during the cut"; Remove-DownloadTemp $tempDir $null $null; [Environment]::Exit(0) }
                        Log "Cut timed out ($enc)"
                        break
                    }
                    if ($pc.ExitCode -eq 0 -and (Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -ge 1024) {
                        $finalPaths[$i] = $target
                        $done = $true
                        break
                    }
                    Log "Cut with '$enc' failed (exit $($pc.ExitCode)); trying the next encoder"
                    Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                }
            }
            if (-not $done) {
                $cutFailed++
                $keep = Join-Path $downloadDir ([IO.Path]::GetFileName($src))
                for ($k = 2; (Test-Path -LiteralPath $keep) -and $k -lt 100; $k++) { $keep = Join-Path $downloadDir ($stem + " ($k)" + $ext) }
                try { Move-Item -LiteralPath $src -Destination $keep -Force -ErrorAction Stop; $finalPaths[$i] = $keep } catch { Log "Could not keep the full video: $_" }
            }
        }
        Remove-DownloadTemp $tempDir $null $null
        if ($cutFailed -gt 0) { $doneMsg = "Downloaded, but the cut failed — full video kept." }
        elseif ($finalPaths.Count -eq 1 -and $length -gt 0) { $script:mediaDuration = $length }
    }

    #---------------------- GIF conversion (own ffmpeg, real progress, cancelable) ----------------------
    if ($isGif) {
        $finalPath = [string]$finalPaths[0]
        if (-not (Test-Path -LiteralPath $ffmpegPath)) {
            Log "ffmpeg missing; cannot make GIF, keeping video"
            $doneMsg = "Video downloaded (GIF conversion impossible: ffmpeg missing)."
        } else {
            if ($script:globalPct -lt 94) { $script:globalPct = 94 }
            Send-Progress 'postprocess' 'Converting to GIF…' $script:globalPct
            $gifOk = $false
            $palette = Join-Path $logsDirectory ("palette_" + $uniq + ".png")
            try {
                $vf = 'fps=15,scale=min(640\,iw):-2:flags=lanczos'
                $skipGif = $false
                # PS 5.1's Start-Process joins -ArgumentList with spaces WITHOUT quoting:
                # every path argument must be pre-quoted.
                $p1 = Start-Process -FilePath $ffmpegPath -ArgumentList (@('-y','-nostdin','-hide_banner','-loglevel','error','-i',$finalPath,'-an','-vf',"$vf,palettegen",$palette) | ForEach-Object { Quote-Arg $_ }) -WindowStyle Hidden -PassThru
                $null = $p1.Handle
                if (-not (Wait-ProcCancelable $p1 -TimeoutSec 1800)) {
                    Remove-Item -LiteralPath $palette -Force -ErrorAction SilentlyContinue
                    if (Test-Cancelled) {
                        Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue   # drop the intermediate video (user asked for a GIF, then cancelled)
                        Remove-DownloadTemp $tempDir $null $null
                        [Environment]::Exit(0)
                    }
                    Log "GIF palettegen timed out -> keeping the downloaded video"
                    $skipGif = $true
                }
                if (-not $skipGif) {
                    $script:ppDuration = if ($script:mediaDuration) { [double]$script:mediaDuration } else { 0.0 }
                    $script:ppFrom = 94; $script:ppTo = 99; $script:ppLabel = 'Converting to GIF…'
                    $gifPath = [System.IO.Path]::ChangeExtension($finalPath, '.gif')
                    $p2 = Start-Process -FilePath $ffmpegPath -ArgumentList (@('-y','-nostdin','-hide_banner','-loglevel','error','-progress',$ffprog,'-i',$finalPath,'-i',$palette,'-an','-lavfi',"$vf[x];[x][1:v]paletteuse",$gifPath) | ForEach-Object { Quote-Arg $_ }) -WindowStyle Hidden -PassThru
                    $null = $p2.Handle
                    $ok2 = Wait-ProcCancelable $p2 $ppPoll -TimeoutSec 1800
                    Remove-Item -LiteralPath $palette -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $ffprog  -Force -ErrorAction SilentlyContinue
                    if (-not $ok2) {
                        Remove-Item -LiteralPath $gifPath -Force -ErrorAction SilentlyContinue
                        if (Test-Cancelled) {
                            Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue   # drop the intermediate video on GIF cancel
                            Remove-DownloadTemp $tempDir $null $null
                            [Environment]::Exit(0)
                        }
                        Log "GIF encode timed out -> keeping the downloaded video"
                    } elseif (($p2.ExitCode -eq 0) -and (Test-Path -LiteralPath $gifPath) -and ((Get-Item -LiteralPath $gifPath).Length -ge 1024)) {
                        Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue
                        $finalPaths[0] = $gifPath
                        $gifOk = $true
                    }
                }
            } catch { Log "GIF conversion error: $_" }
            if (-not $gifOk) { $doneMsg = "Video downloaded (GIF conversion failed — video kept)." }
        }
    }

    #---------------------- MP4 (H.264 + AAC) conversion ----------------------
    # Nothing to do when the file already is H.264/AAC in MP4, a remux when only the
    # container differs, a re-encode with the best working encoder otherwise.
    if ($convertMp4 -and (Test-Path -LiteralPath $ffmpegPath)) {
        $convertFailed = 0
        for ($i = 0; $i -lt $finalPaths.Count; $i++) {
            $src = [string]$finalPaths[$i]
            $info = Get-MediaInfo $src
            $ext = [IO.Path]::GetExtension($src).ToLowerInvariant()
            $videoOk = ($null -eq $info.Video) -or ($info.Video -eq 'h264')
            $audioOk = ($null -eq $info.Audio) -or ($info.Audio -eq 'aac')
            if ($videoOk -and $audioOk -and $ext -eq '.mp4') { continue }
            $dir = Split-Path -LiteralPath $src
            $stem = [IO.Path]::GetFileNameWithoutExtension($src)
            $target = Join-Path $dir ($stem + '.mp4')
            if ($target -ne $src -and (Test-Path -LiteralPath $target)) { $target = Join-Path $dir ($stem + ' (mp4).mp4') }
            $work = Join-Path $dir ($stem + '.vdrpb-convert.mp4')
            $script:ppDuration = if ($info.Duration -gt 0) { $info.Duration } elseif ($script:mediaDuration) { [double]$script:mediaDuration } else { 0.0 }
            $span = [math]::Max(1, [int](8 / $finalPaths.Count))
            $script:ppFrom = [math]::Min(98, 90 + $i * $span); $script:ppTo = [math]::Min(99, $script:ppFrom + $span)
            $script:ppLabel = if ($videoOk) { 'Converting to MP4…' } else { 'Converting to MP4 (H.264)…' }
            if ($script:globalPct -lt $script:ppFrom) { $script:globalPct = $script:ppFrom }
            Send-Progress 'postprocess' $script:ppLabel $script:globalPct
            $encoders = if ($videoOk) { @('copy') } else { @(Get-H264Encoders) }
            $converted = $false
            foreach ($enc in $encoders) {
                $a = @('-y', '-nostdin', '-hide_banner', '-loglevel', 'error', '-progress', $ffprog, '-i', $src, '-map', '0:v:0?', '-map', '0:a:0?')
                if ($enc -eq 'copy') { $a += @('-c:v', 'copy') } else { $a += @('-c:v') + @($enc -split ' ') + @('-pix_fmt', 'yuv420p') }
                if ($audioOk) { $a += @('-c:a', 'copy') } else { $a += @('-c:a', 'aac', '-b:a', '160k') }
                $a += @('-movflags', '+faststart', $work)
                Log "ffmpeg convert: $enc -> $work"
                $pc = Start-Process -FilePath $ffmpegPath -ArgumentList ($a | ForEach-Object { Quote-Arg $_ }) -WindowStyle Hidden -PassThru
                $null = $pc.Handle
                $okc = Wait-ProcCancelable $pc $ppPoll -TimeoutSec 7200
                Remove-Item -LiteralPath $ffprog -Force -ErrorAction SilentlyContinue
                if (-not $okc) {
                    Start-Sleep -Milliseconds 300
                    Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
                    if (Test-Cancelled) { Log "Cancelled during MP4 conversion"; [Environment]::Exit(0) }
                    Log "MP4 conversion timed out ($enc)"
                    break
                }
                if ($pc.ExitCode -eq 0 -and (Test-Path -LiteralPath $work) -and (Get-Item -LiteralPath $work).Length -ge 1024) {
                    try {
                        Remove-Item -LiteralPath $src -Force -ErrorAction Stop
                        Move-Item -LiteralPath $work -Destination $target -Force -ErrorAction Stop
                        $finalPaths[$i] = $target
                        $converted = $true
                    } catch { Log "MP4 replace failed: $_" }
                    break
                }
                Log "Encoder '$enc' failed (exit $($pc.ExitCode)); trying the next one"
                Remove-Item -LiteralPath $work -Force -ErrorAction SilentlyContinue
            }
            if (-not $converted) { $convertFailed++ }
        }
        if ($convertFailed -gt 0) { $doneMsg = "Downloaded, but the MP4 conversion failed — original kept." }
    }

    Send-Progress 'finalize' 'Finalizing…' 100

    $paths = [string[]]@($finalPaths)
    if (AsBool $inputData.copyAtEnd) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $sc = New-Object System.Collections.Specialized.StringCollection
            foreach ($pth in $paths) { [void]$sc.Add($pth) }
            [System.Windows.Forms.Clipboard]::SetFileDropList($sc)
        } catch { Log "Failed to copy file at end: $_" }
    }

    $totalSize = [int64]0
    foreach ($pth in $paths) { try { $totalSize += (Get-Item -LiteralPath $pth).Length } catch { } }
    Send-Done $true $doneMsg $paths[0] @{ finalPaths = $paths; size = $totalSize; logPath = $ytLog }

    if (AsBool $inputData.bipAtEnd) {
        try { (New-Object Media.SoundPlayer "C:\Windows\Media\notify.wav").PlaySync() } catch { }
    }
    [Environment]::Exit(0)
}


#==========================================================================
# SHOW (reveal file in Explorer, or open a folder)
#==========================================================================
elseif ($mode -eq 'show') {
    try {
        if ($fileToShow -eq '::downloads') { $fileToShow = Join-Path $env:USERPROFILE 'Downloads' }
        if (-not (Test-Path -LiteralPath $fileToShow)) {
            Send-Legacy $false "File not found: $fileToShow"
            return
        }
        if (Test-Path -LiteralPath $fileToShow -PathType Container) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList (Quote-Arg $fileToShow)
            Send-Legacy $true "Folder opened: $fileToShow"
            exit
        }
        Add-Type @"
            using System;
            using System.Runtime.InteropServices;
            public class User32 {
                [DllImport("user32.dll")]
                [return: MarshalAs(UnmanagedType.Bool)]
                public static extern bool SetForegroundWindow(IntPtr hWnd);
                [DllImport("user32.dll")]
                [return: MarshalAs(UnmanagedType.Bool)]
                public static extern bool IsIconic(IntPtr hWnd);
                [DllImport("user32.dll")]
                [return: MarshalAs(UnmanagedType.Bool)]
                public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
                public const int SW_RESTORE = 9;
            }
"@ -ErrorAction SilentlyContinue

        $selectFallback = {
            param($path)
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $path)
        }

        $parent = Split-Path -LiteralPath $fileToShow          # default op = parent; NB: '-LiteralPath -Parent' together throws AmbiguousParameterSet in PS 5.1
        $normalizedTargetFolderPath = $null
        if ($parent -and (Test-Path -LiteralPath $parent)) { $normalizedTargetFolderPath = (Resolve-Path -LiteralPath $parent).Path }
        if (-not $normalizedTargetFolderPath) {
            $errormessage = "Could not determine the parent folder: '$fileToShow'"
            Log $errormessage
            Send-Legacy $false $errormessage
            return
        }
        $foundWindowHwnd = $foundWindowObject = $shell = $windows = $null
        try {
            $shell = New-Object -ComObject Shell.Application
            $windows = $shell.Windows()
            foreach ($window in $windows) {
                $currentWindowComObject = $window ; $releaseCurrentWindow = $true
                try {
                    if (($window.FullName -like "*explorer.exe*") -and ($null -ne $window.Document) -and ($null -ne $window.Document.Folder)) {
                        try {
                            if ((Resolve-Path -LiteralPath $window.Document.Folder.Self.Path -ErrorAction Stop).Path -eq $normalizedTargetFolderPath) {
                                $foundWindowHwnd = $window.HWND
                                $foundWindowObject = $currentWindowComObject
                                $releaseCurrentWindow = $false
                                break
                            }
                        }
                        catch { Log "ERROR resolving path for HWND $($window.HWND): $($_.Exception.Message)" }
                    }
                }
                catch { Log "ERROR accessing properties for HWND $($window.HWND): $($_.Exception.Message)" }
                finally {
                    if ($releaseCurrentWindow -and $null -ne $currentWindowComObject -and [System.Runtime.InteropServices.Marshal]::IsComObject($currentWindowComObject)) {
                        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($currentWindowComObject) | Out-Null
                    }
                }
            }
        }
        catch { Log "ERROR during Shell/Windows object access: $($_.Exception.Message)" }
        finally {
             if ($null -ne $windows -and [System.Runtime.InteropServices.Marshal]::IsComObject($windows)) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($windows) | Out-Null }
             if ($null -ne $shell -and [System.Runtime.InteropServices.Marshal]::IsComObject($shell)) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null }
        }
        if ($null -ne $foundWindowHwnd -and $null -ne $foundWindowObject) {
            try {
                if ([User32]::IsIconic($foundWindowHwnd)) {
                    [User32]::ShowWindow($foundWindowHwnd, [User32]::SW_RESTORE) | Out-Null
                    Start-Sleep -Milliseconds 100
                }
                [User32]::SetForegroundWindow($foundWindowHwnd) | Out-Null
                Start-Sleep -Milliseconds 80
                try {
                    $foundWindowObject.Document.SelectItem($fileToShow, 0x1D)
                    Send-Legacy $true "File revealed: $fileToShow"
                }
                catch {
                    Log "COM SelectItem failed: $($_.Exception.Message). Falling back to explorer /select."
                    & $selectFallback $fileToShow
                    Send-Legacy $true "File revealed (explorer): $fileToShow"
                }
            }
            catch {
                Log "ERROR during activation/select: $($_.Exception.Message). Falling back."
                & $selectFallback $fileToShow
                Send-Legacy $true "File revealed (explorer): $fileToShow"
            }
            finally {
                if ($null -ne $foundWindowObject -and [System.Runtime.InteropServices.Marshal]::IsComObject($foundWindowObject)) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($foundWindowObject) | Out-Null }
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
            }
        }
        else {
            Log "No matching window found. Using default explorer.exe /select."
            & $selectFallback $fileToShow
            Send-Legacy $true "File revealed: $fileToShow"
        }
    }
    catch {
        Log "FATAL Error showing file: $_"
        Send-Legacy $false "Error revealing the file: $_"
    }
    exit
}


#==========================================================================
# COPY (put file on clipboard)
#==========================================================================
elseif ($mode -eq 'copy') {
    try {
        if (-not (Test-Path -LiteralPath $fileToCopy)) {
            Send-Legacy $false "File not found: $fileToCopy"
            exit
        }
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $sc = New-Object System.Collections.Specialized.StringCollection
        $sc.Add($fileToCopy) | Out-Null
        [System.Windows.Forms.Clipboard]::SetFileDropList($sc)
        Log "File copied to clipboard: $fileToCopy"
        Send-Legacy $true "File copied."
    }
    catch {
        Log "Error copying file: $_"
        Send-Legacy $false "Error copying the file: $_"
    }
    exit
}


#==========================================================================
# SERVE (long-lived: local HTTP server for dragging a file out of the browser)
#==========================================================================
# Serves ONE media file at http://127.0.0.1:<ephemeral port>/<token> until the
# extension closes the port or nothing is requested for 15 minutes.
elseif ($mode -eq 'serve') {
    $token = [string]$inputData.token
    $serveExt = [IO.Path]::GetExtension($fileToServe).ToLowerInvariant()
    if ($token -notmatch '^[0-9a-f]{32}$' -or -not (Test-Path -LiteralPath $fileToServe -PathType Leaf) -or ($MediaExtensions -notcontains $serveExt)) {
        Log "SERVE refused: $fileToServe"
        Send-NativeMessage @{ type = 'serve'; success = $false; message = 'File not available.' }
        [Environment]::Exit(0)
    }
    $mimeTypes = @{ '.mp4' = 'video/mp4'; '.webm' = 'video/webm'; '.mkv' = 'video/x-matroska'; '.mov' = 'video/quicktime'; '.mp3' = 'audio/mpeg'; '.m4a' = 'audio/mp4'; '.aac' = 'audio/aac'; '.opus' = 'audio/ogg'; '.ogg' = 'audio/ogg'; '.wav' = 'audio/wav'; '.gif' = 'image/gif'; '.webp' = 'image/webp'; '.flv' = 'video/x-flv'; '.3gp' = 'video/3gpp' }
    $mime = if ($mimeTypes.ContainsKey($serveExt)) { $mimeTypes[$serveExt] } else { 'application/octet-stream' }
    $fileName = [IO.Path]::GetFileName($fileToServe)
    $asciiName = ($fileName -replace '[^\x20-\x7E]', '_') -replace '["\\]', '_'
    $disposition = "attachment; filename=`"$asciiName`"; filename*=UTF-8''" + [Uri]::EscapeDataString($fileName)
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    try { $listener.Start() } catch {
        Log "SERVE listen failed: $_"
        Send-NativeMessage @{ type = 'serve'; success = $false; message = 'Could not open a local port.' }
        [Environment]::Exit(0)
    }
    $port = $listener.LocalEndpoint.Port
    Send-NativeMessage @{ type = 'serve'; success = $true; port = $port }
    Log "SERVE listening on 127.0.0.1:$port for $fileToServe"
    $script:cancelFlag = Start-PortWatcher
    $idle = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not (Test-Cancelled) -and $idle.Elapsed.TotalMinutes -lt 15) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $client.ReceiveTimeout = 5000
                $client.SendTimeout = 60000
                $ns = $client.GetStream()
                $reader = New-Object System.IO.StreamReader($ns, [Text.Encoding]::ASCII, $false, 8192, $true)
                $requestLine = $reader.ReadLine()
                for ($h = 0; $h -lt 100; $h++) { $hl = $reader.ReadLine(); if ([string]::IsNullOrEmpty($hl)) { break } }
                $isHead = $requestLine -match '^HEAD '
                if ($requestLine -match '^(GET|HEAD)\s+/([0-9a-f]{32})(?:[?#]\S*)?\s+HTTP/1\.[01]$' -and $Matches[2] -eq $token -and (Test-Path -LiteralPath $fileToServe -PathType Leaf)) {
                    $fs = [IO.File]::Open($fileToServe, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                    try {
                        $head = "HTTP/1.1 200 OK`r`nContent-Type: $mime`r`nContent-Length: $($fs.Length)`r`nContent-Disposition: $disposition`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
                        $hb = [Text.Encoding]::UTF8.GetBytes($head)
                        $ns.Write($hb, 0, $hb.Length)
                        if (-not $isHead) {
                            $buf = New-Object byte[] 65536
                            while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                                $ns.Write($buf, 0, $n)
                                if (Test-Cancelled) { break }
                            }
                        }
                        $ns.Flush()
                        Log "SERVE sent $($fs.Length) bytes"
                    } finally { $fs.Dispose() }
                } else {
                    $nb = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $ns.Write($nb, 0, $nb.Length)
                }
            } catch { Log "SERVE request error: $($_.Exception.Message)" }
            finally { try { $client.Close() } catch { } }
            $idle.Restart()
        }
    } finally {
        try { $listener.Stop() } catch { }
        Log "SERVE stopped"
    }
    [Environment]::Exit(0)
}


#==========================================================================
# OPENLOG (open a download log from the Logs folder)
#==========================================================================
elseif ($mode -eq 'openlog') {
    try {
        $full = [IO.Path]::GetFullPath($logToOpen)
        $logsFull = [IO.Path]::GetFullPath($logsDirectory).TrimEnd('\') + '\'
        if (-not $full.StartsWith($logsFull, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            Send-Legacy $false "Log not found."
            exit
        }
        Start-Process -FilePath 'notepad.exe' -ArgumentList (Quote-Arg $full)
        Send-Legacy $true "Log opened."
    } catch {
        Log "openlog failed: $_"
        Send-Legacy $false "Could not open the log: $($_.Exception.Message)"
    }
    exit
}


#==========================================================================
# STAT (which of these files still exist)
#==========================================================================
elseif ($mode -eq 'stat') {
    try {
        $list = @($inputData.STAT) | Select-Object -First 100
        $exists = @($list | ForEach-Object { $s = [string]$_; [bool]($s -and (Test-Path -LiteralPath $s -PathType Leaf)) })
        Send-NativeMessage @{ success = $true; exists = [bool[]]$exists }
    } catch {
        Log "stat failed: $_"
        Send-NativeMessage @{ success = $false; message = "stat failed" }
    }
    exit
}


#==========================================================================
# PICKFOLDER (one-shot: Windows folder dialog for the download folder)
#==========================================================================
elseif ($mode -eq 'pickfolder') {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class VdrpbFolderPicker {
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] class FileOpenDialogRCW { }
    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileDialog {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, int fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr pFilter);
    }
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string pszPath, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, out IShellItem ppv);

    public static string Pick(string initial, string title, IntPtr owner) {
        IFileDialog dlg = (IFileDialog)new FileOpenDialogRCW();
        uint opts;
        dlg.GetOptions(out opts);
        dlg.SetOptions(opts | 0x20 | 0x40 | 0x800);   // PICKFOLDERS | FORCEFILESYSTEM | PATHMUSTEXIST
        dlg.SetTitle(title);
        if (!String.IsNullOrEmpty(initial)) {
            try { IShellItem folder; SHCreateItemFromParsingName(initial, IntPtr.Zero, typeof(IShellItem).GUID, out folder); dlg.SetFolder(folder); } catch { }
        }
        if (dlg.Show(owner) != 0) return null;
        IShellItem item;
        dlg.GetResult(out item);
        string path;
        item.GetDisplayName(0x80058000, out path);   // SIGDN_FILESYSPATH
        return path;
    }
}
"@ -ErrorAction Stop
        $initial = [string]$inputData.initial
        if (-not $initial -or -not (Test-Path -LiteralPath $initial -PathType Container)) { $initial = Join-Path $env:USERPROFILE 'Downloads' }
        # Invisible topmost owner so the dialog opens in front of the browser.
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true; $owner.ShowInTaskbar = $false; $owner.FormBorderStyle = 'None'
        $owner.Opacity = 0; $owner.StartPosition = 'CenterScreen'; $owner.Width = 1; $owner.Height = 1
        $owner.Show(); $owner.Activate()
        $picked = $null
        try { $picked = [VdrpbFolderPicker]::Pick($initial, 'Download folder', $owner.Handle) } finally { $owner.Close(); $owner.Dispose() }
        if ($picked) { Log "Folder picked: $picked"; Send-NativeMessage @{ success = $true; path = $picked } }
        else { Send-NativeMessage @{ success = $false; cancelled = $true } }
    } catch {
        Log "pickfolder failed: $_"
        Send-NativeMessage @{ success = $false; message = "Could not open the folder dialog." }
    }
    [Environment]::Exit(0)
}


#==========================================================================
# CHECKUPDATE  (one-shot: does a newer GitHub release tag exist?)
#==========================================================================
elseif ($mode -eq 'checkupdate') {
    try {
        $st = Get-UpdateStatus
        Send-NativeMessage @{ success = $true; updateAvailable = [bool]$st.available; latest = [string]$st.latest; current = [string]$st.current }
    } catch {
        Log "checkupdate failed: $_"
        Send-NativeMessage @{ success = $true; updateAvailable = $false }
    }
    # The answer is sent first; yt-dlp/deno/ffmpeg are then updated by a detached
    # process (at most every 4 h), so no download ever waits for it.
    try {
        if (Test-UpdateDue 4) {
            Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Arg $localPath), '-SelfUpdate')
            Log "Detached tool update started"
        }
    } catch { Log "Could not start the tool update: $_" }
    [Environment]::Exit(0)
}


#==========================================================================
# DOUPDATE  (one-shot: download the latest setup.bat and run it -silent)
#==========================================================================
elseif ($mode -eq 'doupdate') {
    try {
        # The update reloads the extension or restarts the browser: never while a download is running.
        $busy = @()
        try {
            $busy = @(Get-CimInstance Win32_Process -Filter "Name='yt-dlp.exe' OR Name='ffmpeg.exe'" -ErrorAction Stop |
                Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($basePath, [StringComparison]::OrdinalIgnoreCase) -and ([string]$_.CommandLine) -notmatch '--update-to' })
        } catch { }
        if ($busy.Count -gt 0) {
            Send-Legacy $false "Downloads are still running. Finish or cancel them, then update."
            [Environment]::Exit(0)
        }
        # Without elevation when the existing install allows it: the extension then asks
        # the browser to update itself from the local server (no UAC, no browser restart).
        if ([string]$inputData.method -ne 'setup') {
            $inPlace = Invoke-InPlaceUpdate
            if ($inPlace.Ok) {
                Log "In-place update prepared: $($inPlace.Version)"
                Send-NativeMessage @{ success = $true; mode = 'inplace'; version = $inPlace.Version; message = 'Update ready' }
                [Environment]::Exit(0)
            }
            Log "In-place update not possible: $($inPlace.Reason) -> installer"
        }
        $stage = Join-Path $env:TEMP 'vdrpb_update'
        if (-not (Test-Path -LiteralPath $stage)) { New-Item -ItemType Directory -Path $stage -Force | Out-Null }
        $setupDest = Join-Path $stage 'setup.bat'
        Invoke-WebRequest -Uri $SetupDlUrl -OutFile $setupDest -UseBasicParsing -TimeoutSec 40 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
        if ((-not (Test-Path -LiteralPath $setupDest)) -or ((Get-Item -LiteralPath $setupDest).Length -lt 500)) {
            Send-Legacy $false "Installer download failed."
            [Environment]::Exit(0)
        }
        $head = ''
        try { $head = (Get-Content -LiteralPath $setupDest -TotalCount 12 -ErrorAction SilentlyContinue) -join "`n" } catch { }
        if ($head -notmatch 'powershell') {
            Send-Legacy $false "Unexpected installer file — update cancelled."
            [Environment]::Exit(0)
        }
        # Launch the fresh installer unattended (-silent). It elevates (one UAC prompt),
        # reinstalls and restarts the browser. Detached, so it survives this host / the
        # browser closing.
        Start-Process -FilePath $setupDest -ArgumentList '-silent' -WorkingDirectory $stage -WindowStyle Hidden
        Log "Update: launched setup.bat -silent from $stage"
        Send-NativeMessage @{ success = $true; mode = 'setup'; message = 'Update launched' }
    } catch {
        Log "doupdate failed: $_"
        Send-Legacy $false ("Failed to launch the update: " + $_.Exception.Message)
    }
    [Environment]::Exit(0)
}
