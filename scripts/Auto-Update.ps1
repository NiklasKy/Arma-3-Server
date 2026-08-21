#Requires -Version 5.1
<#
.SYNOPSIS
    Updates the Arma 3 server and all configured Workshop mods while idle.

.DESCRIPTION
    Acquires the framework maintenance lock, refuses to run while any
    arma3server process is active, updates SERVER_UPDATE_BRANCH from .env (or
    the last recorded branch when unset), and then updates Workshop mods used
    by all profiles.

.PARAMETER DryRun
    Perform lock and process checks without invoking SteamCMD.
#>

[CmdletBinding()]
param(
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$FrameworkRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $ScriptRoot "Common.ps1")

$Config = Get-FrameworkConfig
$maintenanceLock = Enter-FrameworkMaintenanceLock -Config $Config -Purpose "automatic-update"

if ($null -eq $maintenanceLock) {
    Write-Log "Automatic update skipped because another framework operation is running." "Warning"
    Write-Log "AUTO_UPDATE_RESULT=skipped_locked" "Info"
    exit 0
}

$exitCode = 0
try {
    if (@(Get-ServerProcesses).Count -gt 0) {
        Write-Log "Automatic update skipped because at least one Arma 3 server process is active." "Warning"
        Write-Log "AUTO_UPDATE_RESULT=skipped_active" "Info"
    } elseif ($DryRun) {
        Write-Log "Dry run passed: no Arma 3 server process is active." "Success"
        Write-Log "AUTO_UPDATE_RESULT=dry_run" "Info"
    } else {
        if ([string]::IsNullOrWhiteSpace($Config.SteamUsername) -or
            $Config.SteamUsername -eq "your_steam_username" -or
            [string]::IsNullOrWhiteSpace($Config.SteamPassword)) {
            throw "Automatic Workshop updates require STEAM_USERNAME and STEAM_PASSWORD in .env."
        }

        Write-Log "=== Automatic Arma 3 Update ===" "Header"

        $serverUpdateScript = Join-Path $FrameworkRoot "setup\Update-Server.ps1"
        $serverUpdateArgs = @(
            "-NoProfile"
            "-ExecutionPolicy", "Bypass"
            "-NonInteractive"
            "-File", $serverUpdateScript
        )

        if (-not [string]::IsNullOrWhiteSpace($Config.ServerUpdateBranch)) {
            $updateBranch = $Config.ServerUpdateBranch.Trim().ToLowerInvariant()
            if ($updateBranch -notin @("public", "profiling", "development")) {
                throw "Invalid SERVER_UPDATE_BRANCH '$updateBranch' in .env."
            }
            Write-Log "Automatic server branch: $updateBranch" "Info"
            $serverUpdateArgs += @("-Branch", $updateBranch)
        }

        & powershell.exe @serverUpdateArgs
        if ($LASTEXITCODE -ne 0) {
            throw "Server update failed with exit code $LASTEXITCODE."
        }

        # Guard against a server started outside the framework during SteamCMD.
        if (@(Get-ServerProcesses).Count -gt 0) {
            throw "An Arma 3 server process appeared during maintenance; mod updates were not started."
        }

        $modUpdateScript = Join-Path $FrameworkRoot "mods\Sync-Mods.ps1"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File $modUpdateScript -Profile _all -Update
        if ($LASTEXITCODE -ne 0) {
            throw "Workshop update failed with exit code $LASTEXITCODE."
        }

        Write-Log "Automatic game and Workshop update cycle completed." "Success"
        Write-Log "AUTO_UPDATE_RESULT=complete" "Info"
    }
} catch {
    Write-Log "Automatic update failed: $($_.Exception.Message)" "Error"
    Write-Log "AUTO_UPDATE_RESULT=failed" "Error"
    $exitCode = 1
} finally {
    Exit-FrameworkMaintenanceLock -Lock $maintenanceLock -Config $Config
}

exit $exitCode
