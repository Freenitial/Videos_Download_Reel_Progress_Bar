#-------------------------- 
# Utility Functions 
#-------------------------- 
function Remove-OldFiles { 
    param ( 
        [string]$Path, 
        [string]$Pattern, 
        [int]$MaxCount = 10 
    ) 
    $files = Get-ChildItem -Path $Path -Filter $Pattern | Sort-Object LastWriteTime 
    if ($files.Count -gt $MaxCount) { 
        $filesToDelete = $files | Select-Object -First ($files.Count - $MaxCount) 
        foreach ($file in $filesToDelete) { 
            Remove-Item $file.FullName -Force 
        } 
    } 
} 
 
function Log { 
    param ([string]$message) 
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff") 
    "$timestamp - $message" | Out-File -FilePath $scriptLogFile -Append -Encoding UTF8 
} 
 
function Send-NativeMessage {
    param ([PSObject]$Message)
    $out = [Console]::OpenStandardOutput()
    $json = [Text.Encoding]::UTF8.GetBytes(($Message | ConvertTo-Json -Compress -Depth 1))
    $length = $json.Length
    $lengthBytes = [byte[]]::new(4)
    $lengthBytes[0] = $length -band 0xFF
    $lengthBytes[1] = ($length -shr 8) -band 0xFF
    $lengthBytes[2] = ($length -shr 16) -band 0xFF
    $lengthBytes[3] = ($length -shr 24) -band 0xFF
    $out.Write($lengthBytes, 0, 4)
    $out.Write($json, 0, $json.Length)
    $out.Flush()
}

 
#-------------------------- 
# Initialization 
#-------------------------- 
$currentDate = Get-Date -Format "ddMMyyyy" 
$basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } 
$ytDlpPathEXE = Join-Path $basePath "yt-dlp.exe" 
 
$logsDirectory = Join-Path $basePath "Logs" 
if (-Not (Test-Path $logsDirectory)) { New-Item -ItemType Directory -Path $logsDirectory | Out-Null } 
$scriptLogFile  = Join-Path $logsDirectory "script-ps1_$currentDate.log" 
if (Test-Path $scriptLogFile) { Add-Content -Path $scriptLogFile -Value "`n--------`n" } 
 
#-------------------------- 
# Reading Standard Input 
#-------------------------- 
try { 
    $stdin = [Console]::OpenStandardInput() 
    $lengthBytes = New-Object byte[] 4 
    if ($stdin.Read($lengthBytes, 0, 4) -ne 4) { throw "Invalid length header" } 
     
    $messageLength = [System.BitConverter]::ToInt32($lengthBytes, 0) 
    $inputBytes = New-Object byte[] $messageLength 
    $stdin.Read($inputBytes, 0, $messageLength) | Out-Null 
    $inputJson = [System.Text.Encoding]::UTF8.GetString($inputBytes) 
    $inputData = $inputJson | ConvertFrom-Json 
     
    if ($inputData.URL) { 
        $url = $inputData.URL
        Log "Input URL = $url" 
    }
    elseif ($inputData.SHOW) {
        $fileToShow = $inputData.SHOW
        Log "File to show = $fileToShow"
    }
    elseif ($inputData.COPY) {
        $fileToCopy = $inputData.COPY
        Log "File to copy = $fileToCopy"
    }
    else {
        throw "No valid parameter provided."
    }
} 
catch { 
    Log "Input read error: $_" 
    Send-NativeMessage @{ success = $false; message = "Input error: $_" } 
    exit 
} 

 
#-------------------------- 
# Process According to Scenario (Download, Show in explorer, Copy in clipboard)
#-------------------------- 
if ($inputData.URL) {
    $uuid = [guid]::NewGuid().ToString().Substring(0,17)
    Log "Generated UUID: $uuid"
    
    Log "Job: retrieving title for URL: $url"
    $job_title = Start-Job -ScriptBlock { 
        param($exe, $url, $logFile)
        & $exe --get-title $url 2>> $logFile 
    } -ArgumentList $ytDlpPathEXE, $url, $scriptLogFile
    Log "Started job for title retrieval"
    
    if ($inputData.downloadDir) { 
        $downloadDir = $inputData.downloadDir 
        if (-Not (Test-Path $downloadDir)) { 
            Log "Download path '$downloadDir' is invalid." 
            Send-NativeMessage @{ success = $false; message = "Invalid download path: $downloadDir" } 
            exit 
        } 
    } else { $downloadDir = Join-Path $env:userprofile "Downloads" }
    if ($inputData.isGIF) { $tempFilePath = Join-Path $downloadDir "$uuid.gif" }
    elseif ($inputData.mp3) { $tempFilePath = Join-Path $downloadDir "$uuid.mp3" }
    elseif ($inputData.convertMP4) { $tempFilePath = Join-Path $downloadDir "$uuid.mp4" }
    else { $tempFilePath = Join-Path $downloadDir "$uuid.%(ext)s" }
    Log "Temporary file path set to: $tempFilePath"
    
    try {
        $arguments = @("--no-playlist", "--console-title", "--no-mtime", "--output `"$tempFilePath`"", "`"$url`"")
        if ($inputData.cut) { $arguments += @("--download-sections $($inputData.cut)", "--force-keyframes-at-cuts") }
        if ($inputData.useChromeCookies) { $arguments += @("--cookies-from-browser chrome") }
        if ($inputData.mp3) { $arguments += @("-x", "--audio-format mp3", "--audio-quality 0") } elseif ($inputData.convertMP4) { $arguments += @("--recode-video mp4") }
        if ($inputData.isGIF) { $arguments += @("--recode-video gif") }
        Log "Starting download process with arguments: $arguments"
        $process = Start-Process -FilePath $ytDlpPathEXE -ArgumentList $arguments -Wait -PassThru
        Log "Download process exited with code: $($process.ExitCode)"
    
        if ($process.ExitCode -eq 0) {
            $downloaded_path = (Get-ChildItem -Path $downloadDir | Where-Object { $_.BaseName -eq $uuid } | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
            Log "Downloaded file path identified: $downloaded_path"
            if ((Get-Job -Id $job_title.Id).State -eq "Completed") {
                Log "Title retrieval job completed successfully"
                $jobResult = (Receive-Job -Job $job_title 2>&1 | Out-String).Trim()
                Log "Job result: $jobResult"
                if ([string]::IsNullOrWhiteSpace($jobResult)) { 
                    $tempTitle = $uuid
                    Log "Job returned null or empty title, using UUID as tempTitle: $tempTitle"
                } else { 
                    $tempTitle = $jobResult.Trim()
                    Log "Job returned valid title: $tempTitle"
                }
            } else {
                Stop-Job -Job $job_title -Force 2>&1 | Out-Null
                Log "Job did not complete in time, stopped forcefully. Using UUID as tempTitle"
                $tempTitle = $uuid
            }
            if ($tempTitle -eq $uuid) { 
                $sanitized_title = $uuid.Substring(0,17)
                Log "Using UUID as sanitized title: $sanitized_title"
            } else {
                $sanitized_title = $tempTitle.Trim()
                $sanitized_title = [regex]::Replace($sanitized_title, '[^\p{L}\p{N}\s-]', '')
                if ($sanitized_title.Length -gt 35) { 
                    $sanitized_title = $sanitized_title.Substring(0,35).Trim()
                    Log "Sanitized title truncated to 35 characters: $sanitized_title"
                } elseif ($sanitized_title.Length -lt 5) { 
                    $sanitized_title = $uuid.Substring(0,17)
                    Log "Sanitized title too short, using UUID instead: $sanitized_title"
                } else {
                    Log "Sanitized title: $sanitized_title"
                }
            }
            $ext = [IO.Path]::GetExtension($downloaded_path)
            Log "Detected file extension: $ext"
            $newFileName = "$sanitized_title$ext"
            $destination = Join-Path $downloadDir $newFileName
            if ($tempTitle -ne $uuid) { 
                if (Test-Path $destination) { 
                    Remove-Item $destination -Force 
                    Log "Existing file at destination removed: $destination"
                }
                Rename-Item -Path $downloaded_path -NewName $newFileName
                Log "Renamed file from $downloaded_path to $destination"
            }
            $newFile = Get-Item -Path $destination
    
            if ($inputData.copyAtEnd) { 
                try {
                    $fileToCopy = $newFile.FullName
                    Log "Copying file: $fileToCopy"
                    Add-Type -AssemblyName System.Windows.Forms
                    $stringCollection = New-Object System.Collections.Specialized.StringCollection
                    $stringCollection.Add($fileToCopy)
                    [System.Windows.Forms.Clipboard]::SetFileDropList($stringCollection)
                    Log "File copied to clipboard: $fileToCopy"
                } catch { Log "Failed to copy file at end" }
            }
            Send-NativeMessage @{ success = $true; finalPath = $newFile.FullName }
            if ($inputData.bipAtEnd) {
                try { 
                    (New-Object Media.SoundPlayer "C:\Windows\Media\notify.wav").PlaySync()
                    Log "Bip sound played"
                } catch { Log "Failed to play bip sound 'C:\Windows\Media\notify.wav'" }
            }
        } else {
            Log "yt-dlp failed with exit code $($process.ExitCode)."
            Send-NativeMessage @{ success = $false; message = "yt-dlp failed with exit code $($process.ExitCode)." }
        }
    } catch {
        Log "Error executing yt-dlp: $_"
        Send-NativeMessage @{ success = $false; message = "Error executing yt-dlp: $_" }
    }
}
elseif ($inputData.SHOW) {
    try {
        Log "Showing file: $fileToShow"
        $folder = Split-Path $fileToShow -Parent
        $fileName = Split-Path $fileToShow -Leaf
        $folderUrl = "file:///" + ($folder -replace '\\','/')
        $foundExplorer = $false
        $shellApp = New-Object -ComObject Shell.Application
        foreach ($window in $shellApp.Windows()) {
            if ($window.LocationURL -and ($window.LocationURL -like "$folderUrl*")) {
                Log "Explorer window found for folder: $folder"
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@ -ErrorAction Stop
                $hwnd = New-Object System.IntPtr $window.HWND
                if ([Win32]::IsIconic($hwnd)) {
                    [Win32]::ShowWindow($hwnd, 9)
                    Log "Explorer window was minimized and has been restored: $folder"
                }
                [Win32]::SetForegroundWindow($hwnd)
                Log "Explorer window brought to foreground: $folder"
                Add-Type -AssemblyName System.Windows.Forms
                [System.Windows.Forms.SendKeys]::SendWait("{F5}")
                Log "Explorer window refreshed via F5"
                Start-Sleep -Milliseconds 600
                $folderView = $window.Document
                $folderObj = $folderView.Folder
                $item = $folderObj.ParseName($fileName)
                if ($null -ne $item) {
                    $folderView.SelectItem($item, 8)
                    $folderView.SelectItem($item, 1)
                    Log "File exclusively selected: $fileToShow in folder: $folder"
                }
                else { 
                    Log "Could not select file: $fileToShow in folder: $folder" 
                }
                $foundExplorer = $true
                break
            }
        }
        if (-not $foundExplorer) {
            explorer.exe /select,""$fileToShow""
            Log "Opened new explorer window for: $fileToShow"
        }
        Send-NativeMessage @{ success = $true; message = "File showed: $fileToShow" }
    }
    catch {
        Log "Error showing file: $_"
        Send-NativeMessage @{ success = $false; message = "Error showing file: $_" }
    }
}
elseif ($inputData.COPY) {
    try {
        Log "Copying file: $fileToCopy"
        Add-Type -AssemblyName System.Windows.Forms
        $stringCollection = New-Object System.Collections.Specialized.StringCollection
        $stringCollection.Add($fileToCopy)
        [System.Windows.Forms.Clipboard]::SetFileDropList($stringCollection)
        Log "File copied to clipboard: $fileToCopy"
        Send-NativeMessage @{ success = $true }
    }
    catch {
        Log "Error copying file: $_"
        Send-NativeMessage @{ success = $false; message = "Error copying file: $_" }
    }
}
