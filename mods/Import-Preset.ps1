#Requires -Version 5.1
<#
.SYNOPSIS
    Imports an Arma 3 Launcher HTML preset file into a server profile.

.DESCRIPTION
    Parses an Arma 3 Launcher mod preset (.html) exported from the Arma 3 Launcher
    and writes the Workshop IDs and mod folder names into a profile's profile.json.

    After importing, run Sync-Mods.ps1 to download the mods.

.PARAMETER PresetFile
    Path to the Arma 3 Launcher HTML preset file.

.PARAMETER Profile
    Target profile name (folder under profiles\). The profile must already exist.
    Use _template to preview without writing (combine with -WhatIf).

.PARAMETER Merge
    If set, adds mods from the preset to the profile's existing WorkshopIds list
    (deduplicating by Workshop ID). By default, the existing list is replaced.

.PARAMETER SyncAfter
    Automatically run Sync-Mods.ps1 after a successful import.

.PARAMETER WhatIf
    Show what would be imported without writing any changes.

.EXAMPLE
    # Import into the main profile (replaces mod list)
    .\Import-Preset.ps1 -PresetFile "C:\Users\me\Downloads\MyPreset.html" -Profile main

    # Merge new mods into the tvt profile without removing existing ones
    .\Import-Preset.ps1 -PresetFile "C:\Users\me\Downloads\MyPreset.html" -Profile tvt -Merge

    # Preview what would be imported
    .\Import-Preset.ps1 -PresetFile "C:\Users\me\Downloads\MyPreset.html" -Profile main -WhatIf

    # Import and immediately download all mods
    .\Import-Preset.ps1 -PresetFile "C:\Users\me\Downloads\MyPreset.html" -Profile main -SyncAfter
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$PresetFile,

    [Parameter(Mandatory)]
    [string]$Profile,

    [switch]$Merge,

    [switch]$SyncAfter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
$ScriptRoot    = Split-Path -Parent $MyInvocation.MyCommand.Path
$FrameworkRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $FrameworkRoot "scripts\Common.ps1")

$RequiredServerMods = @("@grp9_stats_server")

function Add-UniqueString {
    param(
        [string[]]$Items,
        [string[]]$Required
    )

    $result = @()
    $seen = @{}

    foreach ($item in @($Items + $Required)) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        $key = $item.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $result += $item
    }

    return [string[]]$result
}

# ---------------------------------------------------------------------------
# Validate input file
# ---------------------------------------------------------------------------
if (-not (Test-Path $PresetFile)) {
    Write-Log "Preset file not found: '$PresetFile'" "Error"
    exit 1
}

$extension = [System.IO.Path]::GetExtension($PresetFile).ToLower()
if ($extension -notin @(".html", ".htm")) {
    Write-Log "Expected an .html file, got: $extension" "Error"
    exit 1
}

# ---------------------------------------------------------------------------
# Parse the HTML (it is valid XML, exported by the Arma 3 Launcher)
# ---------------------------------------------------------------------------
Write-Log "Parsing preset: $(Split-Path -Leaf $PresetFile)" "Info"

[xml]$doc = Get-Content -Path $PresetFile -Raw -Encoding UTF8

# Find all <tr data-type="ModContainer"> elements
$modRows = $doc.SelectNodes("//tr[@data-type='ModContainer']")

if ($modRows.Count -eq 0) {
    Write-Log "No mods found in preset file. Make sure this is a valid Arma 3 Launcher preset." "Error"
    exit 1
}

Write-Log "Found $($modRows.Count) mod(s) in preset." "Info"

# ---------------------------------------------------------------------------
# Extract Workshop IDs and display names
# ---------------------------------------------------------------------------
function ConvertTo-FolderName {
    <#
    .SYNOPSIS
        Converts a mod display name to a safe @FolderName.
    #>
    param([string]$DisplayName)

    # Remove/replace characters that are unsafe in Windows folder names
    $safe = $DisplayName.Trim()
    $safe = $safe -replace '[:\\/*?"<>|]', ''   # forbidden Windows chars
    $safe = $safe -replace '[\s\-]+', '_'        # spaces and hyphens -> underscore
    $safe = $safe -replace '[^\w]', ''           # remove remaining non-word chars
    $safe = $safe -replace '_+', '_'             # collapse multiple underscores
    $safe = $safe.Trim('_')                      # strip leading/trailing underscores
    $safe = $safe.ToLower()

    return "@$safe"
}

$parsed = [System.Collections.Generic.List[hashtable]]::new()

foreach ($row in $modRows) {
    # DisplayName cell
    $nameNode  = $row.SelectSingleNode("td[@data-type='DisplayName']")
    $linkNode  = $row.SelectSingleNode(".//a[@data-type='Link']")

    if (-not $nameNode -or -not $linkNode) { continue }

    $displayName = $nameNode.InnerText.Trim()
    $url         = $linkNode.InnerText.Trim()

    # Extract Workshop ID from URL (?id=XXXXXXX)
    if ($url -match '[?&]id=(\d+)') {
        $workshopId = $Matches[1]
    } else {
        Write-Log "Could not extract Workshop ID from URL: $url  (skipping '$displayName')" "Warning"
        continue
    }

    $folderName = ConvertTo-FolderName -DisplayName $displayName

    $parsed.Add(@{
        Id          = $workshopId
        FolderName  = $folderName
        DisplayName = $displayName
    })
}

if ($parsed.Count -eq 0) {
    Write-Log "No valid mods could be parsed from the preset." "Error"
    exit 1
}

# ---------------------------------------------------------------------------
# Show what was parsed
# ---------------------------------------------------------------------------
Write-Log "" "Info"
Write-Log "=== Parsed Mods ===" "Header"
$parsed | ForEach-Object {
    Write-Log ("  [{0,-12}]  {1,-38}  {2}" -f $_.Id, $_.FolderName, $_.DisplayName) "Info"
}
Write-Log "" "Info"

# ---------------------------------------------------------------------------
# WhatIf / dry run
# ---------------------------------------------------------------------------
if ($WhatIfPreference) {
    Write-Log "WhatIf: no changes written." "Warning"
    exit 0
}

# ---------------------------------------------------------------------------
# Load target profile
# ---------------------------------------------------------------------------
$prof        = Get-Profile -ProfileName $Profile
$profileFile = Join-Path $prof.ProfileDir "profile.json"

$profileData = Get-Content $profileFile -Raw | ConvertFrom-Json

# ---------------------------------------------------------------------------
# Build updated WorkshopIds and Mods arrays
# ---------------------------------------------------------------------------
if ($Merge) {
    # Keep existing entries, add new ones (deduplicated by Id)
    $existingIds = @{}
    if ($profileData.PSObject.Properties.Name -contains "WorkshopIds") {
        foreach ($existing in $profileData.WorkshopIds) {
            $existingIds[$existing.Id] = $true
        }
    }

    $toAdd = @($parsed | Where-Object { -not $existingIds.ContainsKey($_.Id) })
    Write-Log "Merge mode: adding $($toAdd.Count) new mod(s), keeping $($existingIds.Count) existing." "Info"

    $newWorkshopIds = @()
    if ($profileData.PSObject.Properties.Name -contains "WorkshopIds") {
        $newWorkshopIds += @($profileData.WorkshopIds)
    }
    foreach ($mod in $toAdd) {
        $newWorkshopIds += [PSCustomObject]@{
            Id         = $mod.Id
            FolderName = $mod.FolderName
            _name      = $mod.DisplayName
        }
    }
} else {
    # Replace the entire list
    Write-Log "Replace mode: replacing mod list with $($parsed.Count) mod(s) from preset." "Info"

    $newWorkshopIds = @($parsed | ForEach-Object {
        [PSCustomObject]@{
            Id         = $_.Id
            FolderName = $_.FolderName
            _name      = $_.DisplayName
        }
    })
}

# Build Mods array (just the folder names, for -mod= parameter).
# Client-side GRP9 mods are published through Steam Workshop and should come
# from the imported preset instead of being forced into every profile.
$newMods = @(Add-UniqueString `
    -Items ([string[]]($newWorkshopIds | Select-Object -ExpandProperty FolderName)) `
    -Required @())

# ---------------------------------------------------------------------------
# Format profile.json in a clean, human-readable style:
#   - scalar properties inline
#   - string arrays (Mods/ServerMods/ExtraArgs) one entry per line
#   - WorkshopIds as inline objects with column-aligned padding
# ---------------------------------------------------------------------------
function Format-ProfileJson {
    param(
        [PSCustomObject]$Data,
        [object[]]$WorkshopIds,
        [string[]]$Mods,
        [string[]]$ServerMods,
        [string[]]$ExtraArgs
    )

    $sb = [System.Text.StringBuilder]::new()
    $nl = "`n"

    $null = $sb.Append("{$nl")

    # Scalar properties in a fixed, readable order
    $scalarOrder = @('_comment','ProfileName','Port','Branch','MaxPlayers','FPSLimit','EnableAutoInit','HeadlessClientCount')
    foreach ($key in $scalarOrder) {
        if ($Data.PSObject.Properties.Name -notcontains $key) { continue }
        $val = $Data.$key
        if ($val -is [bool]) {
            $v = if ($val) { 'true' } else { 'false' }
            $null = $sb.Append("  `"$key`": $v,$nl")
        } elseif ($val -is [int] -or $val -is [long] -or $val -is [double]) {
            $null = $sb.Append("  `"$key`": $val,$nl")
        } else {
            $escaped = "$val" -replace '\\', '\\' -replace '"', '\"'
            $null = $sb.Append("  `"$key`": `"$escaped`",$nl")
        }
    }

    # Helper: write a string array property
    $writeStringArray = {
        param([string]$Name, [string[]]$Items, [bool]$TrailingComma = $true)
        $comma = if ($TrailingComma) { ',' } else { '' }
        if ($Items.Count -eq 0) {
            $null = $sb.Append("  `"$Name`": []$comma$nl")
        } else {
            $null = $sb.Append("  `"$Name`": [$nl")
            for ($i = 0; $i -lt $Items.Count; $i++) {
                $c = if ($i -lt $Items.Count - 1) { ',' } else { '' }
                $null = $sb.Append("    `"$($Items[$i])`"$c$nl")
            }
            $null = $sb.Append("  ]$comma$nl")
        }
    }

    & $writeStringArray "Mods"       $Mods       $true
    & $writeStringArray "ServerMods" $ServerMods $true
    & $writeStringArray "ExtraArgs"  $ExtraArgs  $true

    # WorkshopIds – inline objects with column-aligned spacing BETWEEN fields,
    # never inside the string values (trailing spaces in paths break Copy-Item).
    if ($WorkshopIds.Count -eq 0) {
        $null = $sb.Append("  `"WorkshopIds`": []$nl")
    } else {
        $maxId  = ($WorkshopIds | ForEach-Object { "$($_.Id)".Length }         | Measure-Object -Maximum).Maximum
        $maxFld = ($WorkshopIds | ForEach-Object { "$($_.FolderName)".Length } | Measure-Object -Maximum).Maximum

        $null = $sb.Append("  `"WorkshopIds`": [$nl")
        for ($i = 0; $i -lt $WorkshopIds.Count; $i++) {
            $m        = $WorkshopIds[$i]
            $c        = if ($i -lt $WorkshopIds.Count - 1) { ',' } else { '' }
            $nameEsc  = "$($m._name)" -replace '\\', '\\' -replace '"', '\"'
            # Padding goes AFTER the comma, not inside the string value
            $idGap    = ' ' * ($maxId  - "$($m.Id)".Length  + 2)
            $fldGap   = ' ' * ($maxFld - "$($m.FolderName)".Length + 2)
            $null = $sb.Append("    { `"Id`": `"$($m.Id)`",$idGap`"FolderName`": `"$($m.FolderName)`",$fldGap`"_name`": `"$nameEsc`" }$c$nl")
        }
        $null = $sb.Append("  ]$nl")
    }

    $null = $sb.Append("}")
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Write updated profile.json
# ---------------------------------------------------------------------------
$profileData | Add-Member -NotePropertyName "WorkshopIds" -NotePropertyValue $newWorkshopIds -Force
$profileData | Add-Member -NotePropertyName "Mods"        -NotePropertyValue $newMods        -Force

$existingServerMods = @()
if ($profileData.PSObject.Properties.Name -contains "ServerMods") {
    $existingServerMods = @($profileData.ServerMods | Where-Object { $_ })
}
$existingServerMods = @(Add-UniqueString `
    -Items ([string[]]$existingServerMods) `
    -Required $RequiredServerMods)

$existingExtraArgs = @()
if ($profileData.PSObject.Properties.Name -contains "ExtraArgs") {
    $existingExtraArgs = @($profileData.ExtraArgs | Where-Object { $_ })
}

$json = Format-ProfileJson `
    -Data        $profileData `
    -WorkshopIds $newWorkshopIds `
    -Mods        ([string[]]$newMods) `
    -ServerMods  ([string[]]$existingServerMods) `
    -ExtraArgs   ([string[]]$existingExtraArgs)

Set-Content -Path $profileFile -Value $json -Encoding UTF8 -NoNewline

Write-Log "profile.json updated: $profileFile" "Success"
Write-Log "  WorkshopIds : $($newWorkshopIds.Count) mods" "Info"
Write-Log "  Mods[]      : $($newMods.Count) folder names" "Info"
Write-Log "  ServerMods  : $($existingServerMods.Count) folder names" "Info"
Write-Log "  Required server mods: $($RequiredServerMods -join ', ')" "Info"

# ---------------------------------------------------------------------------
# Optional: run Sync-Mods.ps1 immediately
# ---------------------------------------------------------------------------
if ($SyncAfter) {
    Write-Log "" "Info"
    Write-Log "=== Starting Sync-Mods.ps1 -Profile $Profile ===" "Header"
    $syncScript = Join-Path $ScriptRoot "Sync-Mods.ps1"
    & $syncScript -Profile $Profile
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Log "" "Info"
Write-Log "=== Import Complete ===" "Header"
Write-Log "Next step: .\mods\Sync-Mods.ps1 -Profile $Profile" "Info"
