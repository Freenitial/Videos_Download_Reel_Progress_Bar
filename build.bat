<# :
    @echo off & Title Videos Download - Build

    rem ===== Ensure PowerShell 7 is available (SIDE-BY-SIDE install) =====
    rem  PowerShell 7 installs as pwsh.exe under "%ProgramFiles%\PowerShell\7\" and NEVER replaces
    rem  Windows PowerShell 5.1 (powershell.exe in System32\WindowsPowerShell\v1.0). The default
    rem  "powershell" command is left untouched. Nothing here overwrites or removes 5.1.
    set "pwsh7="
    for %%P in (pwsh.exe) do if not defined pwsh7 set "pwsh7=%%~$PATH:P"
    if not defined pwsh7 if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "pwsh7=%ProgramFiles%\PowerShell\7\pwsh.exe"

    rem NB: goto/labels here instead of "if (...)" blocks on purpose. Parenthesised
    rem cmd blocks that contain "()" "{}" or \"-escaped quotes (as the install
    rem fallbacks below do) break cmd's parser ("} was unexpected at this time").
    if defined pwsh7 goto :pwsh7_ready
    echo Installing PowerShell 7 side-by-side; Windows PowerShell 5.1 is left untouched...
    where winget >nul 2>&1 && winget install --id Microsoft.PowerShell --source winget --silent --accept-source-agreements --accept-package-agreements
    if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "pwsh7=%ProgramFiles%\PowerShell\7\pwsh.exe"
    if defined pwsh7 goto :pwsh7_ready
    echo winget unavailable; using Microsoft install script...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $(irm https://aka.ms/install-powershell.ps1) } -UseMSI -Quiet"
    if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "pwsh7=%ProgramFiles%\PowerShell\7\pwsh.exe"
    if defined pwsh7 goto :pwsh7_ready
    echo [ERROR] Could not find or install PowerShell 7. & pause & exit /b 1
    :pwsh7_ready

    rem ===== Launch pwsh 7 with a native Win32 progress popup, then run this file's body =====
    "%pwsh7%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -Window Hidden -Command ^
        "$M=[Runtime.InteropServices.Marshal];" ^
        "$d=[Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(" ^
        "(New-Object Reflection.AssemblyName('W')),[Reflection.Emit.AssemblyBuilderAccess]::Run).DefineDynamicModule('W');" ^
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
        "$hw=$A::CreateWindowExW(9,'#32770','Videos Download - Build',0x10C00000," ^
        "[int](($sw-440)/2),[int](($sh-130)/2),440,130," ^
        "[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero);" ^
        "$null=$A::ShowWindow($hw,5);" ^
        "$pc=$M::AllocHGlobal(8);$M::WriteInt32($pc,0,8);$M::WriteInt32($pc,4,0x20);" ^
        "$null=$A::InitCommonControlsEx($pc);$M::FreeHGlobal($pc);" ^
        "$ft=$A::GetStockObject(17);" ^
        "$hl=$A::CreateWindowExW(0,'Static','Preparing build...',0x50000000," ^
        "20,15,390,20,$hw,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero);" ^
        "$null=$A::SendMessageW($hl,0x30,$ft,[IntPtr]::Zero);" ^
        "$hb=$A::CreateWindowExW(0,'msctls_progress32','',0x50000000," ^
        "20,42,390,24,$hw,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero);" ^
        "$batFile='%~f0';& ([ScriptBlock]::Create([IO.File]::ReadAllText('%~f0')))"
    exit /b
#>

# =============================================================================
#  PowerShell 7 BODY -- builds the signed CRX3 with a live Win32 progress bar.
#  Runs under pwsh 7 (needs .NET crypto APIs). No chrome.exe is launched.
# =============================================================================
$ErrorActionPreference = 'Stop'

# ---- second P/Invoke type + loading-popup helpers (pump keeps the bar responsive) ----
$t = $d.DefineType('E', 'Public,Class')
foreach ($x in @(
    , @('SetWindowTextW', 'user32.dll', ([Bool]), @([IntPtr], [String]))
    , @('DestroyWindow', 'user32.dll', ([Bool]), @([IntPtr]))
    , @('PeekMessageW', 'user32.dll', ([Bool]), @([IntPtr], [IntPtr], [UInt32], [UInt32], [UInt32]))
    , @('TranslateMessage', 'user32.dll', ([Bool]), @([IntPtr]))
    , @('DispatchMessageW', 'user32.dll', ([IntPtr]), @([IntPtr]))
)) { $z = $t.DefinePInvokeMethod($x[0], $x[1], 'Public,Static,PinvokeImpl', 'Standard', $x[2], $x[3], 'Winapi', 'Unicode'); $z.SetImplementationFlags($z.GetMethodImplementationFlags() -bor 128) }
$E = $t.CreateType()
$mg = $M::AllocHGlobal(48)
function Invoke-LoadingPump { try { while ($E::PeekMessageW($mg, [IntPtr]::Zero, 0, 0, 1)) { $null = $E::TranslateMessage($mg); $null = $E::DispatchMessageW($mg) } } catch {} }
function Update-LoadingPopup([int]$pct, [string]$s) { $null = $A::SendMessageW($hb, 0x402, [IntPtr]$pct, [IntPtr]::Zero); if ($s) { $null = $E::SetWindowTextW($hl, $s) }; try { Invoke-LoadingPump } catch {} }
function Close-LoadingPopup { $null = $E::DestroyWindow($hw); try { Invoke-LoadingPump } catch {}; $M::FreeHGlobal($mg) }

function Show-Result([string]$Title, [string]$Msg, [string]$Icon) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($Msg, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::$Icon)
}

# ---- config (derived from where this .bat lives) ----
$scriptDir = Split-Path -Parent $batFile
$SrcDir    = $scriptDir
$OutDir    = Join-Path $scriptDir 'dist'
$KeyPath   = Join-Path $scriptDir '_signing\videos-download.pem'   # SECRET - travels with the folder so ANY machine rebuilds the SAME extension ID. Keep the folder private; never publish _signing\.
$UpdateUrl = 'http://127.0.0.1:47653/updates.xml'
$CrxUrl    = 'http://127.0.0.1:47653/ext.crx'
$HostName  = 'freenitial_yt_dlp_host'

# ---- CRX3 protobuf helpers ----
function Get-Varint { param([uint64]$Value) $bytes = [System.Collections.Generic.List[byte]]::new(); while ($Value -ge 0x80) { $bytes.Add([byte](($Value -band 0x7F) -bor 0x80)); $Value = $Value -shr 7 }; $bytes.Add([byte]$Value); , $bytes.ToArray() }
function Get-PbField { param([int]$FieldNumber, [byte[]]$Data) $tag = ([uint64]$FieldNumber -shl 3) -bor 2; $out = [System.Collections.Generic.List[byte]]::new(); $out.AddRange([byte[]](Get-Varint $tag)); $out.AddRange([byte[]](Get-Varint ([uint64]$Data.Length))); $out.AddRange($Data); , $out.ToArray() }
function Join-Bytes { param([byte[][]]$Arrays) $list = [System.Collections.Generic.List[byte]]::new(); foreach ($a in $Arrays) { $list.AddRange($a) }; , $list.ToArray() }

try {
    # ---------------------------------------------------------------- validate
    Update-LoadingPopup 5 "Validating inputs..."
    $srcManifest = Join-Path $SrcDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $srcManifest)) { throw "manifest.json not found in $SrcDir" }
    $extFiles = @('manifest.json', 'content.js', 'background.js')
    foreach ($f in $extFiles) { if (-not (Test-Path -LiteralPath (Join-Path $SrcDir $f))) { throw "Required extension file missing: $f" } }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    # ---------------------------------------------------------------- keypair
    Update-LoadingPopup 20 "Loading signing key..."
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $newKeyGenerated = $false
    if (Test-Path -LiteralPath $KeyPath) {
        $der = [Convert]::FromBase64String((((Get-Content -LiteralPath $KeyPath -Raw) -replace '-----[^-]+-----', '') -replace '\s', ''))
        $read = 0; $rsa.ImportPkcs8PrivateKey($der, [ref]$read)
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $KeyPath) | Out-Null
        $der = $rsa.ExportPkcs8PrivateKey(); $b64 = [Convert]::ToBase64String($der)
        $lines = for ($i = 0; $i -lt $b64.Length; $i += 64) { $b64.Substring($i, [Math]::Min(64, $b64.Length - $i)) }
        [IO.File]::WriteAllText($KeyPath, "-----BEGIN PRIVATE KEY-----`n" + ($lines -join "`n") + "`n-----END PRIVATE KEY-----`n")
        $newKeyGenerated = $true
    }

    # ---------------------------------------------------------------- deterministic ID + key field
    Update-LoadingPopup 40 "Computing extension ID..."
    $spki     = $rsa.ExportSubjectPublicKeyInfo()
    $keyField = [Convert]::ToBase64String($spki)
    $hash     = [System.Security.Cryptography.SHA256]::Create().ComputeHash($spki)
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt 16; $i++) { $byte = $hash[$i]; [void]$sb.Append([char](97 + ($byte -shr 4))); [void]$sb.Append([char](97 + ($byte -band 0x0F))) }
    $extId = $sb.ToString()

    # Safety net: the ID derives from the KEY. If _signing\ was missing, a fresh key
    # was silently generated above -> DIFFERENT extension ID -> setup.bat's hardcoded
    # $ExtId, the native-host allowed_origins and every existing install no longer
    # match. Warn loudly instead of shipping a broken package.
    $setupPath = Join-Path $SrcDir 'setup.bat'
    if (Test-Path -LiteralPath $setupPath) {
        $idMatch = [regex]::Match([IO.File]::ReadAllText($setupPath), "\$ExtId\s*=\s*'([a-p]{32})'")
        if ($idMatch.Success -and $idMatch.Groups[1].Value -ne $extId) {
            Show-Result 'Videos Download - Build WARNING' (
                "This signing key produces extension ID:" + [Environment]::NewLine + $extId + [Environment]::NewLine + [Environment]::NewLine +
                "but setup.bat expects:" + [Environment]::NewLine + $idMatch.Groups[1].Value + [Environment]::NewLine + [Environment]::NewLine +
                $(if ($newKeyGenerated) { "A NEW key was just generated because _signing\ was missing. Restore the ORIGINAL videos-download.pem (private backup) to keep the same extension ID, or update `$ExtId in setup.bat - but existing installs will then see a DIFFERENT extension." }
                  else { "Restore the correct videos-download.pem, or update `$ExtId in setup.bat to match." })
            ) 'Warning'
        }
    }

    $srcJson = Get-Content -LiteralPath $srcManifest -Raw | ConvertFrom-Json
    if ($srcJson.PSObject.Properties['key']) { $srcJson.key = $keyField } else { $srcJson | Add-Member -NotePropertyName key -NotePropertyValue $keyField }
    [IO.File]::WriteAllText($srcManifest, ($srcJson | ConvertTo-Json -Depth 50))
    $extVersion = [string]$srcJson.version
    if ([string]::IsNullOrWhiteSpace($extVersion)) { throw "manifest.json has no 'version'." }

    # ---------------------------------------------------------------- stage
    Update-LoadingPopup 55 "Staging extension files..."
    $staging = Join-Path $OutDir 'staging'
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    foreach ($f in $extFiles) { Copy-Item -LiteralPath (Join-Path $SrcDir $f) -Destination (Join-Path $staging $f) -Force }
    if (Test-Path -LiteralPath (Join-Path $SrcDir 'icons')) { Copy-Item -LiteralPath (Join-Path $SrcDir 'icons') -Destination (Join-Path $staging 'icons') -Recurse -Force }
    $stageManifestPath = Join-Path $staging 'manifest.json'
    $stageJson = Get-Content -LiteralPath $stageManifestPath -Raw | ConvertFrom-Json
    if ($stageJson.PSObject.Properties['update_url']) { $stageJson.update_url = $UpdateUrl } else { $stageJson | Add-Member -NotePropertyName update_url -NotePropertyValue $UpdateUrl }
    [IO.File]::WriteAllText($stageManifestPath, ($stageJson | ConvertTo-Json -Depth 50))

    # ---------------------------------------------------------------- pack CRX3 (managed, no Chrome)
    Update-LoadingPopup 70 "Packing CRX3..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $OutDir 'ext.zip'
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    $zipBytes = [IO.File]::ReadAllBytes($zipPath)

    $crxId      = [byte[]]($hash[0..15])
    $signedData = Get-PbField 1 $crxId
    $payload = [System.Collections.Generic.List[byte]]::new()
    $payload.AddRange([System.Text.Encoding]::ASCII.GetBytes('CRX3 SignedData')); $payload.Add(0)
    $payload.AddRange([BitConverter]::GetBytes([uint32]$signedData.Length))
    $payload.AddRange($signedData); $payload.AddRange($zipBytes)
    $signature = $rsa.SignData($payload.ToArray(), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

    $proof  = Join-Bytes @((Get-PbField 1 $spki), (Get-PbField 2 $signature))
    $header = Join-Bytes @((Get-PbField 2 $proof), (Get-PbField 10000 $signedData))
    $crx = [System.Collections.Generic.List[byte]]::new()
    $crx.AddRange([System.Text.Encoding]::ASCII.GetBytes('Cr24'))
    $crx.AddRange([BitConverter]::GetBytes([uint32]3))
    $crx.AddRange([BitConverter]::GetBytes([uint32]$header.Length))
    $crx.AddRange($header); $crx.AddRange($zipBytes)
    $crxPath = Join-Path $OutDir 'ext.crx'
    [IO.File]::WriteAllBytes($crxPath, $crx.ToArray())
    Remove-Item -LiteralPath $zipPath -Force
    Remove-Item -LiteralPath $staging -Recurse -Force

    # ---------------------------------------------------------------- ship copy + cleanup
    # dist\ is only a build WORKSPACE: the single deliverable is ext.crx next to
    # setup.bat (updates.xml is regenerated by setup.bat at install time anyway).
    Update-LoadingPopup 92 "Placing ext.crx next to setup.bat..."
    Move-Item -LiteralPath $crxPath -Destination (Join-Path $scriptDir 'ext.crx') -Force   # so an offline setup.bat run copies it
    Remove-Item -LiteralPath $OutDir -Recurse -Force -ErrorAction SilentlyContinue

    Update-LoadingPopup 100 "Done"
    Start-Sleep -Milliseconds 350
    Close-LoadingPopup

    Show-Result 'Videos Download - Build' (
        "Build OK." + [Environment]::NewLine + [Environment]::NewLine +
        "Extension ID:" + [Environment]::NewLine + $extId + [Environment]::NewLine + [Environment]::NewLine +
        "ext.crx written to:" + [Environment]::NewLine +
        " - " + (Join-Path $scriptDir 'ext.crx') + " (next to setup.bat)" + [Environment]::NewLine + [Environment]::NewLine +
        "Secret key (never ship): " + $KeyPath
    ) 'Information'
}
catch {
    try { Close-LoadingPopup } catch {}
    Show-Result 'Videos Download - Build error' ("Build failed:" + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message) 'Error'
    exit 1
}
