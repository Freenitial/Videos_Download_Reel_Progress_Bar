<# :
    @echo off
    if exist %SystemRoot%\system32\WindowsPowerShell\v1.0\powershell.exe   set "powershell=%SystemRoot%\system32\WindowsPowerShell\v1.0\powershell.exe"
    if exist %SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe  set "powershell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    set args=%*
    rem Accept /silent as an alias for -silent (PowerShell binds -silent, not /silent).
    if defined args set "args=%args:/verysilent=-verysilent%"
    if defined args set "args=%args:/silent=-silent%"
    if defined args set "args=%args:/uninstall=-uninstall%"
    if defined args set "args=%args:"=\"%"
    "%powershell%" -NoLogo -NoProfile -STA -Window Hidden -Command ^
        ^
        %= Create loading popup =% ^
        "$M=[Runtime.InteropServices.Marshal];" ^
        "$d=[AppDomain]::CurrentDomain.DefineDynamicAssembly(" ^
        "(New-Object Reflection.AssemblyName('W')),'Run').DefineDynamicModule('W');" ^
        "$t=$d.DefineType('A','Public,Class');" ^
        "$z=$t.DefinePInvokeMethod('CreateWindowExW','user32.dll'," ^
        "'Public,Static,PinvokeImpl','Standard',([IntPtr])," ^
        "@([Int32],[String],[String],[Int32],[Int32],[Int32],[Int32],[Int32]," ^
        "[IntPtr],[IntPtr],[IntPtr],[IntPtr]),'Winapi','Unicode');" ^
        "$z.SetImplementationFlags($z.GetMethodImplementationFlags()-bor128);" ^
        "$z=$t.DefinePInvokeMethod('ShowWindow','user32.dll'," ^
        "'Public,Static,PinvokeImpl','Standard',([Bool])," ^
        "@([IntPtr],[Int32]),'Winapi','Unicode');" ^
        "$z.SetImplementationFlags($z.GetMethodImplementationFlags()-bor128);" ^
        "$z=$t.DefinePInvokeMethod('GetSystemMetrics','user32.dll'," ^
        "'Public,Static,PinvokeImpl','Standard',([Int32])," ^
        "@([Int32]),'Winapi','Unicode');" ^
        "$z.SetImplementationFlags($z.GetMethodImplementationFlags()-bor128);" ^
        "$z=$t.DefinePInvokeMethod('SendMessageW','user32.dll'," ^
        "'Public,Static,PinvokeImpl','Standard',([IntPtr])," ^
        "@([IntPtr],[UInt32],[IntPtr],[IntPtr]),'Winapi','Unicode');" ^
        "$z.SetImplementationFlags($z.GetMethodImplementationFlags()-bor128);" ^
        "$z=$t.DefinePInvokeMethod('GetStockObject','gdi32.dll'," ^
        "'Public,Static,PinvokeImpl','Standard',([IntPtr])," ^
        "@([Int32]),'Winapi','Unicode');" ^
        "$z.SetImplementationFlags($z.GetMethodImplementationFlags()-bor128);" ^
        "$z=$t.DefinePInvokeMethod('InitCommonControlsEx','comctl32.dll'," ^
        "'Public,Static,PinvokeImpl','Standard',([Bool])," ^
        "@([IntPtr]),'Winapi','Unicode');" ^
        "$z.SetImplementationFlags($z.GetMethodImplementationFlags()-bor128);" ^
        "$A=$t.CreateType();" ^
        "$sw=$A::GetSystemMetrics(0);$sh=$A::GetSystemMetrics(1);" ^
        "$hw=$A::CreateWindowExW(9,'#32770','Videos Download - Reel Progress Bar',0xC00000," ^
        "[int](($sw-440)/2),[int](($sh-130)/2),440,130," ^
        "[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero);" ^
        %= Bar is shown for normal and /silent runs; only /verysilent hides it =% ^
        "if('%args%' -notmatch 'verysilent'){$null=$A::ShowWindow($hw,5)};" ^
        "$pc=$M::AllocHGlobal(8);$M::WriteInt32($pc,0,8);$M::WriteInt32($pc,4,0x20);" ^
        "$null=$A::InitCommonControlsEx($pc);$M::FreeHGlobal($pc);" ^
        "$ft=$A::GetStockObject(17);" ^
        "$hl=$A::CreateWindowExW(0,'Static','Initializing...',0x50000000," ^
        "20,15,390,20,$hw,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero);" ^
        "$null=$A::SendMessageW($hl,0x30,$ft,[IntPtr]::Zero);" ^
        "$hb=$A::CreateWindowExW(0,'msctls_progress32','',0x50000000," ^
        "20,42,390,24,$hw,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero);" ^
        ^
        %= PowerShell self-read, skipping batch part =% ^
        "$batFile='%~f0'; $sb=[ScriptBlock]::Create([IO.File]::ReadAllText('%~f0'));& $sb @args" %args% -scriptDir '%~dp0'
    exit /b
#>

# =============================================================================
#  Videos Download - Reel Progress Bar  --  SETUP (multi-browser, self-contained)
#
#  Silently installs the extension for Google Chrome and/or Brave.
#  No external hosting: a hidden loopback HTTP server serves the CRX to the browser locally.
#  installation_mode = normal_installed by default, so the USER can disable/remove it.
#
#  Flow: self-elevate -> preflight -> detect browsers -> (form if >=2, direct if 1, error if 0)
#        -> CLEAN UNINSTALL of any previous install (policies removed while the
#           browser still runs, so it drops the extension live)
#        -> deploy module -> loopback server task -> fake-MDM gate -> per-browser policy + native host
#        -> close browsers, purge cached extension copies, serve the fresh CRX, relaunch.
#
#  Uninstall:   setup.bat /uninstall   (or -uninstall ; combinable with /silent)
#  Silent:      setup.bat /silent      (progress bar, but NO popups/dialogs)
#  Very silent: setup.bat /verysilent  (nothing at all: no bar, no popups)
# =============================================================================

param([string]$scriptDir, [switch]$Uninstall, [switch]$Silent, [switch]$VerySilent)
# $Silent = "no popups" (both flags). $VerySilent additionally hides the bar.
$script:VerySilent = [bool]$VerySilent
$script:Silent     = ([bool]$Silent) -or $script:VerySilent

# ---- Remaining functions for Invoke-LoadingPump + updates ----
$t=$d.DefineType('E','Public,Class')
foreach($x in @(
    ,@('SetWindowTextW','user32.dll',([Bool]),@([IntPtr],[String]))
    ,@('DestroyWindow','user32.dll',([Bool]),@([IntPtr]))
    ,@('PeekMessageW','user32.dll',([Bool]),@([IntPtr],[IntPtr],[UInt32],[UInt32],[UInt32]))
    ,@('TranslateMessage','user32.dll',([Bool]),@([IntPtr]))
    ,@('DispatchMessageW','user32.dll',([IntPtr]),@([IntPtr]))
)){$z=$t.DefinePInvokeMethod($x[0],$x[1],'Public,Static,PinvokeImpl','Standard',$x[2],$x[3],'Winapi','Unicode');$z.SetImplementationFlags($z.GetMethodImplementationFlags()-bor128)}
$E=$t.CreateType()

$mg=$M::AllocHGlobal(48)

# The popup helpers must only use the pinned $script:Ui* references below:
# PowerShell variables are case-insensitive and dynamically scoped, so plain
# script-body variables such as $e or $m would shadow $E / $M inside them.
$script:UiA=$A; $script:UiE=$E; $script:UiM=$M; $script:UiMg=$mg; $script:UiHw=$hw; $script:UiHl=$hl; $script:UiHb=$hb

# $BarAlive gates EVERY native call below. Once Close-LoadingPopup has destroyed
# the window and freed the MSG buffer, no helper may touch those handles again —
# otherwise (notably in -silent mode, where the bar is closed up front) the next
# Step would pump messages into freed memory and corrupt the heap.
$script:BarAlive = $true

function Invoke-LoadingPump{if(-not $script:BarAlive){return};try{$T=$script:UiE;$g=$script:UiMg;while($T::PeekMessageW($g,[IntPtr]::Zero,0,0,1)){$null=$T::TranslateMessage($g);$null=$T::DispatchMessageW($g)}}catch{}}
function Update-LoadingPopup([int]$pct,[string]$s){if(-not $script:BarAlive){return};try{$TA=$script:UiA;$TE=$script:UiE;$null=$TA::SendMessageW($script:UiHb,0x402,[IntPtr]$pct,[IntPtr]::Zero);if($s){$null=$TE::SetWindowTextW($script:UiHl,$s)};Invoke-LoadingPump}catch{}}
# Teardown runs once; BarAlive is already $false by the time we get here (set by
# Close-ProgressBar), so we destroy + free directly and never pump afterwards.
function Close-LoadingPopup{try{$TE=$script:UiE;$null=$TE::DestroyWindow($script:UiHw);$TM=$script:UiM;$TM::FreeHGlobal($script:UiMg)}catch{}}

# --- Progress-bar visibility management -------------------------------------
# Rule: the bar HIDES whenever a popup/form is shown, REAPPEARS after it if work
# continues, and is CLOSED for good on any terminal path (Show-*Box are all
# terminal). In -silent mode the window was never shown; close it immediately.
function Hide-ProgressBar  { if ($script:BarAlive) { try { $T = $script:UiA; $null = $T::ShowWindow($script:UiHw, 0); Invoke-LoadingPump } catch {} } }
function Show-ProgressBar  { if ($script:BarAlive -and -not $script:VerySilent) { try { $T = $script:UiA; $null = $T::ShowWindow($script:UiHw, 5); Invoke-LoadingPump } catch {} } }
function Close-ProgressBar { if ($script:BarAlive) { $script:BarAlive = $false; Close-LoadingPopup } }
if ($script:VerySilent) { Close-ProgressBar } else { Update-LoadingPopup 5 "Loading..." }

# ----------------------------- CONFIG (ID/version from build.ps1) -----------------------
$ExtId       = 'olmpldphnohichgojfebcgbciknbmpfm'
$ExtVersion  = '2.1'                       # FALLBACK only; setup reads the real version from ext.crx
$HostName    = 'freenitial_yt_dlp_host'    # must match sendNativeMessage(...) in background.js
$ServerPort  = 47653                       # loopback port; must match build.ps1
$InstallMode = 'normal_installed'          # 'normal_installed' = user can disable/remove ; 'force_installed' = locked
$DlBase      = 'https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download'
$YtDlpUrl    = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
$FfmpegZip   = 'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-lgpl.zip'
$DenoZip     = 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip'
$InstallDir  = "$env:ProgramData\Videos Download - Reel Progress Bar"
$TaskName    = 'VideosDownload-LocalExtHost'
$UpdateUrl   = "http://127.0.0.1:$ServerPort/updates.xml"
# ----------------------------------------------------------------------------------------

# Browser catalog. Only browsers that actually honor the policy mechanism are listed.
#  PolicyRoot         : where the browser reads ExtensionSettings/ExtensionInstallForcelist (Brave: NO -Browser).
#  NmRoot             : NativeMessagingHosts root (Brave: WITH -Browser).
#  DetectGlob         : all-users on-disk Extensions path, used by the SYSTEM server to detect install.
$BrowserCatalog = @(
    @{ Key = 'Chrome'; Name = 'Google Chrome'; Proc = 'chrome'; AppPath = 'chrome.exe';
       Exe = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe");
       PolicyRoot = 'HKLM:\SOFTWARE\Policies\Google\Chrome';
       NmRoot     = 'HKLM:\SOFTWARE\Google\Chrome\NativeMessagingHosts';
       DetectGlob = 'C:\Users\*\AppData\Local\Google\Chrome\User Data\*\Extensions' }
    @{ Key = 'Brave'; Name = 'Brave'; Proc = 'brave'; AppPath = 'brave.exe';
       Exe = @("$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe", "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe", "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe");
       PolicyRoot = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave';
       NmRoot     = 'HKLM:\SOFTWARE\BraveSoftware\Brave-Browser\NativeMessagingHosts';
       DetectGlob = 'C:\Users\*\AppData\Local\BraveSoftware\Brave-Browser\User Data\*\Extensions' }
)

$ErrorActionPreference = 'Stop'
$self = $batFile
if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = if ($self) { Split-Path -Parent $self } else { (Get-Location).Path } }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# French UI if the system UI language is French (else English).
$Fr = ([System.Globalization.CultureInfo]::InstalledUICulture.TwoLetterISOLanguageName -eq 'fr')

# Localized progress step: bar % + label in one call.
function Step { param([int]$Pct, [string]$FrMsg, [string]$EnMsg)
    Update-LoadingPopup $Pct ($(if ($Fr -and $FrMsg) { $FrMsg } else { $EnMsg })) }

# ------------------------------------------------------------------ UI + logging helpers
# Both boxes are only ever used on TERMINAL paths -> close the bar for good first.
function Show-ErrorBox { param([string]$Msg)
    Log ("ERRORBOX: " + $Msg)
    Close-ProgressBar
    if ($script:Silent) { return }
    [void][System.Windows.Forms.MessageBox]::Show($Msg, 'Videos Download - Setup', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) }
function Show-InfoBox  { param([string]$Msg)
    Log ("INFOBOX: " + $Msg)
    Close-ProgressBar
    if ($script:Silent) { return }
    [void][System.Windows.Forms.MessageBox]::Show($Msg, 'Videos Download - Setup', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) }
$script:LogFile = $null
function Log { param([string]$Msg)
    Write-Host $Msg
    if ($script:LogFile) { try { [IO.File]::AppendAllText($script:LogFile, ('[{0}] {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg, [Environment]::NewLine)) } catch {} }
}

# ------------------------------------------------------------------ browser detection / selection
function Resolve-BrowserExe {
    param($B)
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths',
                        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths')) {
        $k = Join-Path $root $B.AppPath
        if (Test-Path $k) { $v = (Get-ItemProperty $k).'(default)'; if ($v) { $v = $v.Trim('"'); if (Test-Path $v) { return $v } } }
    }
    foreach ($e in $B.Exe) { if (Test-Path $e) { return $e } }
    return $null
}
function Get-InstalledBrowsers {
    $found = @()
    foreach ($b in $BrowserCatalog) { $exe = Resolve-BrowserExe $b; if ($exe) { $b.ExePath = $exe; $found += $b } }
    return $found
}
function Show-BrowserForm {
    param($Browsers)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = if ($Fr) { 'Choisir les navigateurs' } else { 'Choose browsers' }
    $form.FormBorderStyle = 'FixedDialog'; $form.StartPosition = 'CenterScreen'
    $form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.Topmost = $true
    $form.ClientSize = New-Object System.Drawing.Size(320, (70 + 28 * $Browsers.Count + 45))
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = if ($Fr) { "Installer l'extension pour :" } else { 'Install the extension for:' }
    $lbl.AutoSize = $true; $lbl.Left = 16; $lbl.Top = 16; $form.Controls.Add($lbl)
    $checks = @(); $y = 46
    foreach ($b in $Browsers) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $b.Name; $cb.Checked = $true; $cb.Left = 22; $cb.Top = $y; $cb.Width = 270; $cb.Tag = $b
        $form.Controls.Add($cb); $checks += $cb; $y += 28
    }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = if ($Fr) { 'Installer' } else { 'Install' }
    $ok.Left = 210; $ok.Top = $y + 12; $ok.Width = 90; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok); $form.AcceptButton = $ok
    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return @() }
    return @($checks | Where-Object { $_.Checked } | ForEach-Object { $_.Tag })
}

# ------------------------------------------------------------------ browser (re)launch helpers
function Wait-Port {
    param([int]$Port, [int]$TimeoutMs = 5000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        try { $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $Port); $c.Close(); return $true } catch { Start-Sleep -Milliseconds 150 }
    }
    return $false
}
function Wait-HttpReady {
    # Stronger than Wait-Port: actually issue an HTTP GET and require a 200, so we KNOW the
    # loopback server is answering (not just that the port is bound) before we relaunch Chrome.
    param([int]$Port, [string]$Path = '/updates.xml', [int]$TimeoutMs = 8000)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ((Get-Date) -lt $deadline) {
        try {
            $c = New-Object System.Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $Port)
            $ns = $c.GetStream(); $ns.ReadTimeout = 2000
            $req = [Text.Encoding]::ASCII.GetBytes("GET $Path HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
            $ns.Write($req, 0, $req.Length); $ns.Flush()
            $sr = New-Object System.IO.StreamReader($ns); $line = $sr.ReadLine(); $c.Close()
            if ($line -match ' 200 ') { return $true }
        } catch { Start-Sleep -Milliseconds 200 }
    }
    return $false
}
function Get-BrowserProcs { param($B) Get-Process -Name $B.Proc -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $B.ExePath } }
function Close-BrowserGracefully {
    # Ask the browser to close normally (avoids the "restore pages" prompt); poll every 100ms; hard-kill only after 2500ms.
    param($B)
    $procs = Get-BrowserProcs $B
    if (-not $procs) { return }
    foreach ($p in $procs) { try { [void]$p.CloseMainWindow() } catch {} }
    $deadline = (Get-Date).AddMilliseconds(2500)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        if (-not (Get-BrowserProcs $B)) { Log "$($B.Name) closed gracefully."; return }
    }
    Log "$($B.Name) did not close in 2.5s -> forcing."
    Get-BrowserProcs $B | Stop-Process -Force -ErrorAction SilentlyContinue
}
function Start-BrowserDeElevated {
    # Launch at normal integrity (setup runs elevated) by asking the user shell to start it.
    param([string]$ExePath)
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$ExePath`"" } catch { Start-Process -FilePath $ExePath }
}
function Remove-CachedExtension {
    # Delete the browser's on-disk copy of our extension (all profiles) so the
    # browser re-fetches it from the loopback server on next launch. The browser
    # MUST be closed.
    param($B, [string]$Id)
    foreach ($m in @(Resolve-Path -Path $B.DetectGlob -ErrorAction SilentlyContinue)) {
        $extPath = Join-Path $m.Path $Id
        if (Test-Path -LiteralPath $extPath) {
            try { Remove-Item -LiteralPath $extPath -Recurse -Force -ErrorAction Stop; Log "Removed cached extension: $extPath" }
            catch { Log "Could not remove cached extension '$extPath': $($_.Exception.Message)" }
        }
    }
}
function Clear-ExtensionPrefState {
    # The browser keeps the installed version in each profile's (signed) "Secure
    # Preferences" file. Purging the on-disk copy is NOT enough: the browser still
    # remembers the version and refuses to (re)install an equal/lower one from the
    # loopback. Removing our extension's entry AND its integrity MAC makes the
    # browser treat it as never-installed -> a fresh install of ANY version applies.
    # Only our own extension id is touched; every other setting is preserved; a
    # .vdrpb.bak backup is written first. The browser MUST be closed.
    param($B, [string]$Id)
    $udGlob = $B.DetectGlob -replace '\\\*\\Extensions$', ''
    foreach ($ud in @(Resolve-Path -Path $udGlob -ErrorAction SilentlyContinue)) {
        foreach ($prof in @(Get-ChildItem -LiteralPath $ud.Path -Directory -ErrorAction SilentlyContinue)) {
            foreach ($fn in @('Secure Preferences', 'Preferences')) {
                $pf = Join-Path $prof.FullName $fn
                if (-not (Test-Path -LiteralPath $pf)) { continue }
                try {
                    $raw = [IO.File]::ReadAllText($pf)
                    if ($raw -notmatch [regex]::Escape($Id)) { continue }   # id absent from this file -> nothing to do
                    $j = $raw | ConvertFrom-Json
                    $changed = $false
                    $settings = $j.extensions.settings
                    if ($settings -and $settings.PSObject.Properties[$Id]) { $settings.PSObject.Properties.Remove($Id); $changed = $true }
                    $macs = $j.protection.macs.extensions.settings
                    if ($macs -and $macs.PSObject.Properties[$Id]) { $macs.PSObject.Properties.Remove($Id); $changed = $true }
                    if ($changed) {
                        Copy-Item -LiteralPath $pf -Destination ($pf + '.vdrpb.bak') -Force -ErrorAction SilentlyContinue
                        [IO.File]::WriteAllText($pf, ($j | ConvertTo-Json -Depth 100 -Compress), (New-Object System.Text.UTF8Encoding($false)))
                        Log "Cleared extension state ($Id) from: $pf"
                    }
                } catch { Log "Could not clear extension state in '$pf': $($_.Exception.Message)" }
            }
        }
    }
}

# ------------------------------------------------------------------ CRX version helper
function Get-CrxVersion {
    param([string]$CrxPath)
    try {
        $bytes = [IO.File]::ReadAllBytes($CrxPath)
        if ([Text.Encoding]::ASCII.GetString($bytes, 0, 4) -ne 'Cr24') { return $null }
        $zipOffset = 12 + [BitConverter]::ToUInt32($bytes, 8)
        $zipBytes  = [byte[]]$bytes[$zipOffset..($bytes.Length - 1)]
        Add-Type -AssemblyName System.IO.Compression
        $ms = New-Object System.IO.MemoryStream(, $zipBytes)
        $za = New-Object System.IO.Compression.ZipArchive($ms)
        try {
            $entry = $za.GetEntry('manifest.json'); if (-not $entry) { return $null }
            $sr = New-Object System.IO.StreamReader($entry.Open())
            $v  = [string](($sr.ReadToEnd() | ConvertFrom-Json).version); $sr.Close(); return $v
        } finally { $za.Dispose(); $ms.Dispose() }
    } catch { return $null }
}

# ------------------------------------------------------------------ force-install policy helpers (per-browser)
# On the REGISTRY provider, New-Item -Force on an EXISTING key wipes it -> always guard with Test-Path.
function Clear-FromExtensionSettings {
    param([string]$Id, [string]$PolicyRoot)
    $cur = (Get-ItemProperty -Path $PolicyRoot -Name 'ExtensionSettings' -ErrorAction SilentlyContinue).ExtensionSettings
    if (-not $cur) { return }
    try { $dict = $cur | ConvertFrom-Json } catch { Remove-ItemProperty -Path $PolicyRoot -Name 'ExtensionSettings' -ErrorAction SilentlyContinue; return }
    if ($dict.PSObject.Properties[$Id]) {
        $dict.PSObject.Properties.Remove($Id)
        if (@($dict.PSObject.Properties).Count -gt 0) { Set-ItemProperty -Path $PolicyRoot -Name 'ExtensionSettings' -Value ($dict | ConvertTo-Json -Depth 10 -Compress) -Type String }
        else { Remove-ItemProperty -Path $PolicyRoot -Name 'ExtensionSettings' -ErrorAction SilentlyContinue }
    }
}
function Clear-FromForcelist {
    param([string]$Id, [string]$PolicyRoot)
    $fl = Join-Path $PolicyRoot 'ExtensionInstallForcelist'
    if (-not (Test-Path $fl)) { return }
    foreach ($p in (Get-Item $fl).Property) {
        if ($p -match '^\d+$') { $v = (Get-ItemProperty -Path $fl -Name $p).$p; if ($v -like "$Id;*" -or $v -eq $Id) { Remove-ItemProperty -Path $fl -Name $p -ErrorAction SilentlyContinue } }
    }
}
function Set-ViaExtensionSettings {
    param([string]$Id, [string]$Url, [string]$Mode, [string]$PolicyRoot)
    try {
        if (-not (Test-Path $PolicyRoot)) { New-Item -Path $PolicyRoot -Force | Out-Null }
        $cur  = (Get-ItemProperty -Path $PolicyRoot -Name 'ExtensionSettings' -ErrorAction SilentlyContinue).ExtensionSettings
        $dict = if ($cur) { try { $cur | ConvertFrom-Json } catch { [pscustomobject]@{} } } else { [pscustomobject]@{} }
        $entry = [ordered]@{ installation_mode = $Mode; update_url = $Url; override_update_url = $true }
        if ($dict.PSObject.Properties[$Id]) { $dict.$Id = $entry } else { $dict | Add-Member -NotePropertyName $Id -NotePropertyValue $entry }
        Set-ItemProperty -Path $PolicyRoot -Name 'ExtensionSettings' -Value ($dict | ConvertTo-Json -Depth 10 -Compress) -Type String
        $rb = (Get-ItemProperty -Path $PolicyRoot -Name 'ExtensionSettings' -ErrorAction Stop).ExtensionSettings | ConvertFrom-Json
        if ($rb.$Id -and $rb.$Id.installation_mode -eq $Mode) { return $true }
        throw 'read-back verification failed'
    } catch { Log "ExtensionSettings failed ($PolicyRoot): $($_.Exception.Message)"; Clear-FromExtensionSettings -Id $Id -PolicyRoot $PolicyRoot; return $false }
}
function Set-ViaForcelist {
    param([string]$Id, [string]$Url, [string]$PolicyRoot)
    $fl = Join-Path $PolicyRoot 'ExtensionInstallForcelist'
    try {
        if (-not (Test-Path $fl)) { New-Item -Path $fl -Force | Out-Null }
        $max = 0; $slot = $null
        foreach ($p in (Get-Item $fl).Property) {
            if ($p -match '^\d+$') { $max = [Math]::Max($max, [int]$p); $v = (Get-ItemProperty -Path $fl -Name $p).$p; if ($v -like "$Id;*" -or $v -eq $Id) { $slot = $p } }
        }
        if (-not $slot) { $slot = [string]($max + 1) }
        Set-ItemProperty -Path $fl -Name $slot -Value "$Id;$Url" -Type String
        $rb = (Get-ItemProperty -Path $fl -Name $slot -ErrorAction Stop).$slot
        if ($rb -like "$Id;*") { return $true }
        throw 'read-back verification failed'
    } catch { Log "ExtensionInstallForcelist failed ($PolicyRoot): $($_.Exception.Message)"; Clear-FromForcelist -Id $Id -PolicyRoot $PolicyRoot; return $false }
}
function Apply-BrowserPolicy {
    param($Browser, [string]$Id, [string]$Url, [string]$Mode)
    $root = $Browser.PolicyRoot
    if ($Mode -eq 'force_installed') {
        if     (Set-ViaExtensionSettings -Id $Id -Url $Url -Mode 'force_installed' -PolicyRoot $root) { Clear-FromForcelist -Id $Id -PolicyRoot $root; return 'ExtensionSettings(force)' }
        elseif (Set-ViaForcelist         -Id $Id -Url $Url -PolicyRoot $root)                          { Clear-FromExtensionSettings -Id $Id -PolicyRoot $root; return 'ExtensionInstallForcelist(force)' }
        else { throw "force-install policy failed for $($Browser.Name)" }
    } else {
        # normal_installed is ONLY expressible via ExtensionSettings; a forcelist entry would override it -> purge.
        Clear-FromForcelist -Id $Id -PolicyRoot $root
        if (Set-ViaExtensionSettings -Id $Id -Url $Url -Mode 'normal_installed' -PolicyRoot $root) { return 'ExtensionSettings(normal)' }
        else { throw "normal-install policy failed for $($Browser.Name)" }
    }
}
function Register-NativeHost {
    param($Browser, [string]$HostJsonPath)
    $nmh = Join-Path $Browser.NmRoot $HostName
    if (-not (Test-Path $nmh)) { New-Item -Path $nmh -Force | Out-Null }
    Set-ItemProperty -Path $nmh -Name '(default)' -Value $HostJsonPath
    $hkcu = Join-Path ($Browser.NmRoot -replace '^HKLM:', 'HKCU:') $HostName
    Remove-Item -Path $hkcu -Force -ErrorAction SilentlyContinue   # drop a stale per-user registration
}

# ------------------------------------------------------------------ core uninstall (shared by -Uninstall and the install-time clean pass)
function Invoke-CoreUninstall {
    # Removes everything a previous setup may have written (task, policies, native
    # host registrations, install folder). Returns a warnings array (empty = clean).
    # The shared fake-MDM keys are intentionally LEFT in place (benign / possibly shared).
    $errs = @()
    try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { $errs += "task: $($_.Exception.Message)" }
    foreach ($b in $BrowserCatalog) {
        try {
            Clear-FromExtensionSettings -Id $ExtId -PolicyRoot $b.PolicyRoot
            Clear-FromForcelist        -Id $ExtId -PolicyRoot $b.PolicyRoot
            Remove-Item -Path (Join-Path $b.NmRoot $HostName) -Force -ErrorAction SilentlyContinue
            Remove-Item -Path (Join-Path ($b.NmRoot -replace '^HKLM:', 'HKCU:') $HostName) -Force -ErrorAction SilentlyContinue
        } catch { $errs += "$($b.Name): $($_.Exception.Message)" }
    }
    if (Test-Path $InstallDir) {
        # Retry: a just-stopped server task / running native host releases its handles asynchronously.
        for ($i = 0; $i -lt 3; $i++) {
            Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $InstallDir)) { break }
            Start-Sleep -Milliseconds 400
        }
        if (Test-Path $InstallDir) { $errs += "folder: still present (a file may be in use - close the browser and retry)" }
    }
    return , $errs
}

# ------------------------------------------------------------------ 1) elevation
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    try {
        $relArgs = @()
        if ($Uninstall)          { $relArgs += '-Uninstall' }
        if ($script:VerySilent)  { $relArgs += '-verysilent' } elseif ($Silent) { $relArgs += '-silent' }
        $spArgs = @{ FilePath = $self; Verb = 'RunAs'; WindowStyle = $(if ($script:Silent) { 'Hidden' } else { 'Normal' }) }
        if ($relArgs.Count -gt 0) { $spArgs['ArgumentList'] = $relArgs }
        Close-ProgressBar   # the elevated instance draws its own bar
        Start-Process @spArgs
    } catch { Show-ErrorBox "Administrator rights are required.`n`n$($_.Exception.Message)" }
    return
}

# ------------------------------------------------------------------ UNINSTALL branch (setup.bat /uninstall [-silent])
if ($Uninstall) {
    Step 20 'Désinstallation en cours…' 'Uninstalling…'
    $errors = @(Invoke-CoreUninstall)
    Step 100 'Terminé.' 'Done.'
    if ($errors.Count -eq 0) {
        $m = if ($Fr) { "Désinstallé proprement.`n`nL'extension disparaîtra au prochain redémarrage du navigateur." }
             else     { "Uninstalled cleanly.`n`nThe extension disappears at the next browser restart." }
        Show-InfoBox $m
    } else {
        $head = if ($Fr) { 'Désinstallé avec des avertissements :' } else { 'Uninstalled with warnings:' }
        Show-ErrorBox ($head + "`n`n" + ($errors -join "`n"))
    }
    Close-ProgressBar   # silent path: the boxes were skipped, make sure the (hidden) window dies
    return
}

# ------------------------------------------------------------------ 2) pre-flight checks
Step 8 'Vérifications préalables…' 'Pre-flight checks…'
try {
    $cv    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$cv.CurrentBuild
    $ed    = [string]$cv.EditionID
    if ($build -lt 10240) { Show-ErrorBox "Windows 10 or later is required.`n`nDetected build: $build"; return }
    if ($ed -match '^Core') {
        Show-ErrorBox ("Windows edition '$ed' (Home) is not supported.`n`n" +
            "Silent off-store extension install requires Windows 10/11 Pro, Enterprise or Education (the MDM gate excludes Home).")
        return
    }
}
catch { Show-ErrorBox "Pre-flight check failed:`n$($_.Exception.Message)"; return }

# ------------------------------------------------------------------ 3) detect + select browsers
Step 10 'Détection des navigateurs…' 'Detecting browsers…'
$installedBrowsers = @(Get-InstalledBrowsers)
if ($installedBrowsers.Count -eq 0) {
    $m = if ($Fr) { "Aucun navigateur compatible (Google Chrome ou Brave) trouvé.`n`nInstalle-en un et relance le setup." }
         else     { "No supported browser (Google Chrome or Brave) was found.`n`nInstall one and run this setup again." }
    Show-ErrorBox $m
    return
}
elseif ($script:Silent -or $installedBrowsers.Count -eq 1) {
    $selected = @($installedBrowsers)   # silent (or single) -> install on ALL found browsers, no form
}
else {
    Hide-ProgressBar                                     # a form is a popup: the bar steps aside
    $selected = @(Show-BrowserForm $installedBrowsers)
    Show-ProgressBar
    if ($selected.Count -eq 0) {
        $m = if ($Fr) { 'Aucun navigateur sélectionné. Installation annulée.' } else { 'No browser selected. Installation cancelled.' }
        Show-InfoBox $m
        return
    }
}

# ------------------------------------------------------------------ 3b) ALWAYS clean-uninstall the previous install first
# A full uninstall/reinstall is deterministic: the policies are removed HERE,
# while the browser is still running, so it picks the removal up live and
# completely forgets the extension. Step 11 later closes the browser, purges
# the cached copies and serves the fresh CRX under the re-added policy.
Step 14 "Nettoyage de l'installation précédente…" 'Cleaning previous install…'
$cleanWarn = @(Invoke-CoreUninstall)
foreach ($w in $cleanWarn) { Log "WARN (clean pass): $w" }

# ------------------------------------------------------------------ install dir + logging
Step 18 'Préparation du dossier…' 'Preparing folder…'
try {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $logDir = Join-Path $InstallDir 'Logs'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $script:LogFile = Join-Path $logDir ('setup_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Log ("Selected browsers: " + (($selected | ForEach-Object { $_.Name }) -join ', ') + " ; mode=$InstallMode")
}
catch { Show-ErrorBox "Cannot create install folder '$InstallDir':`n$($_.Exception.Message)"; return }

# ------------------------------------------------------------------ download helpers
function Invoke-DownloadUrl {
    param([string]$Url, [string]$Dest)
    $ok = $false
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fSLo $Dest $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path $Dest) -and (Get-Item $Dest).Length -gt 0) { $ok = $true }
    }
    if (-not $ok) {
        $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing } finally { $ProgressPreference = $prev }
    }
    if (-not (Test-Path $Dest) -or (Get-Item $Dest).Length -eq 0) { throw "Download failed or empty file: $Url" }
}
function Get-ModuleFile {
    param([string]$Name, [string]$Url)
    $dest = Join-Path $InstallDir $Name; $local = Join-Path $scriptDir $Name
    if (Test-Path -LiteralPath $local) { Copy-Item -LiteralPath $local -Destination $dest -Force; Log "Copied (offline): $Name" }
    else { Log "Downloading: $Name"; Invoke-DownloadUrl -Url $Url -Dest $dest; Log "Downloaded: $Name" }
}

# ------------------------------------------------------------------ 4) deploy module + extension payload
try {
    # GitHub package is now SLIM: only ext.crx + script.ps1 come from the release.
    # The wrapper is generated below; host.json/updates.xml/localserver.ps1 are generated too;
    # yt-dlp/ffmpeg/deno come from their own official sources. No loose js/json/png is ever fetched.
    Step 24 'Déploiement du module…' 'Deploying module…'
    Get-ModuleFile 'freenitial_yt_dlp_script.ps1'  "$DlBase/freenitial_yt_dlp_script.ps1"
    Step 30 'Récupération de yt-dlp…' 'Fetching yt-dlp…'
    Get-ModuleFile 'yt-dlp.exe'                     $YtDlpUrl
    Step 40 "Récupération de l'extension…" 'Fetching the extension…'
    Get-ModuleFile 'ext.crx'                        "$DlBase/ext.crx"
    Step 45 'Récupération de ffmpeg…' 'Fetching ffmpeg…'
    $ffExes  = @('ffmpeg.exe', 'ffprobe.exe', 'ffplay.exe')
    $haveAll = -not (($ffExes | ForEach-Object { Test-Path (Join-Path $scriptDir $_) }) -contains $false)
    if ($haveAll) { foreach ($f in $ffExes) { Copy-Item -LiteralPath (Join-Path $scriptDir $f) -Destination (Join-Path $InstallDir $f) -Force; Log "Copied (offline): $f" } }
    else {
        $zipDest = Join-Path $InstallDir 'ffmpeg.zip'; Log "Downloading ffmpeg build..."; Invoke-DownloadUrl -Url $FfmpegZip -Dest $zipDest
        Step 56 'Extraction de ffmpeg…' 'Extracting ffmpeg…'
        Add-Type -AssemblyName System.IO.Compression.FileSystem; Add-Type -AssemblyName System.IO.Compression
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipDest)
        try { foreach ($e in $zip.Entries) { if ($e.Name -like '*.exe') { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $InstallDir $e.Name), $true); Log "Extracted: $($e.Name)" } } }
        finally { $zip.Dispose() }
        Remove-Item $zipDest -Force -ErrorAction SilentlyContinue
    }
    # deno JavaScript runtime (required by yt-dlp for full YouTube support). Single
    # portable exe; non-fatal if it fails (the module re-fetches it on next update).
    Step 62 'Récupération de deno…' 'Fetching deno…'
    $denoLocal = Join-Path $scriptDir 'deno.exe'
    if (Test-Path -LiteralPath $denoLocal) {
        Copy-Item -LiteralPath $denoLocal -Destination (Join-Path $InstallDir 'deno.exe') -Force; Log "Copied (offline): deno.exe"
    } else {
        try {
            $denoZipDest = Join-Path $InstallDir 'deno.zip'; Log "Downloading deno runtime..."; Invoke-DownloadUrl -Url $DenoZip -Dest $denoZipDest
            Add-Type -AssemblyName System.IO.Compression.FileSystem; Add-Type -AssemblyName System.IO.Compression
            $dz = [System.IO.Compression.ZipFile]::OpenRead($denoZipDest)
            try { foreach ($e in $dz.Entries) { if ($e.Name -eq 'deno.exe') { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $InstallDir 'deno.exe'), $true); Log "Extracted: deno.exe" } } }
            finally { $dz.Dispose() }
            Remove-Item $denoZipDest -Force -ErrorAction SilentlyContinue
        } catch { Log "WARN: deno download failed (YouTube may be degraded until next auto-update): $($_.Exception.Message)" }
    }

    # Build the native-host wrapper HERE (deliberately NOT shipped in the GitHub package).
    Step 66 'Génération du module natif…' 'Generating native host…'
    $wrapperPath = Join-Path $InstallDir 'freenitial_yt_dlp_wrapper.bat'
    $wrapperText = "@echo off & cd /d %~dp0`r`n" + 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "freenitial_yt_dlp_script.ps1"' + "`r`n"
    [IO.File]::WriteAllText($wrapperPath, $wrapperText, (New-Object System.Text.ASCIIEncoding))
    Log "Generated wrapper: $wrapperPath"
    if (-not (Test-Path (Join-Path $InstallDir 'ext.crx')))                      { throw "ext.crx not found after deploy." }
    if (-not (Test-Path (Join-Path $InstallDir 'freenitial_yt_dlp_script.ps1'))) { throw "script.ps1 not found after deploy." }
}
catch { Log "ERROR (deploy): $($_.Exception.Message)"; Show-ErrorBox "Failed to deploy files:`n$($_.Exception.Message)`n`nLog: $script:LogFile"; return }

# ------------------------------------------------------------------ 5) generate the local update manifest
Step 68 'Génération du manifeste local…' 'Generating local manifest…'
try {
    $ver = Get-CrxVersion (Join-Path $InstallDir 'ext.crx'); if ([string]::IsNullOrWhiteSpace($ver)) { $ver = $ExtVersion }
    # Record the installed version so the native host can compare it against the latest GitHub tag.
    try { [IO.File]::WriteAllText((Join-Path $InstallDir 'version.txt'), [string]$ver, (New-Object System.Text.ASCIIEncoding)); Log "Wrote version.txt ($ver)" } catch { Log "version.txt write failed: $($_.Exception.Message)" }
    $updatesXml = "<?xml version='1.0' encoding='UTF-8'?>`r`n" +
                  "<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>`r`n" +
                  "  <app appid='$ExtId'>`r`n" +
                  "    <updatecheck codebase='http://127.0.0.1:$ServerPort/ext.crx' version='$ver' />`r`n" +
                  "  </app>`r`n</gupdate>`r`n"
    [IO.File]::WriteAllText((Join-Path $InstallDir 'updates.xml'), $updatesXml, (New-Object System.Text.UTF8Encoding($false)))
    Log "Generated updates.xml (version $ver)"
}
catch { Log "ERROR (updates.xml): $($_.Exception.Message)"; Show-ErrorBox "Failed to write updates.xml:`n$($_.Exception.Message)"; return }

# ------------------------------------------------------------------ 6) write the loopback server script
$serverScriptText = @'
param([string]$ExtId, [int]$Port, [string]$Dir, [string]$Detect, [string]$Version)
$ErrorActionPreference = 'SilentlyContinue'
$log = Join-Path $Dir 'Logs\localserver.log'
function SLog($m) { try { [IO.File]::AppendAllText($log, ('[{0}] {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m, [Environment]::NewLine)) } catch {} }
$globs = @($Detect -split ';' | Where-Object { $_ })
# "Done" = the TARGET version is on disk (a browser stores it as <id>\<version>_<n>).
# EVERY selected browser must have it (each $globs entry is one browser): stopping as
# soon as the FIRST browser installs would starve a slower one (its cache + prefs were
# already wiped, so it would end up with the extension gone entirely). We keep serving
# until all browsers have it, or the deadline below.
function Test-BrowserInstalled($g) { return ($Version -and (Test-Path (Join-Path (Join-Path $g $ExtId) ($Version + '_*')))) }
function Test-TargetInstalled {
    foreach ($g in $globs) { if (-not (Test-BrowserInstalled $g)) { return $false } }
    return ($globs.Count -gt 0)
}
if (Test-TargetInstalled) { SLog "Target version $Version already installed; server not needed."; return }
$crx = Join-Path $Dir 'ext.crx'; $xml = Join-Path $Dir 'updates.xml'
try { $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port); $listener.Start(); SLog "Listening on 127.0.0.1:$Port (serving until $Version is installed)" }
catch { SLog "Bind failed on ${Port}: $($_.Exception.Message)"; return }
$deadline = (Get-Date).AddMinutes(3)
try {
    while (-not (Test-TargetInstalled) -and (Get-Date) -lt $deadline) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 300; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 3000; $client.SendTimeout = 5000
            $ns = $client.GetStream(); $sr = New-Object System.IO.StreamReader($ns)
            $reqLine = $sr.ReadLine(); $reqPath = ''
            if ($reqLine -match '^GET\s+(\S+)') { $reqPath = $matches[1] }
            $bw = New-Object System.IO.BinaryWriter($ns)
            if ($reqPath -like '/updates.xml*' -and (Test-Path $xml)) {
                $body = [IO.File]::ReadAllBytes($xml)
                $bw.Write([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/xml`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")); $bw.Write($body)
            } elseif ($reqPath -like '/ext.crx*' -and (Test-Path $crx)) {
                $body = [IO.File]::ReadAllBytes($crx)
                $bw.Write([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/x-chrome-extension`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")); $bw.Write($body)
            } else { $bw.Write([Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")) }
            $bw.Flush(); SLog "Served $reqPath"
        } catch { SLog "Request error: $($_.Exception.Message)" } finally { $client.Close() }
    }
} finally { $listener.Stop(); SLog "Server stopped (installed=$(Test-TargetInstalled))." }
'@
$serverScript = Join-Path $InstallDir 'localserver.ps1'
[IO.File]::WriteAllText($serverScript, $serverScriptText, (New-Object System.Text.UTF8Encoding($false)))
Log "Wrote loopback server script."

# ------------------------------------------------------------------ 7) register + start the server task (detect across selected browsers)
Step 72 'Enregistrement du serveur local…' 'Registering local server…'
$detectArg = (($selected | ForEach-Object { $_.DetectGlob }) -join ';')
try {
    $taskArg  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$serverScript`" -ExtId $ExtId -Port $ServerPort -Dir `"$InstallDir`" -Detect `"$detectArg`" -Version $ver"
    $action   = New-ScheduledTaskAction  -Execute 'powershell.exe' -Argument $taskArg
    $trigger  = New-ScheduledTaskTrigger  -AtStartup
    $princ    = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $princ -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Log "Loopback server task registered + started."
}
catch {
    Log "Scheduled task failed ($($_.Exception.Message)); starting a one-shot hidden server."
    try { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$serverScript`"", '-ExtId', $ExtId, '-Port', "$ServerPort", '-Dir', "`"$InstallDir`"", '-Detect', "`"$detectArg`"", '-Version', "$ver") }
    catch { Log "ERROR: could not start loopback server: $($_.Exception.Message)"; Show-ErrorBox "Could not start the local extension server:`n$($_.Exception.Message)"; return }
}

# ------------------------------------------------------------------ 8) native host manifest (one file, registered per browser)
try {
    $hostJsonPath = Join-Path $InstallDir "$HostName.json"
    $escPath = $wrapperPath -replace '\\', '\\\\'
    $hostJson = @"
{
  "name": "$HostName",
  "description": "Download with yt-dlp",
  "path": "$escPath",
  "type": "stdio",
  "allowed_origins": [ "chrome-extension://$ExtId/" ]
}
"@
    [IO.File]::WriteAllText($hostJsonPath, $hostJson, (New-Object System.Text.UTF8Encoding($false)))
    Log "Wrote native host manifest."
}
catch { Log "ERROR (host manifest): $($_.Exception.Message)"; Show-ErrorBox "Failed to write native host manifest:`n$($_.Exception.Message)"; return }

# ------------------------------------------------------------------ 9) fake-MDM management gate (shared, once)
Step 78 'Activation de la gestion locale…' 'Enabling local management…'
try {
    $guid  = 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF'
    $enr   = "HKLM:\SOFTWARE\Microsoft\Enrollments\$guid"
    $omadm = "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\$guid"
    if (-not (Test-Path $enr)) { New-Item -Path $enr -Force | Out-Null }
    Set-ItemProperty -Path $enr -Name 'EnrollmentState' -Value 1 -Type DWord
    Set-ItemProperty -Path $enr -Name 'EnrollmentType'  -Value 0 -Type DWord
    Set-ItemProperty -Path $enr -Name 'IsFederated'     -Value 0 -Type DWord
    Set-ItemProperty -Path $enr -Name 'UPN' -Value 'user@Fake-MDM-Provider.local' -Type String
    if (-not (Test-Path $omadm)) { New-Item -Path $omadm -Force | Out-Null }
    Set-ItemProperty -Path $omadm -Name 'Flags'        -Value 0x00d6fb7f -Type DWord
    Set-ItemProperty -Path $omadm -Name 'AcctUId'      -Value '0x000000000000000000000000000000000000000000000000000000000000000000000000' -Type String
    Set-ItemProperty -Path $omadm -Name 'RoamingCount' -Value 0 -Type DWord
    Set-ItemProperty -Path $omadm -Name 'SslClientCertReference' -Value 'MY;User;0000000000000000000000000000000000000000' -Type String
    Set-ItemProperty -Path $omadm -Name 'ProtoVer'     -Value '1.2' -Type String
    Log "Applied fake-MDM enrollment."
}
catch { Log "ERROR (fake-MDM): $($_.Exception.Message)"; Show-ErrorBox "Failed to write the MDM management keys:`n$($_.Exception.Message)"; return }

# ------------------------------------------------------------------ 10) per-browser policy + native host
Step 82 'Application des stratégies navigateur…' 'Applying browser policies…'
try {
    foreach ($b in $selected) {
        $method = Apply-BrowserPolicy -Browser $b -Id $ExtId -Url $UpdateUrl -Mode $InstallMode
        Register-NativeHost -Browser $b -HostJsonPath $hostJsonPath
        Log "$($b.Name): policy via $method ; native host registered."
    }
}
catch { Log "ERROR (policy/host): $($_.Exception.Message)"; Show-ErrorBox "Failed to write policy / host registration:`n$($_.Exception.Message)`n`nLog: $script:LogFile"; return }

# ------------------------------------------------------------------ 11) force a CLEAN reinstall, then (re)launch
# Deterministic update path (order matters, this is what makes an UPDATE actually apply):
#   stop the server task -> close browsers -> delete the cached extension copy ->
#   (re)start the server (now it sees the TARGET version is not on disk and serves the CRX) ->
#   require a real HTTP 200 from it -> relaunch. Works whether the version changed or not;
#   the server self-terminates as soon as the target version lands (<=3 min cap, no lingering).
Log "Setup completed successfully."
$NL = [Environment]::NewLine
$running = @($selected | Where-Object { Get-BrowserProcs $_ })

if ($running.Count -gt 0) {
    $sep = if ($Fr) { ' et ' } else { ' and ' }
    $rnames = ($running | ForEach-Object { $_.Name }) -join $sep
    if (-not $script:Silent) {
        Hide-ProgressBar                                 # popup on screen -> bar steps aside
        $msg = if ($Fr) { "Cliquez sur OK pour redemarrer $rnames et appliquer la mise a jour." } else { "Click OK to restart $rnames and apply the update." }
        [void][System.Windows.Forms.MessageBox]::Show($msg, '', [System.Windows.Forms.MessageBoxButtons]::OK)
        Show-ProgressBar                                 # work continues -> bar comes back
    }
}

# 1) Stop any server instance started at step 7 (it may still hold the port); we must (re)start
#    it AFTER the cache is cleared so a fresh instance sees "target not installed" and serves.
Step 86 'Redémarrage du navigateur…' 'Restarting the browser…'
try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
# 2) Close browsers so their on-disk copy of the extension unlocks.
foreach ($b in $selected) { Close-BrowserGracefully $b }
# 3) Drop the installed copy (all profiles) AND clear the browser's remembered
#    version, so the reinstall applies regardless of version (upgrade, same, or downgrade).
Step 90 "Purge de l'ancienne copie…" 'Purging the old copy…'
foreach ($b in $selected) { Remove-CachedExtension -B $b -Id $ExtId; Clear-ExtensionPrefState -B $b -Id $ExtId }
# 4) (Re)start the server; it now serves the fresh CRX until the TARGET version lands on disk.
Step 93 'Démarrage du serveur local…' 'Starting local server…'
try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
catch {
    Log "Could not (re)start server task ($($_.Exception.Message)); starting a one-shot hidden server."
    try { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$serverScript`"", '-ExtId', $ExtId, '-Port', "$ServerPort", '-Dir', "`"$InstallDir`"", '-Detect', "`"$detectArg`"", '-Version', "$ver") } catch { Log "One-shot server failed: $($_.Exception.Message)" }
}
# 5) Require a real HTTP 200 from the server before relaunching (not just an open port).
if (Wait-HttpReady -Port $ServerPort -Path '/updates.xml' -TimeoutMs 8000) { Log "Loopback server confirmed serving on port $ServerPort." }
else { Log "WARN: loopback server did not confirm HTTP readiness; Chrome will still pick it up on its own update schedule (server serves up to 3 min)." }
# 6) Relaunch -> Chrome reinstalls the new code from the loopback.
Step 98 'Relance du navigateur…' 'Relaunching the browser…'
foreach ($b in $selected) { Start-BrowserDeElevated $b.ExePath }
$allNames = ($selected | ForEach-Object { $_.Name }) -join ', '
Log "Forced clean reinstall; relaunched: $allNames"
Step 100 'Terminé.' 'Done.'

if ($running.Count -eq 0) {
    $t1 = if ($Fr) { 'Installation terminee.' } else { 'Setup complete.' }
    $t2 = if ($Fr) { "Le navigateur va s'ouvrir pour appliquer la mise a jour." } else { 'The browser will open to apply the update.' }
    $modeNote = ''
    if ($InstallMode -eq 'normal_installed') { $modeNote = if ($Fr) { 'Vous pouvez la desactiver/supprimer a tout moment.' } else { 'You can disable/remove it anytime.' } }
    Show-InfoBox ($t1 + $NL + $NL + $allNames + $NL + $t2 + $NL + $modeNote + $NL + "Log: $script:LogFile")
}
Close-ProgressBar   # end of the run (also covers the silent / browsers-were-running paths)
