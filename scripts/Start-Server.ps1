#Requires -Version 5.1
<#
.SYNOPSIS
    Starts an Arma 3 Dedicated Server for the specified profile.
    Optionally starts Headless Client processes automatically.

.DESCRIPTION
    Reads .env and the target profile's profile.json, then:
      - Selects the correct server binary (public vs profiling branch)
      - Builds the -mod= and -serverMod= strings
      - Starts the server process
      - Waits for the server to be ready, then starts Headless Clients (if configured)

.PARAMETER Profile
    Profile name to start (folder name under profiles\).

.PARAMETER NoHC
    Skip starting Headless Clients even if the profile has HeadlessClientCount > 0.

.PARAMETER NoWait
    Do not wait for the server to be ready before starting HCs (start HCs after a fixed delay).

.PARAMETER HCDelay
    Seconds to wait after server start before launching HCs (used with -NoWait or as fallback).
    Default: 30.

.EXAMPLE
    .\Start-Server.ps1 -Profile main
    .\Start-Server.ps1 -Profile tvt -NoHC
    .\Start-Server.ps1 -Profile main -HCDelay 60
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Profile,

    [switch]$NoHC,

    [switch]$NoWait,

    [int]$HCDelay = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot "Common.ps1")

$Config  = Get-FrameworkConfig
$Prof    = Get-Profile -ProfileName $Profile

$branchMarkerPath = Join-Path $Config.ServerInstallPath ".arma3-server-branch"
if (Test-Path -LiteralPath $branchMarkerPath) {
    $installedBranch = (Get-Content -LiteralPath $branchMarkerPath -Raw).Trim().ToLowerInvariant()
    $profileBranch = ([string]$Prof.Branch).Trim().ToLowerInvariant()
    if ($installedBranch -ne $profileBranch) {
        Write-Log "Profile '$Profile' requires branch '$profileBranch', but '$installedBranch' is installed." "Error"
        Write-Log "Run .\setup\Update-Server.ps1 -Branch $profileBranch before starting this profile." "Error"
        exit 1
    }
}

$maintenanceLock = Enter-FrameworkMaintenanceLock -Config $Config -Purpose "server-start:$Profile"
if ($null -eq $maintenanceLock) {
    Write-Log "Server start blocked because a framework maintenance operation is running." "Error"
    exit 1
}

Write-Log "=== Starting Arma 3 Server: $Profile ===" "Header"
Write-Log "Branch     : $($Prof.Branch)" "Info"
Write-Log "Port       : $($Prof.Port)" "Info"
Write-Log "MaxPlayers : $($Prof.MaxPlayers)" "Info"

# ---------------------------------------------------------------------------
# Archive previous session logs before a clean start
# ---------------------------------------------------------------------------
Invoke-LogRotation -ProfileDir $Prof.ProfileDir -LogDir $Prof.LogDir

# ---------------------------------------------------------------------------
# Resolve binary
# ---------------------------------------------------------------------------
$binary = Get-Arma3ServerBinary -ServerInstallPath $Config.ServerInstallPath `
                                 -Branch $Prof.Branch
Write-Log "Binary     : $binary" "Info"

# ---------------------------------------------------------------------------
# Build mod strings
# ---------------------------------------------------------------------------
$modString = ""
if ($Prof.PSObject.Properties.Name -contains "Mods" -and @($Prof.Mods).Count -gt 0) {
    $modString = Build-ModString -Mods @($Prof.Mods) -ServerInstallPath $Config.ServerInstallPath
    Write-Log "Mods       : $modString" "Info"
}

$serverModString = ""
if ($Prof.PSObject.Properties.Name -contains "ServerMods" -and @($Prof.ServerMods).Count -gt 0) {
    $serverModString = Build-ModString -Mods @($Prof.ServerMods) `
                                       -ServerInstallPath $Config.ServerInstallPath
    Write-Log "ServerMods : $serverModString" "Info"
}

# ---------------------------------------------------------------------------
# Build server argument list
# ---------------------------------------------------------------------------
$serverArgs = [System.Collections.Generic.List[string]]::new()

$serverArgs.Add("-port=$($Prof.Port)")
$serverArgs.Add("-config=`"$($Prof.ServerCfg)`"")
$serverArgs.Add("-cfg=`"$($Prof.BasicCfg)`"")
$serverArgs.Add("-profiles=`"$($Prof.ProfileDir)`"")
$serverArgs.Add("-name=$Profile")
$serverArgs.Add("-world=empty")

if ($modString) {
    $serverArgs.Add("-mod=`"$modString`"")
}
if ($serverModString) {
    $serverArgs.Add("-serverMod=`"$serverModString`"")
}

# Optional flags from profile
if ($Prof.PSObject.Properties.Name -contains "EnableAutoInit" -and $Prof.EnableAutoInit) {
    $serverArgs.Add("-autoInit")
}
if ($Prof.PSObject.Properties.Name -contains "FPSLimit" -and $Prof.FPSLimit -gt 0) {
    $serverArgs.Add("-limitFPS=$($Prof.FPSLimit)")
}
if ($Prof.PSObject.Properties.Name -contains "ExtraArgs" -and $Prof.ExtraArgs) {
    foreach ($arg in $Prof.ExtraArgs) {
        $serverArgs.Add($arg)
    }
}

$serverArgs.Add("-enableHT")

# ---------------------------------------------------------------------------
# Deploy userconfig (ACE3 / CBA settings) from profile to server root
# ---------------------------------------------------------------------------
$profileUserconfig = Join-Path $Prof.ProfileDir "userconfig"
if (Test-Path $profileUserconfig) {
    $serverUserconfig = Join-Path $Config.ServerInstallPath "userconfig"
    Write-Log "Deploying userconfig from profile '$Profile' to server root..." "Info"
    Copy-Item -Path $profileUserconfig -Destination $Config.ServerInstallPath -Recurse -Force
    Write-Log "userconfig deployed to: $serverUserconfig" "Success"
}

# ---------------------------------------------------------------------------
# Check for port conflict
# ---------------------------------------------------------------------------
$existingProcs = Get-ServerProcesses
if ($existingProcs) {
    Write-Log "Running arma3server processes detected:" "Warning"
    $existingProcs | ForEach-Object { Write-Log "  PID $($_.Id)  $($_.MainWindowTitle)" "Warning" }
    Write-Log "If you want to start a second instance, make sure it uses a different port." "Warning"
}

# ---------------------------------------------------------------------------
# Start server
# ---------------------------------------------------------------------------
Write-Log "" "Info"
Write-Log "Launching server..." "Info"
Write-Log "  $binary $($serverArgs -join ' ')" "Info"
Write-Log "" "Info"

$serverPid = Start-DetachedProcess -FilePath $binary `
                                    -ArgumentList $serverArgs `
                                    -WorkingDirectory $Config.ServerInstallPath

Write-Log "Server started  (PID: $serverPid)" "Success"

# Persist the PID for Stop-Server.ps1
$pidFile = Join-Path $Prof.ProfileDir "server.pid"
Set-Content -Path $pidFile -Value $serverPid -Encoding ASCII
Write-Log "PID saved to: $pidFile" "Info"

# The update job only needs to exclude the launch itself. Once the process is
# visible, subsequent update cycles will skip because an Arma process is active.
Exit-FrameworkMaintenanceLock -Lock $maintenanceLock -Config $Config
$maintenanceLock = $null

# ---------------------------------------------------------------------------
# Headless Clients
# ---------------------------------------------------------------------------
$hcCount = 0
if ($Prof.PSObject.Properties.Name -contains "HeadlessClientCount") {
    $hcCount = [int]$Prof.HeadlessClientCount
}

if ($hcCount -gt 0 -and -not $NoHC) {
    Write-Log "" "Info"
    Write-Log "=== Starting $hcCount Headless Client(s) ===" "Header"

    # Wait for server to be ready
    if ($NoWait) {
        Write-Log "Waiting $HCDelay seconds before starting HCs (-NoWait mode)..." "Info"
        Start-Sleep -Seconds $HCDelay
    } else {
        # Arma 3 only responds to UDP queries once a mission is loaded.
        # A short timeout is fine – if the server is up, HCs can connect immediately.
        $ready = Wait-ServerReady -Port $Prof.Port -TimeoutSeconds 20
        if (-not $ready) {
            Write-Log "Server did not respond to UDP query (normal without active mission). Starting HCs in ${HCDelay}s..." "Info"
            Start-Sleep -Seconds $HCDelay
        }
    }

    $hcScript = Join-Path $ScriptRoot "Start-Headless.ps1"
    $hcPids   = @()

    for ($i = 1; $i -le $hcCount; $i++) {
        Write-Log "Starting HC $i / $hcCount ..." "Info"

        $hcReturnedPid = & $hcScript `
            -Profile $Profile `
            -HCIndex $i `
            -ServerHost "127.0.0.1" `
            -PassThru

        if ($hcReturnedPid) {
            $hcPids += $hcReturnedPid
        }

        # Small stagger to avoid simultaneous logins
        if ($i -lt $hcCount) { Start-Sleep -Seconds 5 }
    }

    # Persist HC PIDs
    $hcPidFile = Join-Path $Prof.ProfileDir "headless.pids"
    Set-Content -Path $hcPidFile -Value ($hcPids -join "`n") -Encoding ASCII
    Write-Log "HC PIDs saved to: $hcPidFile" "Info"
} elseif ($hcCount -gt 0 -and $NoHC) {
    Write-Log "Headless Clients skipped (-NoHC)." "Info"
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Log "" "Info"
Write-Log "=== Server is running ===" "Header"
Write-Log "Profile  : $Profile" "Info"
Write-Log "Port     : $($Prof.Port)" "Info"
Write-Log "PID      : $serverPid" "Info"
if ($hcCount -gt 0 -and -not $NoHC) {
    Write-Log "HCs      : $hcCount" "Info"
}
Write-Log "" "Info"
Write-Log "To stop  : .\scripts\Stop-Server.ps1 -Profile $Profile" "Info"
