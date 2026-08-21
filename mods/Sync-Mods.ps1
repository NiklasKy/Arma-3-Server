#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads, updates, and deploys Steam Workshop mods for Arma 3.

.DESCRIPTION
    Reads Workshop IDs from a profile, downloads required items with SteamCMD,
    deploys them transactionally, and copies their public keys. Update mode uses
    Steam Workshop timestamps and a local deployment-state file so unchanged
    mods are skipped.

.PARAMETER Profile
    Profile name to load mod list from. Use _all to combine every profile.

.PARAMETER WorkshopId
    Download a single mod by Workshop ID without reading a profile.

.PARAMETER FolderName
    Target folder name for single-mod mode.

.PARAMETER Force
    Re-download all selected mods even when already deployed.

.PARAMETER Update
    Download only missing or changed Workshop mods. The first update run creates
    a trusted baseline and therefore refreshes every existing mod once.

.PARAMETER CheckOnly
    Report pending updates without downloading or deploying anything.

.PARAMETER RestartServer
    If the selected profile is running and updates are available, stop it before
    deployment and start it again afterwards. Not supported with Profile _all.

.EXAMPLE
    .\Sync-Mods.ps1 -Profile main
    .\Sync-Mods.ps1 -Profile main -Update -CheckOnly
    .\Sync-Mods.ps1 -Profile main -Update -RestartServer
    .\Sync-Mods.ps1 -Profile main -Force
#>

[CmdletBinding(DefaultParameterSetName = "Profile")]
param(
    [Parameter(ParameterSetName = "Profile", Mandatory)]
    [string]$Profile,

    [Parameter(ParameterSetName = "Single", Mandatory)]
    [string]$WorkshopId,

    [Parameter(ParameterSetName = "Single", Mandatory)]
    [string]$FolderName,

    [switch]$Force,

    [Parameter(ParameterSetName = "Profile")]
    [switch]$Update,

    [Parameter(ParameterSetName = "Profile")]
    [switch]$CheckOnly,

    [Parameter(ParameterSetName = "Profile")]
    [switch]$RestartServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ArmaAppId = 107410
$WorkshopDetailsUri = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"

# ---------------------------------------------------------------------------
# Bootstrap and validation
# ---------------------------------------------------------------------------
$ScriptRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path
$FrameworkRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $FrameworkRoot "scripts\Common.ps1")

if ($Force -and $Update) {
    throw "-Force and -Update cannot be used together."
}
if ($CheckOnly -and -not $Update) {
    throw "-CheckOnly requires -Update."
}
if ($RestartServer -and -not $Update) {
    throw "-RestartServer requires -Update."
}
if ($RestartServer -and $CheckOnly) {
    throw "-RestartServer cannot be combined with -CheckOnly."
}
if ($PSCmdlet.ParameterSetName -eq "Profile") {
    if ($Profile -ne "_all" -and $Profile -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Invalid profile name '$Profile'."
    }
    if ($Profile -eq "_all" -and $RestartServer) {
        throw "-RestartServer requires one concrete profile, not _all."
    }
}

function Test-SafeWorkshopId {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^\d{1,20}$'
}

function Test-SafeFolderName {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or [IO.Path]::IsPathRooted($Value)) {
        return $false
    }
    if ($Value -in @('.', '..') -or $Value.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        return $false
    }
    return $Value -notmatch '[\\/]'
}

function Add-ValidatedMod {
    param(
        [System.Collections.ArrayList]$List,
        [string]$Id,
        [string]$TargetFolder
    )

    if (-not (Test-SafeWorkshopId -Value $Id)) {
        throw "Invalid Workshop ID '$Id'."
    }
    if (-not (Test-SafeFolderName -Value $TargetFolder)) {
        throw "Invalid mod folder name '$TargetFolder'."
    }

    $null = $List.Add(@{
        WorkshopId = $Id
        FolderName = $TargetFolder
    })
}

function Get-WorkshopDetails {
    param([object[]]$Mods)

    $body = @{ itemcount = $Mods.Count }
    for ($i = 0; $i -lt $Mods.Count; $i++) {
        $body["publishedfileids[$i]"] = $Mods[$i].WorkshopId
    }

    $response = Invoke-RestMethod -Method Post `
                                  -Uri $WorkshopDetailsUri `
                                  -Body $body `
                                  -ContentType "application/x-www-form-urlencoded" `
                                  -TimeoutSec 30

    if (-not $response.response -or -not $response.response.publishedfiledetails) {
        throw "Steam Workshop API returned an invalid response."
    }

    $detailsById = @{}
    foreach ($item in @($response.response.publishedfiledetails)) {
        $id = "$($item.publishedfileid)"
        if (-not (Test-SafeWorkshopId -Value $id)) {
            continue
        }
        $detailsById[$id] = $item
    }

    Write-Output -NoEnumerate $detailsById
}

function Read-WorkshopState {
    param([string]$Path)

    $state = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Output -NoEnumerate $state
        return
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($raw) {
            foreach ($property in $raw.PSObject.Properties) {
                $state[$property.Name] = $property.Value
            }
        }
    } catch {
        Write-Log "Workshop state is unreadable; a full baseline refresh is required: $($_.Exception.Message)" "Warning"
        $state = @{}
    }

    Write-Output -NoEnumerate $state
}

function Read-UpdateExclusions {
    param([string]$Path)

    $exclusions = @{}
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Output -NoEnumerate $exclusions
        return
    }

    try {
        $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Update exclusion file '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    if (-not $document -or $document.PSObject.Properties.Name -notcontains "WorkshopIds") {
        throw "Update exclusion file '$Path' must contain a WorkshopIds array."
    }

    foreach ($entry in @($document.WorkshopIds)) {
        $id = if ($entry -is [string]) { $entry } else { "$($entry.Id)" }
        if (-not (Test-SafeWorkshopId -Value $id)) {
            throw "Invalid Workshop ID '$id' in update exclusion file '$Path'."
        }

        $reason = if ($entry -is [string] -or $entry.PSObject.Properties.Name -notcontains "Reason") {
            "no reason specified"
        } else {
            "$($entry.Reason)" -replace '[\r\n]+', ' '
        }
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = "no reason specified"
        }
        if ($reason.Length -gt 200) {
            $reason = $reason.Substring(0, 200)
        }

        $exclusions[$id] = $reason
    }

    Write-Output -NoEnumerate $exclusions
}

function Save-WorkshopState {
    param(
        [hashtable]$State,
        [string]$Path
    )

    $orderedState = [ordered]@{}
    foreach ($key in @($State.Keys | Sort-Object)) {
        $orderedState[$key] = $State[$key]
    }

    $tempPath = "$Path.tmp.$PID"
    $orderedState | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Install-WorkshopMod {
    param(
        [string]$Source,
        [string]$Target
    )

    $newPath    = "$Target.__new_$PID"
    $backupPath = "$Target.__backup_$PID"

    if (Test-Path -LiteralPath $newPath) {
        Remove-Item -LiteralPath $newPath -Recurse -Force
    }
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Recurse -Force
    }

    Copy-Item -LiteralPath $Source -Destination $newPath -Recurse -Force

    try {
        if (Test-Path -LiteralPath $Target) {
            Move-Item -LiteralPath $Target -Destination $backupPath
        }
        Move-Item -LiteralPath $newPath -Destination $Target
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Recurse -Force
        }
    } catch {
        if ((Test-Path -LiteralPath $backupPath) -and -not (Test-Path -LiteralPath $Target)) {
            Move-Item -LiteralPath $backupPath -Destination $Target
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $newPath) {
            Remove-Item -LiteralPath $newPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$Config   = Get-FrameworkConfig
$SteamCmd = Join-Path $Config.SteamCMDPath "steamcmd.exe"

# ---------------------------------------------------------------------------
# Build and validate the selected mod list
# ---------------------------------------------------------------------------
$modList = [System.Collections.ArrayList]::new()
$profileData = $null

if ($PSCmdlet.ParameterSetName -eq "Single") {
    Add-ValidatedMod -List $modList -Id $WorkshopId -TargetFolder $FolderName
} elseif ($Profile -eq "_all") {
    $seen = @{}
    foreach ($profileName in Get-AvailableProfiles) {
        $currentProfile = Get-Profile -ProfileName $profileName
        if ($currentProfile.PSObject.Properties.Name -notcontains "WorkshopIds") {
            continue
        }
        foreach ($entry in @($currentProfile.WorkshopIds)) {
            $id = "$($entry.Id)"
            if (-not $seen.ContainsKey($id)) {
                Add-ValidatedMod -List $modList -Id $id -TargetFolder "$($entry.FolderName)"
                $seen[$id] = $true
            }
        }
    }
} else {
    $profileData = Get-Profile -ProfileName $Profile
    if ($profileData.PSObject.Properties.Name -notcontains "WorkshopIds") {
        Write-Log "Profile '$Profile' has no WorkshopIds defined in profile.json." "Warning"
        exit 0
    }
    foreach ($entry in @($profileData.WorkshopIds)) {
        Add-ValidatedMod -List $modList -Id "$($entry.Id)" -TargetFolder "$($entry.FolderName)"
    }
}

if ($modList.Count -eq 0) {
    Write-Log "No mods selected." "Info"
    exit 0
}

$mode = if ($Update) { "Update" } elseif ($Force) { "Force sync" } else { "Sync" }
Write-Log "=== Mod ${mode}: $($modList.Count) mod(s) ===" "Header"

# ---------------------------------------------------------------------------
# Determine which mods need deployment
# ---------------------------------------------------------------------------
$stagingRoot = Join-Path $Config.WorkshopStagingPath "steamapps\workshop\content\$ArmaAppId"
$statePath   = Join-Path $Config.WorkshopStagingPath "workshop-deploy-state.json"
$keysDir     = Join-Path $Config.ServerInstallPath "keys"
$exclusionPath = Join-Path $ScriptRoot "update-exclusions.json"

$workshopDetails = @{}
$deployState = @{}
$updateExclusions = @{}
if ($Update) {
    try {
        $updateExclusions = Read-UpdateExclusions -Path $exclusionPath
        $modsForMetadata = @($modList | Where-Object {
            -not $updateExclusions.ContainsKey($_.WorkshopId)
        })
        if ($modsForMetadata.Count -gt 0) {
            Write-Log "Checking Steam Workshop metadata..." "Info"
            $workshopDetails = Get-WorkshopDetails -Mods $modsForMetadata
        }
        $deployState = Read-WorkshopState -Path $statePath
    } catch {
        Write-Log "Workshop update check failed: $($_.Exception.Message)" "Error"
        exit 1
    }
}

$toDownload = [System.Collections.ArrayList]::new()
$current = 0
$failed = 0
$excluded = 0

foreach ($mod in $modList) {
    $id = $mod.WorkshopId
    $targetDir = Join-Path $Config.ServerInstallPath $mod.FolderName
    $hasFiles = (Test-Path -LiteralPath $targetDir) -and
                (@(Get-ChildItem -LiteralPath $targetDir -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0)

    if ($Force) {
        $mod.Reason = "forced refresh"
        $null = $toDownload.Add($mod)
        continue
    }

    if (-not $Update) {
        if ($hasFiles) {
            Write-Log "Already deployed: $($mod.FolderName)  (ID: $id)" "Info"
            $current++
        } else {
            $mod.Reason = "missing deployment"
            $null = $toDownload.Add($mod)
        }
        continue
    }

    if ($updateExclusions.ContainsKey($id)) {
        Write-Log "Excluded: $($mod.FolderName)  (ID: $id, reason: $($updateExclusions[$id]))" "Warning"
        $excluded++
        continue
    }

    if (-not $workshopDetails.ContainsKey($id)) {
        Write-Log "Workshop item $id was not returned by Steam. Skipping $($mod.FolderName)." "Error"
        $failed++
        continue
    }

    $remote = $workshopDetails[$id]
    $steamResult = [int]$remote.result
    if ($steamResult -ne 1) {
        Write-Log "Workshop item $id returned Steam result $steamResult. Add it to update-exclusions.json only when the installed version should remain pinned." "Error"
        $failed++
        continue
    }
    if ([long]$remote.consumer_app_id -ne $ArmaAppId) {
        Write-Log "Workshop item $id does not belong to Arma 3. Skipping." "Error"
        $failed++
        continue
    }

    $mod.RemoteTimeUpdated = [long]$remote.time_updated
    $mod.Title = "$($remote.title)"

    if (-not $hasFiles) {
        $mod.Reason = "missing deployment"
        $null = $toDownload.Add($mod)
    } elseif (-not $deployState.ContainsKey($id)) {
        $mod.Reason = "initial update baseline"
        $null = $toDownload.Add($mod)
    } else {
        $stateEntry = $deployState[$id]
        $stateTimeUpdated = 0
        if ($stateEntry.PSObject.Properties.Name -contains "TimeUpdated") {
            $stateTimeUpdated = [long]$stateEntry.TimeUpdated
        }

        if ($stateTimeUpdated -lt $mod.RemoteTimeUpdated) {
            $mod.Reason = "Workshop update available"
            $null = $toDownload.Add($mod)
        } else {
            Write-Log "Current: $($mod.FolderName)  (ID: $id)" "Info"
            $current++
        }
    }
}

foreach ($mod in $toDownload) {
    Write-Log "Update queued: $($mod.FolderName)  (ID: $($mod.WorkshopId), reason: $($mod.Reason))" "Info"
}

if ($CheckOnly) {
    Write-Log "" "Info"
    Write-Log "=== Update Check Complete ===" "Header"
    Write-Log "  Updates : $($toDownload.Count)" $(if ($toDownload.Count -gt 0) { "Warning" } else { "Success" })
    Write-Log "  Current : $current" "Info"
    Write-Log "  Excluded: $excluded" $(if ($excluded -gt 0) { "Warning" } else { "Info" })
    Write-Log "  Failed  : $failed" $(if ($failed -gt 0) { "Error" } else { "Info" })
    if ($failed -gt 0) { exit 1 }
    exit 0
}

if ($toDownload.Count -eq 0) {
    Write-Log "" "Info"
    Write-Log "=== Sync Complete: everything is current ===" "Success"
    if ($failed -gt 0) { exit 1 }
    exit 0
}

if (-not (Test-Path -LiteralPath $SteamCmd)) {
    Write-Log "steamcmd.exe not found at '$SteamCmd'. Run .\setup\Install-Framework.ps1 first." "Error"
    exit 1
}

# ---------------------------------------------------------------------------
# Protect running profiles from live mod replacement
# ---------------------------------------------------------------------------
$serverWasStopped = $false
if ($Update -and $Profile -ne "_all" -and $profileData) {
    $pidFile = Join-Path $profileData.ProfileDir "server.pid"
    $serverRunning = $false
    if (Test-Path -LiteralPath $pidFile) {
        $pidText = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        $serverPid = 0
        if ([int]::TryParse("$pidText", [ref]$serverPid)) {
            $process = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
            $serverRunning = $null -ne $process -and $process.ProcessName -like "arma3server*"
        }
    }

    if (-not $serverRunning) {
        $escapedProfileDir = [WildcardPattern]::Escape($profileData.ProfileDir)
        $profilePort = [int]$profileData.Port
        $matchingProcesses = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'arma3server%'" -ErrorAction SilentlyContinue |
            Where-Object {
                $commandLine = if ($_.CommandLine) { $_.CommandLine } else { '' }
                $isHeadlessClient = $commandLine -match '(^|\s)-client(\s|$)'
                -not $isHeadlessClient -and
                ($commandLine -like "*$escapedProfileDir*" -or $commandLine -like "*-port=$profilePort*")
            })
        $serverRunning = $matchingProcesses.Count -gt 0
    }

    if ($serverRunning -and -not $RestartServer) {
        Write-Log "Profile '$Profile' is running. Re-run with -RestartServer or stop it before updating mods." "Error"
        exit 1
    }

    if ($serverRunning) {
        Write-Log "Updates are available; stopping profile '$Profile' before deployment..." "Warning"
        $stopScript = Join-Path $FrameworkRoot "scripts\Stop-Server.ps1"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File $stopScript -Profile $Profile
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Could not stop profile '$Profile'; update aborted." "Error"
            exit 1
        }
        $serverWasStopped = $true
    }
}

# ---------------------------------------------------------------------------
# Download and transactionally deploy selected mods
# ---------------------------------------------------------------------------
$operationFailed = $false
$deployed = 0
$steamPass = $null

try {
    New-Item -ItemType Directory -Path $Config.WorkshopStagingPath -Force | Out-Null
    New-Item -ItemType Directory -Path $keysDir -Force | Out-Null

    $steamUser = $Config.SteamUsername
    $steamPass = Read-SteamPassword -Username $steamUser -Config $Config

    Write-Log "" "Info"
    Write-Log "=== Downloading $($toDownload.Count) mod(s) in one SteamCMD session ===" "Header"

    $downloadCommands = @()
    foreach ($mod in $toDownload) {
        $downloadCommands += "workshop_download_item $ArmaAppId $($mod.WorkshopId) validate"
    }

    $exitCode = Invoke-SteamCMD -SteamCMDExe $SteamCmd `
                                 -Username $steamUser `
                                 -Password $steamPass `
                                 -PreLoginCommands @(
                                     "force_install_dir `"$($Config.WorkshopStagingPath)`""
                                 ) `
                                 -Commands $downloadCommands

    if ($exitCode -ne 0) {
        throw "SteamCMD batch download exited with code $exitCode. Existing deployments were left untouched."
    }

    Write-Log "" "Info"
    Write-Log "=== Deploying downloaded mods ===" "Header"

    foreach ($mod in $toDownload) {
        $id = $mod.WorkshopId
        $targetDir = Join-Path $Config.ServerInstallPath $mod.FolderName
        $downloadedPath = Join-Path $stagingRoot $id

        Write-Log "Deploying $($mod.FolderName)  (ID: $id)..." "Info"
        if (-not (Test-Path -LiteralPath $downloadedPath)) {
            Write-Log "Downloaded folder not found at '$downloadedPath'; existing deployment was kept." "Error"
            $failed++
            continue
        }

        try {
            Install-WorkshopMod -Source $downloadedPath -Target $targetDir
            Write-Log "Deployed: $($mod.FolderName)" "Success"

            foreach ($key in @(Get-ChildItem -LiteralPath $targetDir -Recurse -Filter "*.bikey" -File -ErrorAction SilentlyContinue)) {
                Copy-Item -LiteralPath $key.FullName -Destination (Join-Path $keysDir $key.Name) -Force
                Write-Log "  Key copied: $($key.Name)" "Info"
            }

            if ($Update) {
                $deployState[$id] = [ordered]@{
                    TimeUpdated  = [long]$mod.RemoteTimeUpdated
                    FolderName   = $mod.FolderName
                    Title        = $mod.Title
                    DeployedAtUtc = [DateTime]::UtcNow.ToString("o")
                }
                Save-WorkshopState -State $deployState -Path $statePath
            }

            $deployed++
        } catch {
            Write-Log "Deployment failed for $($mod.FolderName); previous files were preserved: $($_.Exception.Message)" "Error"
            $failed++
        }
    }
} catch {
    Write-Log "Mod update failed: $($_.Exception.Message)" "Error"
    $operationFailed = $true
} finally {
    $steamPass = $null
    [GC]::Collect()

    if ($serverWasStopped) {
        Write-Log "Starting profile '$Profile' after mod maintenance..." "Info"
        $startScript = Join-Path $FrameworkRoot "scripts\Start-Server.ps1"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File $startScript -Profile $Profile
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Profile '$Profile' could not be restarted." "Error"
            $operationFailed = $true
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Log "" "Info"
Write-Log "=== Sync Complete ===" "Header"
Write-Log "  Deployed: $deployed" $(if ($deployed -gt 0) { "Success" } else { "Info" })
Write-Log "  Current : $current" "Info"
Write-Log "  Excluded: $excluded" $(if ($excluded -gt 0) { "Warning" } else { "Info" })
Write-Log "  Failed  : $failed" $(if ($failed -gt 0) { "Error" } else { "Info" })
Write-Log "  Keys dir: $keysDir" "Info"

if ($operationFailed -or $failed -gt 0) {
    exit 1
}
