#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helper functions for the Arma 3 Server Framework.
    Dot-source this file at the top of every other script.

.EXAMPLE
    . "$PSScriptRoot\..\scripts\Common.ps1"
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped, colour-coded log message to the console.
    .PARAMETER Message
        Text to display.
    .PARAMETER Level
        Log level: Info | Success | Warning | Error | Header
    #>
    [CmdletBinding()]
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error", "Header")]
        [string]$Level = "Info"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix    = "[$timestamp]"

    switch ($Level) {
        "Header"  { Write-Host "$prefix $Message"         -ForegroundColor Cyan }
        "Success" { Write-Host "$prefix [OK]  $Message"   -ForegroundColor Green }
        "Warning" { Write-Host "$prefix [WARN] $Message"  -ForegroundColor Yellow }
        "Error"   { Write-Host "$prefix [ERR] $Message"   -ForegroundColor Red }
        default   { Write-Host "$prefix $Message"         -ForegroundColor Gray }
    }
}

# ---------------------------------------------------------------------------
# .env parser
# ---------------------------------------------------------------------------

function Read-EnvFile {
    <#
    .SYNOPSIS
        Parses a .env file and returns a hashtable of key/value pairs.
        Lines starting with # and empty lines are ignored.
        Values may be optionally quoted with single or double quotes.
    .PARAMETER Path
        Full path to the .env file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $result = @{}

    Get-Content $Path -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()

        # Skip full-line comments and blank lines
        # NOTE: inline comments (value = something # comment) are NOT supported.
        # Paths like C:\#Folder would be wrongly truncated. Use comment-only lines.
        if ($line -eq '' -or $line.StartsWith('#')) { return }

        # Split on first '=' only
        $eqIdx = $line.IndexOf('=')
        if ($eqIdx -lt 1) { return }

        $key   = $line.Substring(0, $eqIdx).Trim()
        $value = $line.Substring($eqIdx + 1).Trim()

        # Strip optional surrounding quotes (single or double).
        # Only strip if BOTH the first and last character are the same quote type.
        if ($value.Length -ge 2) {
            $first = $value[0]
            $last  = $value[$value.Length - 1]
            if (($first -eq '"' -and $last -eq '"') -or
                ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        if ($key -ne '') {
            $result[$key] = $value
        }
    }

    return $result
}

# Mapping from .env key names to framework config property names
$script:EnvKeyMap = @{
    SERVER_INSTALL_PATH    = 'ServerInstallPath'
    STEAMCMD_PATH          = 'SteamCMDPath'
    WORKSHOP_STAGING_PATH  = 'WorkshopStagingPath'
    STEAM_USERNAME         = 'SteamUsername'
    STEAM_PASSWORD         = 'SteamPassword'
}

# ---------------------------------------------------------------------------
# Framework configuration
# ---------------------------------------------------------------------------

function Get-FrameworkConfig {
    <#
    .SYNOPSIS
        Reads .env from the repository root and returns a config object.
        .env is the single source of truth for all framework settings.
    .OUTPUTS
        PSCustomObject with all framework settings.
    #>
    [CmdletBinding()]
    param()

    # Walk up from the calling script's location to find .env
    $searchPath = $PSScriptRoot
    $envFile    = $null

    for ($i = 0; $i -lt 4; $i++) {
        $candidate = Join-Path $searchPath ".env"
        if (Test-Path $candidate) {
            $envFile = $candidate
            break
        }
        $searchPath = Split-Path -Parent $searchPath
    }

    if (-not $envFile) {
        Write-Log ".env not found. Copy .env.example to .env and fill in your values." "Error"
        exit 1
    }

    # --- Parse .env ---
    $env    = Read-EnvFile -Path $envFile
    $config = [PSCustomObject]@{}

    foreach ($envKey in $script:EnvKeyMap.Keys) {
        $jsonKey = $script:EnvKeyMap[$envKey]
        $value   = if ($env.ContainsKey($envKey)) { $env[$envKey] } else { '' }
        $config | Add-Member -NotePropertyName $jsonKey -NotePropertyValue $value -Force
    }

    Write-Log "Config loaded from .env ($envFile)" "Info"

    # --- Validate required keys ---
    # SteamUsername is only needed for Workshop mod downloads (Sync-Mods.ps1),
    # not for server installation/updates (those use anonymous login).
    $required = @("ServerInstallPath", "SteamCMDPath", "WorkshopStagingPath")
    foreach ($key in $required) {
        $prop = $config.PSObject.Properties[$key]
        $val  = if ($prop) { $prop.Value } else { $null }
        if ([string]::IsNullOrWhiteSpace($val)) {
            Write-Log "Required value '$key' is missing or empty in .env." "Error"
            Write-Log "Set $(($script:EnvKeyMap.GetEnumerator() | Where-Object Value -eq $key).Key) in your .env file." "Error"
            exit 1
        }
    }

    # Warn if SteamUsername is still placeholder (needed later for Sync-Mods.ps1)
    $steamUser = $config.PSObject.Properties["SteamUsername"]
    if (-not $steamUser -or [string]::IsNullOrWhiteSpace($steamUser.Value)) {
        Write-Log "STEAM_USERNAME is not set in .env. This is required for Sync-Mods.ps1." "Warning"
    } elseif ($steamUser.Value -eq "your_steam_username") {
        Write-Log "STEAM_USERNAME is still set to the placeholder value. Edit your .env before running Sync-Mods.ps1." "Warning"
    }

    return $config
}

# ---------------------------------------------------------------------------
# Profile loading
# ---------------------------------------------------------------------------

function Get-Profile {
    <#
    .SYNOPSIS
        Reads and validates a profile's profile.json.
    .PARAMETER ProfileName
        The profile folder name (e.g. "main", "tvt").
    .OUTPUTS
        PSCustomObject with all profile settings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileName
    )

    # Locate the profiles\ directory relative to this script
    $searchPath = $PSScriptRoot
    $profilesDir = $null

    for ($i = 0; $i -lt 4; $i++) {
        $candidate = Join-Path $searchPath "profiles"
        if (Test-Path $candidate) {
            $profilesDir = $candidate
            break
        }
        $searchPath = Split-Path -Parent $searchPath
    }

    if (-not $profilesDir) {
        Write-Log "profiles\ directory not found." "Error"
        exit 1
    }

    $profileDir  = Join-Path $profilesDir $ProfileName
    $profileFile = Join-Path $profileDir  "profile.json"

    if (-not (Test-Path $profileFile)) {
        Write-Log "Profile '$ProfileName' not found at '$profileFile'." "Error"
        Write-Log "Available profiles:" "Info"
        Get-ChildItem -Path $profilesDir -Directory | Where-Object { $_.Name -ne "_template" } |
            ForEach-Object { Write-Log "  - $($_.Name)" "Info" }
        exit 1
    }

    $profile = Get-Content $profileFile -Raw | ConvertFrom-Json

    # Inject computed paths
    $profile | Add-Member -NotePropertyName "ProfileDir"  -NotePropertyValue $profileDir  -Force
    $profile | Add-Member -NotePropertyName "LogDir"      -NotePropertyValue (Join-Path $profileDir "logs") -Force
    $profile | Add-Member -NotePropertyName "ServerCfg"   -NotePropertyValue (Join-Path $profileDir "server.cfg") -Force
    $profile | Add-Member -NotePropertyName "BasicCfg"    -NotePropertyValue (Join-Path $profileDir "basic.cfg")  -Force

    return $profile
}

# ---------------------------------------------------------------------------
# Log rotation
# ---------------------------------------------------------------------------

function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Moves existing Arma 3 RPT/log files from the profile directory into a
        timestamped session folder under <ProfileDir>\logs\ before a new start.
    .DESCRIPTION
        Arma 3 always writes its .rpt files directly into the -profiles= directory.
        This function archives them into sub-folders so the profile root stays clean:

            profiles\main\logs\2026-06-15_10-05-22\arma3server_....rpt
            profiles\main\logs\2026-06-15_10-05-22\hc_1_....rpt

        If -KeepSessions is specified the oldest session folders are pruned
        so at most that many sessions are retained.
    .PARAMETER ProfileDir
        Path to the profile directory (e.g. profiles\main).
    .PARAMETER LogDir
        Destination root for log archives.  Defaults to <ProfileDir>\logs.
    .PARAMETER KeepSessions
        Maximum number of session folders to keep.  0 = keep all (default).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProfileDir,

        [string]$LogDir = "",

        [int]$KeepSessions = 0
    )

    if (-not $LogDir) { $LogDir = Join-Path $ProfileDir "logs" }
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    # Collect all Arma 3 log / report files sitting directly in the profile root.
    # Covered types:
    #   .rpt  – main server / HC report logs  (arma3server*.rpt)
    #   .log  – server_console_*.log, mpStatistics_*.log, rating.log, etc.
    #   .txt  – mpMessageDetailsServer-*.txt  (message detail dumps)
    $files = @(Get-ChildItem -Path $ProfileDir -File |
               Where-Object { $_.Extension -in @(".rpt", ".log", ".txt") })

    if ($files.Count -eq 0) {
        Write-Log "Log rotation: no previous log files found." "Info"
        return
    }

    # Use the modification time of the newest file as the session label
    $sessionTs  = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    $sessionDir = Join-Path $LogDir ($sessionTs.ToString("yyyy-MM-dd_HH-mm-ss"))
    if (-not (Test-Path $sessionDir)) {
        New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null
    }

    foreach ($f in $files) {
        Move-Item -Path $f.FullName -Destination (Join-Path $sessionDir $f.Name) -Force
    }
    Write-Log "Log rotation: moved $($files.Count) file(s) → logs\$($sessionTs.ToString('yyyy-MM-dd_HH-mm-ss'))\" "Success"

    # Prune oldest session folders if requested
    if ($KeepSessions -gt 0) {
        $sessions = Get-ChildItem -Path $LogDir -Directory |
                    Sort-Object Name -Descending |
                    Select-Object -Skip $KeepSessions
        foreach ($old in $sessions) {
            Remove-Item -Path $old.FullName -Recurse -Force
            Write-Log "Log rotation: removed old session $($old.Name)" "Info"
        }
    }
}

# ---------------------------------------------------------------------------
# Steam credential helper
# ---------------------------------------------------------------------------

function Read-SteamPassword {
    <#
    .SYNOPSIS
        Returns the Steam password, either from .env (STEAM_PASSWORD) or by prompting
        the user interactively. The password is never written to disk by this function.
    .PARAMETER Username
        Steam account username (shown in prompt for clarity).
    .PARAMETER Config
        Framework config object (from Get-FrameworkConfig). If it contains a SteamPassword
        property (loaded from .env), no interactive prompt is shown.
    .OUTPUTS
        Plain-text password string (needed by SteamCMD command line).
    #>
    [CmdletBinding()]
    param(
        [string]$Username = "steam",

        [PSCustomObject]$Config = $null
    )

    # Use password from .env if available
    if ($Config -and
        $Config.PSObject.Properties.Name -contains "SteamPassword" -and
        -not [string]::IsNullOrWhiteSpace($Config.SteamPassword)) {

        Write-Log "Using Steam password from .env (STEAM_PASSWORD)." "Info"
        return $Config.SteamPassword
    }

    # Interactive prompt fallback
    Write-Log "Steam password required for account '$Username'." "Info"
    Write-Log "(Tip: set STEAM_PASSWORD in .env to skip this prompt.)" "Info"

    $securePass = Read-Host -Prompt "Steam password for '$Username'" -AsSecureString
    $bstr       = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
    $plainText  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    return $plainText
}

# ---------------------------------------------------------------------------
# Detached process launcher (SSH-safe)
# ---------------------------------------------------------------------------

function Start-DetachedProcess {
    <#
    .SYNOPSIS
        Start a process fully detached from the current SSH job object.

    .DESCRIPTION
        Standard Start-Process inherits the SSH session's Windows Job Object.
        When the SSH connection closes, Windows terminates every process in that
        job — including the game server.

        This function calls CreateProcess() with CREATE_BREAKAWAY_FROM_JOB so
        the new process is outside the SSH job and survives the session end.

    .PARAMETER FilePath
        Full path to the executable.

    .PARAMETER ArgumentList
        Array of arguments to pass. They are joined with spaces.

    .PARAMETER WorkingDirectory
        Working directory for the new process.

    .OUTPUTS
        PID of the new process as [int].
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $FilePath,
        [string[]]                         $ArgumentList    = @(),
        [string]                           $WorkingDirectory = $PWD.Path
    )

    # Define the Win32 shim only once per PowerShell session
    if (-not ([System.Management.Automation.PSTypeName]'Arma3.ProcessHelper').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Arma3 {
    public class ProcessHelper {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFO {
            public int    cb;
            public string lpReserved, lpDesktop, lpTitle;
            public uint   dwX, dwY, dwXSize, dwYSize;
            public uint   dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short  wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_INFORMATION {
            public IntPtr hProcess, hThread;
            public uint   dwProcessId, dwThreadId;
        }
        [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
        public static extern bool CreateProcess(
            string lpApplicationName, string lpCommandLine,
            IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
            bool bInheritHandles, uint dwCreationFlags,
            IntPtr lpEnvironment, string lpCurrentDirectory,
            ref STARTUPINFO lpStartupInfo,
            out PROCESS_INFORMATION lpProcessInformation);
        [DllImport("kernel32.dll", SetLastError=true)]
        public static extern bool CloseHandle(IntPtr h);

        // CREATE_BREAKAWAY_FROM_JOB | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW
        public const uint DETACH_FLAGS = 0x01000200u | 0x08000000u;
    }
}
'@
    }

    $si       = New-Object Arma3.ProcessHelper+STARTUPINFO
    $si.cb    = [System.Runtime.InteropServices.Marshal]::SizeOf($si)
    $pi       = New-Object Arma3.ProcessHelper+PROCESS_INFORMATION
    $cmdLine  = "`"$FilePath`"" + $(if ($ArgumentList) { " " + ($ArgumentList -join " ") } else { "" })

    # Pass FilePath as lpApplicationName so Windows doesn't do a PATH search
    # (paths with '#' or spaces fail when lpApplicationName is null).
    # lpCommandLine still needs the exe as argv[0] for some programs.
    $ok = [Arma3.ProcessHelper]::CreateProcess(
        $FilePath, $cmdLine,
        [IntPtr]::Zero, [IntPtr]::Zero,
        $false, [Arma3.ProcessHelper]::DETACH_FLAGS,
        [IntPtr]::Zero, $WorkingDirectory,
        [ref]$si, [ref]$pi
    )

    if (-not $ok) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "CreateProcess failed (Win32 error $err): $(New-Object System.ComponentModel.Win32Exception($err))"
    }

    [Arma3.ProcessHelper]::CloseHandle($pi.hProcess) | Out-Null
    [Arma3.ProcessHelper]::CloseHandle($pi.hThread)  | Out-Null

    return [int]$pi.dwProcessId
}

# ---------------------------------------------------------------------------
# SteamCMD script-file helper
# ---------------------------------------------------------------------------

function Invoke-SteamCMD {
    <#
    .SYNOPSIS
        Runs SteamCMD using a temporary script file (+runscript) so that passwords
        with special characters (quotes, backslashes, $, #, etc.) are passed safely
        without any shell escaping issues.

    .PARAMETER SteamCMDExe
        Full path to steamcmd.exe.
    .PARAMETER Anonymous
        Use anonymous login. No Username / Password required.
        Suitable for App ID 233780 (Arma 3 Dedicated Server).
    .PARAMETER Username
        Steam account username. Required unless -Anonymous is set.
    .PARAMETER Password
        Steam account password (plain text, never written to permanent storage).
        Required unless -Anonymous is set.
    .PARAMETER Commands
        Array of SteamCMD commands to run after login, e.g.:
          @('force_install_dir "C:\Server"', 'app_update 233780 -beta profiling validate')
    .OUTPUTS
        Exit code of the SteamCMD process.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SteamCMDExe,

        [switch]$Anonymous,

        [string]$Username = "",

        [string]$Password = "",

        [Parameter(Mandatory)]
        [string[]]$Commands
    )

    if (-not $Anonymous -and [string]::IsNullOrWhiteSpace($Username)) {
        Write-Log "Invoke-SteamCMD: -Username is required when not using -Anonymous." "Error"
        exit 1
    }

    # Ensure SteamCMD can find its data directories when running under a
    # service account or SSH session that has no initialised user profile.
    if (-not $env:APPDATA) {
        $env:APPDATA = if ($env:USERPROFILE) {
            Join-Path $env:USERPROFILE "AppData\Roaming"
        } else { "$env:SystemRoot\Temp" }
    }
    if (-not $env:LOCALAPPDATA) {
        $env:LOCALAPPDATA = if ($env:USERPROFILE) {
            Join-Path $env:USERPROFILE "AppData\Local"
        } else { "$env:SystemRoot\Temp" }
    }
    if (-not $env:TEMP) { $env:TEMP = "$env:SystemRoot\Temp" }
    if (-not $env:TMP)  { $env:TMP  = $env:TEMP }
    foreach ($d in @($env:APPDATA, $env:LOCALAPPDATA)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # Write commands to a temporary script file.
    # Using a file avoids all shell-quoting issues with special chars in passwords.
    $scriptFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.steamcmd'

    try {
        if ($Anonymous) {
            $loginLine = "login anonymous"
            Write-Log "Running SteamCMD as anonymous..." "Info"
        } else {
            $loginLine = "login `"$Username`" `"$Password`""
            Write-Log "Running SteamCMD as '$Username'..." "Info"
        }

        $lines  = @($loginLine)
        $lines += $Commands
        $lines += "quit"
        Set-Content -Path $scriptFile -Value $lines -Encoding ASCII

        $proc = Start-Process -FilePath $SteamCMDExe `
                               -ArgumentList "+runscript `"$scriptFile`"" `
                               -NoNewWindow -Wait -PassThru

        return $proc.ExitCode
    } finally {
        # Always delete the script file – it may contain credentials
        if (Test-Path $scriptFile) {
            Remove-Item $scriptFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Arma 3 binary resolver
# ---------------------------------------------------------------------------

function Get-Arma3ServerBinary {
    <#
    .SYNOPSIS
        Returns the full path to the correct Arma 3 server binary for the given branch.
    .PARAMETER ServerInstallPath
        Root directory of the Arma 3 Dedicated Server installation.
    .PARAMETER Branch
        Steam branch: "public" or "profiling".
    .OUTPUTS
        Full path to the server executable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServerInstallPath,

        [ValidateSet("public", "profiling", "development")]
        [string]$Branch = "public"
    )

    # Profiling branch ships a dedicated profiling binary; fall back to standard if missing
    $candidates = if ($Branch -eq "profiling") {
        @("arma3serverprofiling_x64.exe", "arma3server_x64.exe")
    } else {
        @("arma3server_x64.exe")
    }

    foreach ($bin in $candidates) {
        $full = Join-Path $ServerInstallPath $bin
        if (Test-Path $full) {
            return $full
        }
    }

    Write-Log "No Arma 3 server binary found in '$ServerInstallPath'." "Error"
    Write-Log "Run .\setup\Install-Framework.ps1 first." "Error"
    exit 1
}

# ---------------------------------------------------------------------------
# Mod list builder
# ---------------------------------------------------------------------------

function Build-ModString {
    <#
    .SYNOPSIS
        Builds the semicolon-separated mod string for the -mod= parameter.
    .PARAMETER Mods
        Array of mod folder names (e.g. @("@cba_a3", "@ace")).
    .PARAMETER ServerInstallPath
        Root of the server installation (used to resolve relative mod paths).
    .OUTPUTS
        String ready to pass as -mod= value, or empty string if no mods.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Mods,
        [string]$ServerInstallPath
    )

    if (-not $Mods -or $Mods.Count -eq 0) {
        return ""
    }

    $resolved = foreach ($mod in $Mods) {
        $modPath = Join-Path $ServerInstallPath $mod
        if (-not (Test-Path $modPath)) {
            Write-Log "Mod folder not found: '$modPath'. Mod '$mod' will be skipped." "Warning"
            continue
        }
        $mod
    }

    return ($resolved -join ";")
}

# ---------------------------------------------------------------------------
# Process helpers
# ---------------------------------------------------------------------------

function Get-ServerProcesses {
    <#
    .SYNOPSIS
        Returns all running arma3server* processes.
    #>
    return Get-Process -Name "arma3server*" -ErrorAction SilentlyContinue
}

function Enter-FrameworkMaintenanceLock {
    <#
    .SYNOPSIS
        Acquires the cross-process lock used by server starts and maintenance jobs.
    .OUTPUTS
        An open FileStream when acquired, or $null when another operation holds it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory)]
        [string]$Purpose
    )

    New-Item -ItemType Directory -Path $Config.WorkshopStagingPath -Force | Out-Null
    $lockPath = Join-Path $Config.WorkshopStagingPath ".arma3-framework-maintenance.lock"

    try {
        $stream = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch [System.IO.IOException] {
        return $null
    }

    try {
        $payload = [ordered]@{
            ProcessId = $PID
            Purpose = $Purpose
            StartedAtUtc = [DateTime]::UtcNow.ToString("o")
        } | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
    } catch {
        $stream.Dispose()
        throw
    }

    Write-Output -NoEnumerate $stream
}

function Exit-FrameworkMaintenanceLock {
    <#
    .SYNOPSIS
        Releases a lock returned by Enter-FrameworkMaintenanceLock.
    #>
    [CmdletBinding()]
    param(
        [System.IO.FileStream]$Lock,
        [Parameter(Mandatory)]
        [PSCustomObject]$Config
    )

    if ($Lock) {
        $Lock.Dispose()
    }

    $lockPath = Join-Path $Config.WorkshopStagingPath ".arma3-framework-maintenance.lock"
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}

function Wait-ServerReady {
    <#
    .SYNOPSIS
        Waits until the Arma 3 server UDP port is accepting connections,
        or until the timeout is reached.
    .PARAMETER Port
        The game port to poll.
    .PARAMETER TimeoutSeconds
        Maximum wait time in seconds. Default: 120.
    #>
    [CmdletBinding()]
    param(
        [int]$Port = 2302,
        [int]$TimeoutSeconds = 120
    )

    Write-Log "Waiting for server on port $Port (timeout: ${TimeoutSeconds}s)..." "Info"

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $udpClient = New-Object System.Net.Sockets.UdpClient

    try {
        while ((Get-Date) -lt $deadline) {
            # Send a basic Steam A2S_INFO query packet
            $queryPacket = [byte[]]@(0xFF, 0xFF, 0xFF, 0xFF, 0x54) +
                           [System.Text.Encoding]::ASCII.GetBytes("Source Engine Query`0")
            try {
                $udpClient.Send($queryPacket, $queryPacket.Length, "127.0.0.1", $Port) | Out-Null
                $udpClient.Client.ReceiveTimeout = 1000
                $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
                $udpClient.Receive([ref]$ep) | Out-Null
                Write-Log "Server is responding on port $Port." "Success"
                return $true
            } catch {
                Start-Sleep -Seconds 5
            }
        }
    } finally {
        $udpClient.Close()
    }

    Write-Log "Server did not respond within ${TimeoutSeconds}s. Continuing anyway..." "Warning"
    return $false
}

# ---------------------------------------------------------------------------
# Profile listing helper
# ---------------------------------------------------------------------------

function Get-AvailableProfiles {
    <#
    .SYNOPSIS
        Returns the names of all profiles (excluding _template).
    #>
    $searchPath = $PSScriptRoot
    for ($i = 0; $i -lt 4; $i++) {
        $candidate = Join-Path $searchPath "profiles"
        if (Test-Path $candidate) {
            return (Get-ChildItem -Path $candidate -Directory |
                    Where-Object { $_.Name -ne "_template" } |
                    Select-Object -ExpandProperty Name)
        }
        $searchPath = Split-Path -Parent $searchPath
    }
    return @()
}
