#Requires -Version 5.1
<#
.SYNOPSIS
    Updates the Arma 3 Dedicated Server via SteamCMD. Supports branch switching.

.DESCRIPTION
    Updates the public dedicated-server package (App ID 233780) anonymously.
    Profiling and development branches use the full Arma 3 package (App ID
    107410) and the Steam account configured in .env.
    Can switch between branches (public / profiling / development).
    Stops running server processes before updating if -StopFirst is specified.

.PARAMETER Branch
    Target Steam branch. Valid values: "public", "profiling", "development".
    Omit to use SERVER_UPDATE_BRANCH from .env, then the branch recorded by the
    last successful framework update. Defaults to public when neither exists.

.PARAMETER StopFirst
    Stop any running arma3server processes before updating.

.PARAMETER Validate
    Pass the 'validate' flag to SteamCMD (verifies all files, slower but thorough).

.EXAMPLE
    .\Update-Server.ps1
    .\Update-Server.ps1 -Branch profiling
    .\Update-Server.ps1 -Branch public -StopFirst -Validate
#>

[CmdletBinding()]
param(
    [ValidateSet("public", "profiling", "development")]
    [string]$Branch,

    [switch]$StopFirst,
    [switch]$Validate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Load shared utilities and framework config
# ---------------------------------------------------------------------------
$ScriptRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path
$FrameworkRoot = Split-Path -Parent $ScriptRoot
$CommonScript  = Join-Path $FrameworkRoot "scripts\Common.ps1"

if (-not (Test-Path $CommonScript)) {
    Write-Error "Common.ps1 not found at '$CommonScript'."
}
. $CommonScript

$Config = Get-FrameworkConfig

$branchMarkerPath = Join-Path $Config.ServerInstallPath ".arma3-server-branch"
$validBranches = @("public", "profiling", "development")

if ($Branch) {
    $targetBranch = $Branch
} elseif (-not [string]::IsNullOrWhiteSpace($Config.ServerUpdateBranch)) {
    $targetBranch = $Config.ServerUpdateBranch.Trim().ToLowerInvariant()
    if ($targetBranch -notin $validBranches) {
        Write-Log "Invalid SERVER_UPDATE_BRANCH '$targetBranch' in .env." "Error"
        Write-Log "Use public, profiling, or development." "Error"
        exit 1
    }
    Write-Log "Branch loaded from .env: $targetBranch" "Info"
} elseif (Test-Path -LiteralPath $branchMarkerPath) {
    $targetBranch = (Get-Content -LiteralPath $branchMarkerPath -Raw).Trim()
    if ($targetBranch -notin $validBranches) {
        Write-Log "Invalid branch marker '$targetBranch' at '$branchMarkerPath'." "Error"
        Write-Log "Run again with -Branch public, -Branch profiling, or -Branch development." "Error"
        exit 1
    }
    Write-Log "Branch loaded from marker: $targetBranch" "Info"
} else {
    $targetBranch = "public"
    Write-Log "No branch marker found. Defaulting to public; pass -Branch explicitly to switch." "Warning"
}

# ---------------------------------------------------------------------------
# Optional: stop running server processes
# ---------------------------------------------------------------------------
if ($StopFirst) {
    Write-Log "Stopping running Arma 3 server processes..." "Info"
    $procs = Get-Process -Name "arma3server*" -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force
        Write-Log "Stopped $($procs.Count) process(es)." "Success"
        Start-Sleep -Seconds 3
    } else {
        Write-Log "No running arma3server processes found." "Info"
    }
}

# ---------------------------------------------------------------------------
# Build SteamCMD arguments
# ---------------------------------------------------------------------------
$steamCmdExe = Join-Path $Config.SteamCMDPath "steamcmd.exe"
if (-not (Test-Path $steamCmdExe)) {
    Write-Log "steamcmd.exe not found at '$steamCmdExe'." "Error"
    Write-Log "Run .\setup\Install-Framework.ps1 first." "Error"
    exit 1
}

# App ID 233780 provides the public dedicated-server package anonymously.
# Non-public branches are distributed through the full Arma 3 app and require
# an account that owns Arma 3.
$requiresSteamAccount = $targetBranch -ne "public"
$appId = if ($requiresSteamAccount) { 107410 } else { 233780 }
$appUpdateCmd = "app_update $appId -beta $targetBranch"

Write-Log "Branch: $targetBranch" "Info"
Write-Log "Steam App ID: $appId" "Info"

$steamUser = ""
$steamPass = ""
if ($requiresSteamAccount) {
    $steamUser = $Config.SteamUsername
    if ([string]::IsNullOrWhiteSpace($steamUser) -or $steamUser -eq "your_steam_username") {
        Write-Log "Branch '$targetBranch' requires STEAM_USERNAME in .env." "Error"
        exit 1
    }
    $steamPass = Read-SteamPassword -Username $steamUser -Config $Config
}

if ($Validate) {
    $appUpdateCmd += " validate"
    Write-Log "Validate: enabled" "Info"
}

# ---------------------------------------------------------------------------
# Run SteamCMD via script file (handles special chars in password safely)
# ---------------------------------------------------------------------------
Write-Log "Starting server update..." "Info"
Write-Log "Target: $($Config.ServerInstallPath)" "Info"

$steamCmdParams = @{
    SteamCMDExe      = $steamCmdExe
    PreLoginCommands = @("force_install_dir `"$($Config.ServerInstallPath)`"")
    Commands         = @($appUpdateCmd)
}

if ($requiresSteamAccount) {
    $steamCmdParams.Username = $steamUser
    $steamCmdParams.Password = $steamPass
} else {
    $steamCmdParams.Anonymous = $true
}

$exitCode = Invoke-SteamCMD @steamCmdParams

if ($exitCode -ne 0) {
    Write-Log "SteamCMD exited with code $exitCode. Check output above." "Error"
    exit 1
}

$expectedBinaryName = if ($targetBranch -eq "profiling") {
    "arma3serverprofiling_x64.exe"
} else {
    "arma3server_x64.exe"
}
$expectedBinaryPath = Join-Path $Config.ServerInstallPath $expectedBinaryName

if (-not (Test-Path -LiteralPath $expectedBinaryPath)) {
    Write-Log "SteamCMD completed but expected binary is missing: $expectedBinaryPath" "Error"
    exit 1
}

Set-Content -LiteralPath $branchMarkerPath -Value $targetBranch -Encoding ASCII
Set-Content -LiteralPath (Join-Path $Config.ServerInstallPath "appid") -Value $appId -Encoding ASCII

Write-Log "Server update complete." "Success"
Write-Log "Recorded installed branch: $targetBranch" "Info"

# ---------------------------------------------------------------------------
# Report installed binary versions
# ---------------------------------------------------------------------------
$binaries = @(
    "arma3server_x64.exe",
    "arma3serverprofiling_x64.exe"
)

Write-Log "" "Info"
Write-Log "Installed binaries:" "Info"
foreach ($bin in $binaries) {
    $binPath = Join-Path $Config.ServerInstallPath $bin
    if (Test-Path $binPath) {
        $ver = (Get-Item $binPath).VersionInfo.FileVersion
        Write-Log "  $bin  (version: $ver)" "Info"
    }
}
