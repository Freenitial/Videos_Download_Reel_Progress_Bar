#--------------------------
# Utility Functions
#--------------------------
$script:portDead = $false

function Remove-OldFiles {
    param ([string]$Path, [string]$Pattern, [int]$MaxCount = 15)
    try {
        $files = Get-ChildItem -LiteralPath $Path -Filter $Pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
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

function Send-Done {
    param ([bool]$Success, [string]$Message = $null, [string]$FinalPath = $null)
    $m = @{ type = 'done'; success = $Success }
    if ($Message)   { $m.message   = $Message }
    if ($FinalPath) { $m.finalPath = $FinalPath }
    Send-NativeMessage $m
}

# One-shot response for SHOW / COPY (sendNativeMessage, single message expected).
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

function Test-SafeCut {
    param ([string]$c)
    return ($c -match '^\*(\d+(:\d+){0,2})?-(\d+(:\d+){0,2})?$')
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

# Map frequent yt-dlp errors to a human-friendly message + hint. Raw kept as fallback.
function Translate-YtDlpError {
    param ([string]$raw)
    if ([string]::IsNullOrWhiteSpace($raw)) { return "The download failed. Try again in a moment." }
    $map = @(
        @('is private|login required|Sign in to|requires authentication|Private video',       'Private video or restricted to logged-in accounts — cannot be downloaded without signing in.'),
        @('Video unavailable|has been removed|no longer available|Content isn|This video is not available', 'Video unavailable or removed.'),
        @('confirm your age|age-restricted|inappropriate for some',                             'Age-restricted video.'),
        @('not available in your country|geo.?restricted|blocked it in your country',           'Video blocked in your country.'),
        @('Requested format is not available|No video formats|Requested format',               'Requested format unavailable for this video.'),
        @('HTTP Error 403|Forbidden|403:',                                                      'Access denied by the server (403) — try again in a few minutes.'),
        @('HTTP Error 404|Not Found|404:',                                                      'Video not found (404).'),
        @('Unable to download|Unable to connect|getaddrinfo|Temporary failure|timed out|Connection refused|Network is unreachable|Read timed out', 'Network connection problem — check your connection and try again.'),
        @('This live event|is live|will begin in|Premieres in',                                 'Live or upcoming broadcast — not downloadable yet.'),
        @('Unsupported URL|Unable to extract|no suitable extractor',                            'Link not supported for download.')
    )
    foreach ($e in $map) { if ($raw -match $e[0]) { return $e[1] } }
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

# Each run gets a PRIVATE yt-dlp temp dir (--paths temp:), so cleanup can wipe
# it wholesale without ever touching a concurrent download's partials/state
# (content.js runs up to 3 downloads into the same Downloads folder).
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


#--------------------------
# Initialization
#--------------------------
$localPath     = $MyInvocation.MyCommand.Path
$currentDate   = Get-Date -Format "ddMMyyyy"
$basePath      = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ytDlpPathEXE  = Join-Path $basePath "yt-dlp.exe"
$ffmpegPath    = Join-Path $basePath "ffmpeg.exe"
$denoPath      = Join-Path $basePath "deno.exe"
$versionFile     = Join-Path $basePath "version.txt"        # written by setup.bat = installed CRX version
$updateStateFile = Join-Path $basePath "update_state.txt"   # cached online-version verdict (throttled)
$RepoOwnerRepo   = 'Freenitial/Videos_Download_Reel_Progress_Bar'
$RepoApiLatest   = "https://api.github.com/repos/$RepoOwnerRepo/releases/latest"
$SetupDlUrl      = "https://github.com/$RepoOwnerRepo/releases/latest/download/setup.bat"
$FfmpegZipUrl    = 'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-lgpl.zip'

$logsDirectory = Join-Path $basePath "Logs"
if (-Not (Test-Path -LiteralPath $logsDirectory)) { New-Item -ItemType Directory -Path $logsDirectory | Out-Null }
$scriptLogFile = Join-Path $logsDirectory "script-ps1_$currentDate.log"
if (Test-Path -LiteralPath $scriptLogFile) { Add-Content -LiteralPath $scriptLogFile -Value "`r`n--------`r`n" -Encoding UTF8 }

Remove-OldFiles -Path $logsDirectory -Pattern 'script-ps1_*.log' -MaxCount 15
Remove-OldFiles -Path $logsDirectory -Pattern 'ytdlp_*.log'     -MaxCount 6
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
function ConvertTo-VersionSafe {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $t = $s.Trim().TrimStart('vV')
    $m = [regex]::Match($t, '^\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $v = $m.Value
    if ($v -notmatch '\.') { $v = $v + '.0' }   # [version] needs at least major.minor ("v2" -> "2.0")
    try { return [version]$v } catch { return $null }
}
function Get-InstalledVersion {
    try { if (Test-Path -LiteralPath $versionFile) { return (ConvertTo-VersionSafe ([IO.File]::ReadAllText($versionFile))) } } catch { }
    return $null
}
function Get-UpdateStatus {
    param([switch]$ForceRefresh)
    $cur = Get-InstalledVersion
    $cache = $null
    try { if (Test-Path -LiteralPath $updateStateFile) { $cache = ([IO.File]::ReadAllText($updateStateFile) | ConvertFrom-Json) } } catch { $cache = $null }
    if (-not $ForceRefresh -and $cache -and $cache.checkedAt) {
        try {
            $age = ((Get-Date) - [datetime]::Parse([string]$cache.checkedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).TotalHours
            if ($age -lt 4) { return @{ available = [bool]$cache.available; latest = [string]$cache.latest; current = [string]$cache.current } }
        } catch { }
    }
    $latest = $null
    try {
        $rel = Invoke-RestMethod -Uri $RepoApiLatest -TimeoutSec 15 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
        if ($rel -and $rel.tag_name) { $latest = ConvertTo-VersionSafe ([string]$rel.tag_name) }
    } catch {
        if ($cache) { return @{ available = [bool]$cache.available; latest = [string]$cache.latest; current = [string]$cache.current } }
        $curStr0 = if ($null -ne $cur) { $cur.ToString() } else { $null }
        return @{ available = $false; latest = $null; current = $curStr0 }
    }
    $available = ($null -ne $latest -and $null -ne $cur -and $latest -gt $cur)
    $latestStr = if ($null -ne $latest) { $latest.ToString() } else { $null }
    $curStr    = if ($null -ne $cur)    { $cur.ToString() }    else { $null }
    try {
        $obj = [ordered]@{ checkedAt = (Get-Date).ToString('o'); available = [bool]$available; latest = $latestStr; current = $curStr }
        [IO.File]::WriteAllText($updateStateFile, ($obj | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    return @{ available = [bool]$available; latest = $latestStr; current = $curStr }
}
function Update-FfmpegIfMissing {
    # ffmpeg has no version API; only ensure it is PRESENT (repair a deleted/corrupt copy).
    if ((Test-Path -LiteralPath $ffmpegPath) -and (Test-Path -LiteralPath (Join-Path $basePath 'ffprobe.exe'))) { return }
    try {
        $zip = Join-Path $basePath 'ffmpeg_repair.zip'
        Invoke-WebRequest -Uri $FfmpegZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $za = [IO.Compression.ZipFile]::OpenRead($zip)
        try { foreach ($e in $za.Entries) { if (@('ffmpeg.exe','ffprobe.exe','ffplay.exe') -contains $e.Name) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $basePath $e.Name), $true) } } } finally { $za.Dispose() }
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Log "ffmpeg repaired (was missing)"
    } catch { Log ("ffmpeg repair failed: {0}" -f $_.Exception.Message) }
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

    Send-Progress 'prepare' 'Preparing download…'

    # Watch the port from the very start so updates are cancelable too.
    $script:cancelFlag = Start-PortWatcher

    #---------------------- Updates (bounded, throttled >= 4h, mutex-guarded) ----------------------
    $lastUpdateFile = Join-Path $basePath "lastupdate.txt"
    $needUpdate = $true
    if (Test-Path -LiteralPath $lastUpdateFile) {
        if (((Get-Date) - (Get-Item -LiteralPath $lastUpdateFile).LastWriteTime).TotalHours -lt 4) { $needUpdate = $false }
    }
    if ($needUpdate) {
        $mutex = New-Object System.Threading.Mutex($false, 'Local\vdrpb_update_mutex')
        $acquired = $false
        try { $acquired = $mutex.WaitOne(0) } catch { $acquired = $false }
        if ($acquired) {
            try {
                $stillNeed = $true
                if (Test-Path -LiteralPath $lastUpdateFile) {
                    if (((Get-Date) - (Get-Item -LiteralPath $lastUpdateFile).LastWriteTime).TotalHours -lt 4) { $stillNeed = $false }
                }
                if ($stillNeed) {
                    Send-Progress 'update' 'Updating yt-dlp…'
                    try {
                        $up = Start-Process -FilePath $ytDlpPathEXE -ArgumentList @("--update-to", "stable") -WindowStyle Hidden -PassThru
                        if (-not $up.WaitForExit(30000)) { try { Stop-ProcessTree $up.Id } catch { }; Log "yt-dlp update timed out" }
                        else { Log ("yt-dlp update ExitCode: {0}" -f $up.ExitCode) }
                    } catch { Log ("yt-dlp update failed: {0}" -f $_) }

                    if ($script:cancelFlag.stop -or $script:portDead) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose(); Log "Cancelled during update"; [Environment]::Exit(0) }
                    Send-Progress 'update' 'Updating JavaScript engine (deno)…'
                    try {
                        if (Test-Path -LiteralPath $denoPath) {
                            $dn = Start-Process -FilePath $denoPath -ArgumentList @("upgrade", "--quiet") -WindowStyle Hidden -PassThru
                            if (-not $dn.WaitForExit(30000)) { try { Stop-ProcessTree $dn.Id } catch { } }
                        } else {
                            Log "deno.exe missing; downloading standalone runtime"
                            $denoZip = Join-Path $basePath "deno_download.zip"
                            $denoUrl = "https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip"
                            Invoke-WebRequest -Uri $denoUrl -OutFile $denoZip -UseBasicParsing -TimeoutSec 60 -Headers @{ "User-Agent" = "Mozilla/5.0" }
                            Add-Type -AssemblyName System.IO.Compression.FileSystem
                            $za = [System.IO.Compression.ZipFile]::OpenRead($denoZip)
                            try { foreach ($e in $za.Entries) { if ($e.Name -eq 'deno.exe') { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $denoPath, $true) } } } finally { $za.Dispose() }
                            Remove-Item -LiteralPath $denoZip -Force -ErrorAction SilentlyContinue
                        }
                    } catch { Log ("deno update failed: {0}" -f $_) }

                    if ($script:cancelFlag.stop -or $script:portDead) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose(); Log "Cancelled during update"; [Environment]::Exit(0) }
                    Send-Progress 'update' 'Checking ffmpeg…'
                    # yt-dlp & deno self-update above. ffmpeg has no updater -> just ensure it's present.
                    # The module itself (.ps1 + CRX) updates via the TAG-based flow only
                    # (content.js shows an "update" button -> CHECKUPDATE/DOUPDATE -> setup.bat re-run).
                    Update-FfmpegIfMissing

                    try { Set-Content -LiteralPath $lastUpdateFile -Value (Get-Date).ToString('o') -Encoding UTF8 } catch { }
                }
            } finally {
                try { $mutex.ReleaseMutex() } catch { }
                $mutex.Dispose()
            }
        } else {
            # Another host is updating yt-dlp/deno/ffmpeg RIGHT NOW: wait (bounded,
            # cancel-aware) until the binaries are quiescent before launching them.
            # Exit early when lastupdate.txt gets stamped (the updater writes it only
            # after ALL swaps). Hard cap 300s > the updater's worst case (~210s:
            # 30s yt-dlp + 90s deno + 120s+extract ffmpeg).
            $got = $false
            $waitStart = Get-Date
            while (-not $got -and (((Get-Date) - $waitStart).TotalSeconds -lt 300)) {
                if ($script:cancelFlag.stop -or $script:portDead) { break }
                try { $got = $mutex.WaitOne(2000) } catch { $got = $true }   # AbandonedMutex = we own it now
                if (-not $got) {
                    try { if ((Test-Path -LiteralPath $lastUpdateFile) -and ((Get-Item -LiteralPath $lastUpdateFile).LastWriteTime -gt $waitStart)) { break } } catch { }
                }
            }
            if ($got) { try { $mutex.ReleaseMutex() } catch { } }
            $mutex.Dispose()
        }
    }

    # Cancelled during the update phase?
    if ($script:cancelFlag.stop -or $script:portDead) { Log "Cancelled during update"; [Environment]::Exit(0) }

    #---------------------- Destination ----------------------
    if ($inputData.downloadDir) {
        $downloadDir = [string]$inputData.downloadDir
        if (-Not (Test-Path -LiteralPath $downloadDir)) {
            Log "Download path '$downloadDir' is invalid."
            Send-Done $false "Invalid download folder: $downloadDir"
            [Environment]::Exit(0)
        }
    } else {
        $downloadDir = Join-Path $env:userprofile "Downloads"
    }

    #---------------------- Build yt-dlp arguments ----------------------
    $isGif = AsBool $inputData.isGIF
    $isMp3 = (-not $isGif) -and (AsBool $inputData.mp3)
    $outTemplate = '%(title).50B [%(id)s].%(ext)s'
    $uniq        = [guid]::NewGuid().ToString('N')
    $pathFile    = Join-Path $logsDirectory ("path_" + $uniq + ".txt")
    $metaFile    = Join-Path $logsDirectory ("meta_" + $uniq + ".txt")
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

    $tokens = @(
        '--no-mtime', '--newline', '--no-playlist', '--windows-filenames', '--no-warnings',
        '--socket-timeout', '30', '--retries', '10', '--fragment-retries', '10',
        '--progress-template', 'download:[[PROG]]|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s',
        '--print-to-file', 'before_dl:%(.{title,uploader,duration,thumbnail})j', $metaFile,
        '--print-to-file', 'after_move:%(filepath)s', $pathFile,
        '--paths', $downloadDir,
        '--paths', ('temp:' + $tempDir),
        '--output', $outTemplate
    )
    if (Test-Path -LiteralPath $ffmpegPath) { $tokens += @('--ffmpeg-location', $ffmpegPath) }
    if (Test-Path -LiteralPath $denoPath)   { $tokens += @('--js-runtimes', "deno:$denoPath") }
    if ($cut) { $tokens += @('--download-sections', $cut, '--force-keyframes-at-cuts', '--hls-use-mpegts') }
    if ($isMp3) { $tokens += @('-x', '--audio-format', 'mp3', '--audio-quality', '0') }
    elseif ((-not $isGif) -and (AsBool $inputData.convertMP4)) { $tokens += @('--recode-video', 'mp4') }
    if (AsBool $inputData.useChromeCookies) { $tokens += @('--cookies-from-browser', 'chrome') }
    if (AsBool $inputData.keepConsoleOpen)  { $tokens += @('-v') }
    $tokens += @('--', $url)

    $argString = ($tokens | ForEach-Object { Quote-Arg $_ }) -join ' '
    Log "yt-dlp args: $argString"

    Send-Progress 'prepare' 'Analyzing video…'

    #---------------------- Run yt-dlp with live progress ----------------------
    $script:globalPct   = 0
    $script:streamCount = 1
    $script:streamsSeen = 0
    $script:analyzed    = $false
    $script:postprocessing = $false
    $script:mediaDuration = $null
    $script:errLines    = New-Object System.Collections.ArrayList
    # Monotonic clock for the progress throttle. NOT [Environment]::TickCount:
    # it is an Int32 that goes negative past ~25 days of uptime, and PowerShell
    # promotes the overflowing subtraction to double instead of wrapping.
    $script:progSw       = [System.Diagnostics.Stopwatch]::StartNew()
    $script:lastProgSent = [long]-1000000
    $script:lastSentPct  = -1
    $ytLog     = Join-Path $logsDirectory ("ytdlp_" + $uniq + ".log")
    $script:ytLogWriter = $null
    try {
        $script:ytLogWriter = New-Object System.IO.StreamWriter($ytLog, $true, (New-Object System.Text.UTF8Encoding($false)))
        $script:ytLogWriter.AutoFlush = $true
    } catch { $script:ytLogWriter = $null }
    $finalPath = $null
    $exitCode  = -1
    $aborted   = $false
    $abortReason = ''
    $dlStart   = Get-Date

    try {
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
                    $g = [int][math]::Floor(((($idx + ($filePct / 100.0)) / $n) * 90.0))
                    if ($g -gt $script:globalPct) { $script:globalPct = $g }
                    # Throttle: yt-dlp can emit 10-30+ progress lines/sec and each one costs
                    # a JSON serialize + native message + port relay + ~15 DOM writes.
                    # Send on integer-percent change OR every 250ms (keeps speed/ETA live).
                    $nowMs = $script:progSw.ElapsedMilliseconds
                    if (($script:globalPct -ne $script:lastSentPct) -or (($nowMs - $script:lastProgSent) -ge 250)) {
                        $script:lastSentPct  = $script:globalPct
                        $script:lastProgSent = $nowMs
                        Send-Progress -Stage 'download' -Message 'Downloading…' -Percent $script:globalPct -Speed ($p[2].Trim()) -Eta ($p[3].Trim()) -Downloaded $dl -Total $tot
                    }
                }
                return
            }

            # One persistent writer (AutoFlush) instead of a CreateFile/CloseHandle
            # cycle per line — with -v yt-dlp emits hundreds of lines.
            if ($script:ytLogWriter) { try { $script:ytLogWriter.WriteLine($line) } catch { } }
            if ($isErr) { [void]$script:errLines.Add($line) }

            if ($line -match '^\[info\].*Downloading\s+\d+\s+format') {
                $fm = [regex]::Match($line, ':\s*([0-9a-zA-Z+\-\.]+)\s*$')
                if ($fm.Success) { $c = ($fm.Groups[1].Value -split '\+').Count; if ($c -gt $script:streamCount) { $script:streamCount = $c } }
            }
            elseif ($line -match '^\[download\]\s+Destination:') { $script:streamsSeen++ }
            elseif ($line -match 'Retrying|Got server error|timed out|Temporary failure|Unable to connect') {
                Send-Progress -Stage 'download' -Message 'Unstable connection, retrying…' -Percent $script:globalPct
            }
            elseif ($line -match '^\[Merger\]')       { $script:postprocessing = $true; if ($script:globalPct -lt 93) { $script:globalPct = 93 }; Send-Progress -Stage 'postprocess' -Message 'Merging audio/video tracks…' -Percent $script:globalPct }
            elseif ($line -match '^\[ExtractAudio\]') { $script:postprocessing = $true; if ($script:globalPct -lt 93) { $script:globalPct = 93 }; Send-Progress -Stage 'postprocess' -Message "Extracting audio…" -Percent $script:globalPct }
            elseif ($line -match '^\[(VideoConvertor|VideoRemuxer|Recode)\]') { $script:postprocessing = $true; if ($script:globalPct -lt 95) { $script:globalPct = 95 }; Send-Progress -Stage 'postprocess' -Message 'Converting format…' -Percent $script:globalPct }
            elseif ($line -match '^\[(youtube|info|generic|facebook|instagram|tiktok|twitter)') { if (-not $script:analyzed) { $script:analyzed = $true; Send-Progress -Stage 'prepare' -Message 'Analyzing video…' } }
        }

        $lastActivity = Get-Date
        $script:metaSent = $false
        $loopN = 0
        $readMeta = {
            if ($script:metaSent -or -not (Test-Path -LiteralPath $metaFile)) { return }
            try {
                $raw = [System.IO.File]::ReadAllText($metaFile, [System.Text.Encoding]::UTF8)
                if ($raw -and $raw.TrimStart().StartsWith('{')) {
                    $md = $raw | ConvertFrom-Json
                    if ($md.duration) { $script:mediaDuration = [double]$md.duration }
                    Send-Meta $md.title $md.uploader $md.duration $md.thumbnail
                    $script:metaSent = $true
                }
            } catch { }
        }

        while ((-not $proc.HasExited) -or ($queue.Count -gt 0)) {
            if ($script:cancelFlag.stop -or $script:portDead) { $aborted = $true; $abortReason = 'cancel'; break }

            # Meta polling gated to every 8th iteration (a Test-Path filesystem stat
            # 16x/sec for a multi-minute download is pure waste; <=1s of extra meta
            # latency is invisible).
            $loopN++
            if (-not $script:metaSent -and ($loopN % 8 -eq 0)) { & $readMeta }

            if ($queue.Count -gt 0) {
                $lastActivity = Get-Date
                & $handleLine ($queue.Dequeue())
            } else {
                # Inactivity watchdog. Download phase: 120s. Post-processing
                # (merge/recode/mp3 via ffmpeg) is legitimately SILENT on stdout, so it
                # gets a generous 30 min ceiling — a deadlocked ffmpeg must not leave
                # the card running forever with no terminal 'done'.
                $idleLimit = if ($script:postprocessing) { 1800 } else { 120 }
                if (((Get-Date) - $lastActivity).TotalSeconds -gt $idleLimit) {
                    $aborted = $true
                    $abortReason = if ($script:postprocessing) { 'pp-timeout' } else { 'timeout' }
                    break
                }
                Start-Sleep -Milliseconds 120
            }
        }

        if (-not $aborted) {
            $proc.WaitForExit()
            $flushDeadline = (Get-Date).AddMilliseconds(400)
            while ((Get-Date) -lt $flushDeadline) {
                while ($queue.Count -gt 0) { & $handleLine ($queue.Dequeue()) }
                Start-Sleep -Milliseconds 50
            }
            while ($queue.Count -gt 0) { & $handleLine ($queue.Dequeue()) }
            # Last chance: a short/fast download can finish between two gated meta
            # polls — the card must still get title/thumbnail (and the GIF branch
            # its duration anchor) before 'done'.
            & $readMeta
            $exitCode = $proc.ExitCode
        }

        try { Unregister-Event -SourceIdentifier $outEvt.Name -ErrorAction SilentlyContinue } catch { }
        try { Unregister-Event -SourceIdentifier $errEvt.Name -ErrorAction SilentlyContinue } catch { }
        try { Remove-Job -Job $outEvt -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Job -Job $errEvt -Force -ErrorAction SilentlyContinue } catch { }
        try { if ($script:ytLogWriter) { $script:ytLogWriter.Close(); $script:ytLogWriter = $null } } catch { }
    } catch {
        Log "Error executing yt-dlp: $_"
        try { if ($proc -and -not $proc.HasExited) { Stop-ProcessTree $proc.Id } } catch { }
        Remove-DownloadTemp $tempDir $metaFile $pathFile
        Send-Done $false ("Error during download: {0}" -f $_)
        [Environment]::Exit(0)
    }

    if ($aborted) {
        try { if (-not $proc.HasExited) { Stop-ProcessTree $proc.Id } } catch { }
        Remove-DownloadTemp $tempDir $metaFile $pathFile
        if ($abortReason -eq 'timeout') {
            Log "Watchdog: no output for 120s -> aborting"
            Send-Done $false "Download stalled (no response from the server). Check your connection and try again."
        } elseif ($abortReason -eq 'pp-timeout') {
            Log "Watchdog: post-processing silent for 30 min -> aborting"
            Send-Done $false "Video processing (conversion/merge) appears stuck. Try again."
        } else {
            Log "Aborted by port close / cancel"
        }
        [Environment]::Exit(0)
    }

    Log "yt-dlp exit code: $exitCode"

    if ($exitCode -ne 0) {
        $lastErr = ($script:errLines | Where-Object { $_ -match '^ERROR' } | Select-Object -Last 1)
        if (-not $lastErr) { $lastErr = ($script:errLines | Select-Object -Last 1) }
        Remove-DownloadTemp $tempDir $metaFile $pathFile
        Send-Done $false (Translate-YtDlpError $lastErr)
        [Environment]::Exit(0)
    }

    # Final path (UTF-8 from print-to-file), fallback to the freshest file of this run.
    if (Test-Path -LiteralPath $pathFile) {
        try {
            $pfLines = @(([System.IO.File]::ReadAllText($pathFile, [System.Text.Encoding]::UTF8) -split "`r?`n") | Where-Object { $_.Trim() -ne '' })
            if ($pfLines.Count -gt 0) { $finalPath = $pfLines[-1].Trim() }
        } catch { Log "path file read error: $_" }
    }
    if ((-not $finalPath) -or (-not (Test-Path -LiteralPath $finalPath))) {
        $mediaExt = @('.mp4','.webm','.mkv','.gif','.mp3','.m4a','.aac','.opus','.mov','.flv','.wav','.ogg','.3gp')
        $cand = @(Get-ChildItem -LiteralPath $downloadDir -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -ge $dlStart -and ($mediaExt -contains $_.Extension.ToLower()) } |
                  Sort-Object LastWriteTime -Descending)
        # Only trust the fallback when it is unambiguous (exactly one fresh media file of
        # this run), so a concurrent download in the same folder can't be mistaken for ours.
        if ($cand.Count -eq 1) { $finalPath = $cand[0].FullName }
    }
    Remove-Item -LiteralPath $pathFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $metaFile -Force -ErrorAction SilentlyContinue
    try { if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { }

    if ((-not $finalPath) -or (-not (Test-Path -LiteralPath $finalPath))) {
        Send-Done $false "Download finished but the file could not be found."
        [Environment]::Exit(0)
    }
    if ((Get-Item -LiteralPath $finalPath).Length -lt 1024) {
        Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue
        Send-Done $false "The downloaded file is empty or corrupted. Try again."
        [Environment]::Exit(0)
    }

    #---------------------- GIF conversion (own ffmpeg, real progress, cancelable) ----------------------
    $doneMsg = "Download complete."
    if ($isGif) {
        if (-not (Test-Path -LiteralPath $ffmpegPath)) {
            Log "ffmpeg missing; cannot make GIF, keeping video"
            $doneMsg = "Video downloaded (GIF conversion impossible: ffmpeg missing)."
        } else {
            if ($script:globalPct -lt 94) { $script:globalPct = 94 }
            Send-Progress 'postprocess' 'Converting to GIF…' $script:globalPct
            $gifOk = $false
            $palette = Join-Path $logsDirectory ("palette_" + $uniq + ".png")
            $ffprog  = Join-Path $logsDirectory ("ffprog_" + $uniq + ".txt")
            try {
                $vf = 'fps=15,scale=min(640\,iw):-2:flags=lanczos'
                $skipGif = $false
                # PS 5.1's Start-Process joins -ArgumentList with spaces WITHOUT quoting,
                # and the output template guarantees a space in the file name ("title [id]")
                # -> every path argument must be pre-quoted or ffmpeg gets stray tokens.
                $p1 = Start-Process -FilePath $ffmpegPath -ArgumentList (@('-y','-nostdin','-hide_banner','-loglevel','error','-i',$finalPath,'-an','-vf',"$vf,palettegen",$palette) | ForEach-Object { Quote-Arg $_ }) -WindowStyle Hidden -PassThru
                if (-not (Wait-ProcCancelable $p1 -TimeoutSec 1800)) {
                    Remove-Item -LiteralPath $palette -Force -ErrorAction SilentlyContinue
                    if (($script:cancelFlag -and $script:cancelFlag.stop) -or $script:portDead) {
                        Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue   # drop the intermediate video (user asked for a GIF, then cancelled)
                        Remove-DownloadTemp $tempDir $null $null
                        [Environment]::Exit(0)
                    }
                    # TIMEOUT (not cancel): deleting the downloaded video would be
                    # user-hostile — keep it and report via the gifOk fallback message.
                    Log "GIF palettegen timed out -> keeping the downloaded video"
                    $skipGif = $true
                }
                if (-not $skipGif) {
                    $dur = 0.0; if ($script:mediaDuration) { $dur = [double]$script:mediaDuration }
                    $gifPath = [System.IO.Path]::ChangeExtension($finalPath, '.gif')
                    $p2 = Start-Process -FilePath $ffmpegPath -ArgumentList (@('-y','-nostdin','-hide_banner','-loglevel','error','-progress',$ffprog,'-i',$finalPath,'-i',$palette,'-an','-lavfi',"$vf[x];[x][1:v]paletteuse",$gifPath) | ForEach-Object { Quote-Arg $_ }) -WindowStyle Hidden -PassThru
                    $script:lastGifSent = [long]-1000000
                    $poll = {
                        $prevPct = $script:globalPct
                        if ($dur -gt 0 -and (Test-Path -LiteralPath $ffprog)) {
                            try {
                                $t = [System.IO.File]::ReadAllText($ffprog)
                                $ms = [regex]::Matches($t, 'out_time_us=(\d+)')
                                if ($ms.Count -gt 0) {
                                    $frac = [math]::Min(1.0, ([double]$ms[$ms.Count - 1].Groups[1].Value / 1e6) / $dur)
                                    $gp = [int](94 + $frac * 5)
                                    if ($gp -gt $script:globalPct) { $script:globalPct = $gp }
                                }
                            } catch { }
                        }
                        # Send only on change (the GIF range spans 5 integer percents),
                        # plus a 2s liveness heartbeat.
                        $nowMs = $script:progSw.ElapsedMilliseconds
                        if (($script:globalPct -ne $prevPct) -or (($nowMs - $script:lastGifSent) -ge 2000)) {
                            $script:lastGifSent = $nowMs
                            Send-Progress 'postprocess' 'Converting to GIF…' $script:globalPct
                        }
                    }
                    $ok2 = Wait-ProcCancelable $p2 $poll -TimeoutSec 1800
                    Remove-Item -LiteralPath $palette -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $ffprog  -Force -ErrorAction SilentlyContinue
                    if (-not $ok2) {
                        Remove-Item -LiteralPath $gifPath -Force -ErrorAction SilentlyContinue
                        if (($script:cancelFlag -and $script:cancelFlag.stop) -or $script:portDead) {
                            Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue   # drop the intermediate video on GIF cancel
                            Remove-DownloadTemp $tempDir $null $null
                            [Environment]::Exit(0)
                        }
                        Log "GIF encode timed out -> keeping the downloaded video"
                    } elseif (($p2.ExitCode -eq 0) -and (Test-Path -LiteralPath $gifPath) -and ((Get-Item -LiteralPath $gifPath).Length -ge 1024)) {
                        Remove-Item -LiteralPath $finalPath -Force -ErrorAction SilentlyContinue
                        $finalPath = $gifPath
                        $gifOk = $true
                    }
                }
            } catch { Log "GIF conversion error: $_" }
            if (-not $gifOk) { $doneMsg = "Video downloaded (GIF conversion failed — video kept)." }
        }
    }

    Send-Progress 'finalize' 'Finalizing…' 100

    if (AsBool $inputData.copyAtEnd) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            $sc = New-Object System.Collections.Specialized.StringCollection
            $sc.Add($finalPath) | Out-Null
            [System.Windows.Forms.Clipboard]::SetFileDropList($sc)
        } catch { Log "Failed to copy file at end: $_" }
    }

    Send-Done $true $doneMsg $finalPath

    if (AsBool $inputData.bipAtEnd) {
        try { (New-Object Media.SoundPlayer "C:\Windows\Media\notify.wav").PlaySync() } catch { }
    }
    [Environment]::Exit(0)
}


#==========================================================================
# SHOW (reveal file in Explorer)
#==========================================================================
elseif ($mode -eq 'show') {
    try {
        if (-not (Test-Path -LiteralPath $fileToShow)) {
            Send-Legacy $false "File not found: $fileToShow"
            return
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
    [Environment]::Exit(0)
}


#==========================================================================
# DOUPDATE  (one-shot: download the latest setup.bat and run it -silent)
#==========================================================================
elseif ($mode -eq 'doupdate') {
    try {
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
        # Launch the fresh installer fully unattended (-silent). It self-elevates (one UAC),
        # then reinstalls everything (crx + ps1 fetched from GitHub, wrapper/host.json generated)
        # and restarts the browser. Detached, so it survives this host / the browser closing.
        Start-Process -FilePath $setupDest -ArgumentList '-silent' -WorkingDirectory $stage -WindowStyle Hidden
        Log "Update: launched setup.bat -silent from $stage"
        Send-Legacy $true "Update launched"
    } catch {
        Log "doupdate failed: $_"
        Send-Legacy $false ("Failed to launch the update: " + $_.Exception.Message)
    }
    [Environment]::Exit(0)
}
