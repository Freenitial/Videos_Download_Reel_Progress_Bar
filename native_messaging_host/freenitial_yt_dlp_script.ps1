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
        foreach ($file in $filesToDelete) { Remove-Item $file.FullName -Force } 
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
$localPath = $MyInvocation.MyCommand.Path
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
if ($args.Count -gt 0 -and (Test-Path $args[0])) {
    $inputData = Get-Content -Path $args[0] -Raw | ConvertFrom-Json
    Remove-Item -Path $args[0] -Force
}
else {
    try { 
        $stdin = [Console]::OpenStandardInput() 
        $lengthBytes = New-Object byte[] 4 
        if ($stdin.Read($lengthBytes, 0, 4) -ne 4) { throw "Invalid length header" } 
        $messageLength = [System.BitConverter]::ToInt32($lengthBytes, 0) 
        $inputBytes = New-Object byte[] $messageLength 
        $stdin.Read($inputBytes, 0, $messageLength) | Out-Null 
        $inputJson = [System.Text.Encoding]::UTF8.GetString($inputBytes) 
        $inputData = $inputJson | ConvertFrom-Json
    } 
    catch { 
        Log "Error input read : $_" 
        Send-NativeMessage @{ success = $false; message = "Error input : $_" } 
        exit 
    }
}
if ($inputData.URL) { $url = $inputData.URL; Log "Input URL = $url" }
elseif ($inputData.SHOW) { $fileToShow = $inputData.SHOW; Log "File to show = $fileToShow" }
elseif ($inputData.COPY) { $fileToCopy = $inputData.COPY; Log "File to copy = $fileToCopy" }
else { throw "No valid parameter provided." }


#--------------------------
# Updates Checks
#--------------------------
$lastUpdateFile = Join-Path $basePath "lastupdate.txt"
if (Test-Path $lastUpdateFile) {
    $elapsedHours = (Get-Date) - (Get-Item $lastUpdateFile).LastWriteTime
    if ($elapsedHours.TotalHours -ge 4) { Log "Last update was over 4 hours ago ($([math]::Round($elapsedHours.TotalHours,2)) hours elapsed). Update needed." }
    else { Log "Last update was within 4 hours ($([math]::Round($elapsedHours.TotalHours,2)) hours elapsed). No update needed." }
}
else {
    Log "lastupdate.txt not found. Update needed."
    Set-Content -Path $lastUpdateFile -Value $(Get-Date) -Encoding UTF8
    Log "Updated lastupdate.txt"
    # YT-DLP
    try {
        Log "Self updating yt-dlp"
        $updateArgs = @("--update")
        $updateProcess = Start-Process -FilePath $ytDlpPathEXE -ArgumentList $updateArgs -WindowStyle Hidden -Wait -PassThru
        Log "yt-dlp self-update attempted. ExitCode: $($updateProcess.ExitCode)"
    } 
    catch { Log "yt-dlp self-update failed : $_" }
    # PS1
    try {
        $release = Invoke-RestMethod "https://api.github.com/repos/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest"
        $asset = $release.assets | Where-Object { $_.name -eq "freenitial_yt_dlp_script.ps1" }
        $onlineDate = [datetime]$asset.updated_at
        $localDate = (Get-Item $localPath).LastWriteTime.ToUniversalTime()
        if ($onlineDate -gt $localDate) {
            Log "Self updating PS1"
            $tempNewScript = "temp_updated_script.ps1"
            Invoke-WebRequest "https://github.com/Freenitial/Videos_Download_Reel_Progress_Bar/releases/latest/download/freenitial_yt_dlp_script.ps1" -OutFile $tempNewScript
            Start-Sleep -Seconds 1
            $tempNativeMessage = "temp_native_message.json"
            $inputData | ConvertTo-Json -Compress | Out-File -FilePath $tempNativeMessage -Encoding UTF8
            Copy-Item -Path $tempNewScript -Destination $localPath -Force | Out-Null
            Log "PS1 update end, relaunching with saved native message from $tempNativeMessage"
            & "$localPath" "$tempNativeMessage"
            Exit
        } 
        else { Log "No PS1 update needed" }
    }
    catch { Log "Error while updating PS1: $_" }
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
    } 
    else { $downloadDir = Join-Path $env:userprofile "Downloads" }

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
                if ([string]::IsNullOrWhiteSpace($jobResult)) { $tempTitle = $uuid ; Log "Job returned null or empty title, using UUID as tempTitle: $tempTitle" }
                else { $tempTitle = $jobResult.Trim() ; Log "Job returned valid title: $tempTitle" }
            } 
            else { Stop-Job -Job $job_title -Force 2>&1 | Out-Null ; Log "Job did not complete in time, stopped forcefully. Using UUID as tempTitle" ; $tempTitle = $uuid }
            if ($tempTitle -eq $uuid) { $sanitized_title = $uuid.Substring(0,17) ; Log "Using UUID as sanitized title: $sanitized_title" }
            else {
                $sanitized_title = $tempTitle.Trim()
                $sanitized_title = [regex]::Replace($sanitized_title, '[^\p{L}\p{N}\s-]', '')
                if ($sanitized_title.Length -gt 35) { $sanitized_title = $sanitized_title.Substring(0,35).Trim() ; Log "Sanitized title truncated to 35 characters: $sanitized_title" }
                elseif ($sanitized_title.Length -lt 5) { $sanitized_title = $uuid.Substring(0,17) ; Log "Sanitized title too short, using UUID instead: $sanitized_title" }
                else { Log "Sanitized title: $sanitized_title" }
            }

            $extension = [IO.Path]::GetExtension($downloaded_path)
            Log "Detected file extension: $extension"
            $newFileName = "$sanitized_title$extension"
            $destination = Join-Path $downloadDir $newFileName
            if ($tempTitle -ne $uuid) { 
                if (Test-Path $destination) { Remove-Item $destination -Force ; Log "Existing file at destination removed: $destination" }
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
                } 
                catch { Log "Failed to copy file at end" }
            }
            Send-NativeMessage @{ success = $true; finalPath = $newFile.FullName }
            if ($inputData.bipAtEnd) {
                try { (New-Object Media.SoundPlayer "C:\Windows\Media\notify.wav").PlaySync() ; Log "Bip sound played" } 
                catch { Log "Failed to play bip sound 'C:\Windows\Media\notify.wav'" }
            }
        } 
        else {
            Log "yt-dlp failed with exit code $($process.ExitCode)."
            Send-NativeMessage @{ success = $false; message = "yt-dlp failed with exit code $($process.ExitCode).<br>If the error persist, please retry in a few hours/days." }
        }
    } 
    catch {
        Log "Error executing yt-dlp: $_"
        Send-NativeMessage @{ success = $false; message = "Error executing yt-dlp: $_ <br>If the error persist, please retry in a few hours/days." }
    }
}
elseif ($inputData.SHOW) {
    try {
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
        $normalizedTargetFolderPath = (Resolve-Path (Split-Path -Path $fileToShow -Parent)).Path
        if (-not $normalizedTargetFolderPath) { 
            $errormessage = "Could not get parent path for: '$fileToShow'"
            Log $errormessage
            Send-NativeMessage @{ success = $false; message = $errormessage }
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
                            if ((Resolve-Path $window.Document.Folder.Self.Path -ErrorAction Stop).Path -eq $normalizedTargetFolderPath) {
                                Log "Found matching window (HWND: $($window.HWND))"
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
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
                if ([User32]::IsIconic($foundWindowHwnd)) {
                    Log "Restoring minimized window..."
                    [User32]::ShowWindow($foundWindowHwnd, [User32]::SW_RESTORE) | Out-Null
                    Start-Sleep -Milliseconds 100
                }
                if ([User32]::SetForegroundWindow($foundWindowHwnd)) {
                    Start-Sleep -Milliseconds 100
                    Log "Attempting F5 refresh and select..."
                    try {
                        [System.Windows.Forms.SendKeys]::SendWait("{F5}")
                        $itemFoundInView = $false
                        $timeoutSeconds = 2
                        $waitTimeMs = 400
                        Start-Sleep -Milliseconds $waitTimeMs
                        $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
                        while ($stopWatch.Elapsed.TotalSeconds -lt $timeoutSeconds) {
                            $items = $null
                            try {
                                $items = $foundWindowObject.Document.Folder.Items()
                                if ($null -ne ($items | Where-Object { $_.Path -eq $fileToShow })) {
                                    $itemFoundInView = $true
                                    break
                                }
                            } 
                            catch { Log "Warning: cannot access items during poll: $($_.Exception.Message)" }
                            finally { if ($null -ne $items -and [System.Runtime.InteropServices.Marshal]::IsComObject($items)) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($items) | Out-Null } }
                            Start-Sleep -Milliseconds $waitTimeMs
                        }
                        $stopWatch.Stop()
                        if (-not $itemFoundInView) { Log "Warning: File not seen in view after F5/$timeoutSeconds sec timeout." }
                    } 
                    catch { Log "Warning: Cannot send F5 or polling: $($_.Exception.Message)" }
                    try {
                        $foundWindowObject.Document.SelectItem($fileToShow, 0x0D) # 0x0D = Select+EnsureVisible+DeselectOthers
                        Send-NativeMessage @{ success = $true; message = "Activated, refreshed (F5), selected via COM: $fileToShow" }
                    } 
                    catch {
                         Log "ERROR using COM SelectItem after F5: $($_.Exception.Message). Falling back."
                         explorer.exe /select,"$fileToShow"
                         Send-NativeMessage @{ success = $false; message = "Activated/refreshed (F5), COM select failed. Fallback used. File: $fileToShow. Error: $($_.Exception.Message)" }
                    }
                } 
                else {
                    Log "SetForegroundWindow failed. Falling back."
                    explorer.exe /select,"$fileToShow"
                    Send-NativeMessage @{ success = false; message = "Failed to set foreground window. Fallback used: $fileToShow" }
                }
            } 
            catch {
                Log "ERROR during activation/refresh/select: $($_.Exception.Message). Falling back."
                explorer.exe /select,"$fileToShow"
                Send-NativeMessage @{ success = false; message = "Error activating/refreshing/selecting. Fallback used. File: $fileToShow. Error: $($_.Exception.Message)" }
            } 
            finally {
                if ($null -ne $foundWindowObject -and [System.Runtime.InteropServices.Marshal]::IsComObject($foundWindowObject)) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($foundWindowObject) | Out-Null }
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()
            }
        } 
        else {
            Log "No matching window found. Using default explorer.exe /select."
            explorer.exe /select,"$fileToShow"
            Send-NativeMessage @{ success = $true; message = "File showed (default behavior): $fileToShow" }
        }
    } 
    catch {
        Log "FATAL Error showing file: $_"
        Send-NativeMessage @{ success = $false; message = "Error showing file: $_" }
    }
}
elseif ($inputData.COPY) {
    try {
        Log "Copying file: $fileToCopy"
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
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
