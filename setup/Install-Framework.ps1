#Requires -Version 5.1
<#
.SYNOPSIS
    First-time installation: downloads SteamCMD and installs the Arma 3 Dedicated Server.

.DESCRIPTION
    - Downloads SteamCMD to the path configured in .env (SteamCMDPath)
    - Installs the public dedicated server (App ID 233780) anonymously
    - Installs profiling from the full Arma 3 app (App ID 107410) with the
      Steam account configured in .env
    - Optionally selects a Steam branch (public / profiling)

.PARAMETER Branch
    Steam branch to install. Valid values: "public", "profiling". Default: "public".

.PARAMETER SkipSteamCMD
    Skip the SteamCMD download step (use if SteamCMD is already installed).

.PARAMETER SkipServer
    Skip the Arma 3 server installation step (use to only install SteamCMD).

.EXAMPLE
    .\Install-Framework.ps1
    .\Install-Framework.ps1 -Branch profiling
    .\Install-Framework.ps1 -SkipSteamCMD
#>

[CmdletBinding()]
param(
    [ValidateSet("public", "profiling")]
    [string]$Branch = "public",

    [switch]$SkipSteamCMD,
    [switch]$SkipServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Load shared utilities and framework config
# ---------------------------------------------------------------------------
$ScriptRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$FrameworkRoot = Split-Path -Parent $ScriptRoot
$CommonScript  = Join-Path $FrameworkRoot "scripts\Common.ps1"

if (-not (Test-Path $CommonScript)) {
    Write-Error "Common.ps1 not found at '$CommonScript'. Make sure the scripts\ folder exists."
}
. $CommonScript

$Config = Get-FrameworkConfig

if (-not $PSBoundParameters.ContainsKey("Branch") -and
    -not [string]::IsNullOrWhiteSpace($Config.ServerUpdateBranch)) {
    $configuredBranch = $Config.ServerUpdateBranch.Trim().ToLowerInvariant()
    if ($configuredBranch -notin @("public", "profiling")) {
        Write-Log "Install-Framework supports SERVER_UPDATE_BRANCH public or profiling, got '$configuredBranch'." "Error"
        exit 1
    }
    $Branch = $configuredBranch
}

# ---------------------------------------------------------------------------
# Step 1 – Download and extract SteamCMD
# ---------------------------------------------------------------------------
if (-not $SkipSteamCMD) {
    Write-Log "=== Step 1: SteamCMD Installation ===" "Header"

    $steamCmdExe = Join-Path $Config.SteamCMDPath "steamcmd.exe"

    if (Test-Path $steamCmdExe) {
        Write-Log "SteamCMD already found at '$steamCmdExe'. Skipping download." "Info"
    } else {
        Write-Log "Creating SteamCMD directory: $($Config.SteamCMDPath)" "Info"
        New-Item -ItemType Directory -Path $Config.SteamCMDPath -Force | Out-Null

        $zipUrl  = "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip"
        $zipPath = Join-Path $Config.SteamCMDPath "steamcmd.zip"

        Write-Log "Downloading SteamCMD from $zipUrl ..." "Info"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing

        Write-Log "Extracting SteamCMD..." "Info"
        Expand-Archive -Path $zipPath -DestinationPath $Config.SteamCMDPath -Force
        Remove-Item $zipPath -Force

        Write-Log "SteamCMD installed to: $($Config.SteamCMDPath)" "Success"
    }
} else {
    Write-Log "Skipping SteamCMD download (-SkipSteamCMD)." "Info"
}

# ---------------------------------------------------------------------------
# Step 2 – Install Arma 3 Dedicated Server
# ---------------------------------------------------------------------------
if (-not $SkipServer) {
    Write-Log "=== Step 2: Arma 3 Dedicated Server Installation ===" "Header"
    Write-Log "Branch  : $Branch" "Info"
    Write-Log "Target  : $($Config.ServerInstallPath)" "Info"

    $steamCmdExe = Join-Path $Config.SteamCMDPath "steamcmd.exe"
    if (-not (Test-Path $steamCmdExe)) {
        Write-Log "steamcmd.exe not found at '$steamCmdExe'." "Error"
        Write-Log "Run without -SkipSteamCMD first, or install SteamCMD manually." "Error"
        exit 1
    }

    New-Item -ItemType Directory -Path $Config.ServerInstallPath -Force | Out-Null

    $requiresSteamAccount = $Branch -ne "public"
    $appId = if ($requiresSteamAccount) { 107410 } else { 233780 }
    $appUpdateCmd = "app_update $appId -beta $Branch validate"

    Write-Log "Steam App ID: $appId" "Info"
    Write-Log "Starting SteamCMD server installation. This may take a while..." "Info"

    $steamCmdParams = @{
        SteamCMDExe      = $steamCmdExe
        PreLoginCommands = @("force_install_dir `"$($Config.ServerInstallPath)`"")
        Commands         = @($appUpdateCmd)
    }

    if ($requiresSteamAccount) {
        $steamUser = $Config.SteamUsername
        if ([string]::IsNullOrWhiteSpace($steamUser) -or $steamUser -eq "your_steam_username") {
            Write-Log "Branch '$Branch' requires STEAM_USERNAME in .env." "Error"
            exit 1
        }

        $steamCmdParams.Username = $steamUser
        $steamCmdParams.Password = Read-SteamPassword -Username $steamUser -Config $Config
    } else {
        $steamCmdParams.Anonymous = $true
    }

    $exitCode = Invoke-SteamCMD @steamCmdParams

    if ($exitCode -ne 0) {
        Write-Log "SteamCMD exited with code $exitCode. Check output above for errors." "Error"
        exit 1
    }

    $expectedBinaryName = if ($Branch -eq "profiling") {
        "arma3serverprofiling_x64.exe"
    } else {
        "arma3server_x64.exe"
    }
    $expectedBinaryPath = Join-Path $Config.ServerInstallPath $expectedBinaryName
    if (-not (Test-Path -LiteralPath $expectedBinaryPath)) {
        Write-Log "SteamCMD completed but expected binary is missing: $expectedBinaryPath" "Error"
        exit 1
    }

    # Record the installed package and branch for future updates.
    Set-Content -LiteralPath (Join-Path $Config.ServerInstallPath "appid") -Value $appId -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Config.ServerInstallPath ".arma3-server-branch") -Value $Branch -Encoding ASCII

    # Create keys directory if missing
    $keysDir = Join-Path $Config.ServerInstallPath "keys"
    New-Item -ItemType Directory -Path $keysDir -Force | Out-Null

    # Create MPMissions directory if missing
    $mpMissionsDir = Join-Path $Config.ServerInstallPath "MPMissions"
    New-Item -ItemType Directory -Path $mpMissionsDir -Force | Out-Null

    Write-Log "Arma 3 Dedicated Server installed successfully on branch '$Branch'." "Success"
    Write-Log "Server path : $($Config.ServerInstallPath)" "Success"
} else {
    Write-Log "Skipping server installation (-SkipServer)." "Info"
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Log "" "Info"
Write-Log "=== Installation Complete ===" "Header"
Write-Log "Next steps:" "Info"
Write-Log "  1. Edit profiles\main\profile.json (mods, port, HC count, ...)" "Info"
Write-Log "  2. Edit profiles\main\server.cfg   (hostname, passwords, missions, ...)" "Info"
Write-Log "  3. Run: .\mods\Sync-Mods.ps1 -Profile main" "Info"
Write-Log "  4. Run: .\scripts\Start-Server.ps1 -Profile main" "Info"
