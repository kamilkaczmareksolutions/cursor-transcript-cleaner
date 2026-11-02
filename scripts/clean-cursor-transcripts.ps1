#Requires -Version 5.1
<#
.SYNOPSIS
  Report Cursor transcript and chat disk use, archive old agent-transcript jsonl
  files, and restore them 1:1. Windows PowerShell 5.1 and 7. No dependencies.
.DESCRIPTION
  Default (no switches) is a read-only report. Omitting -Apply is a dry-run.
  -WhatIf with -Apply also keeps the run read-only. Cursor must be quit for -Apply.
#>
[CmdletBinding(DefaultParameterSetName = 'Report')]
param(
    [string]$UserProfile,
    [string]$AppData,

    [Parameter(ParameterSetName = 'Archive', Mandatory = $true)]
    [switch]$Archive,

    [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
    [switch]$Restore,

    [Parameter(ParameterSetName = 'Archive', Mandatory = $true)]
    [ValidateRange(0, 36500)]
    [int]$OlderThanDays,

    [Parameter(ParameterSetName = 'Archive')]
    [Parameter(ParameterSetName = 'Restore')]
    [string]$ArchivePath,

    [Parameter(ParameterSetName = 'Archive')]
    [Parameter(ParameterSetName = 'Restore')]
    [switch]$Apply,

    [Parameter(ParameterSetName = 'Archive')]
    [Parameter(ParameterSetName = 'Restore')]
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$Script:CursorUserProfileOverride = $null
$Script:CursorAppDataOverride = $null

function Set-CursorRootOverride {
    param(
        [string]$UserProfile,
        [string]$AppData
    )
    $Script:CursorUserProfileOverride = $UserProfile
    $Script:CursorAppDataOverride = $AppData
}

function Clear-CursorRootOverride {
    $Script:CursorUserProfileOverride = $null
    $Script:CursorAppDataOverride = $null
}

function Get-PathClassTable {
    return @(
        [pscustomobject]@{
            Class       = 'AgentTranscriptJsonl'
            RootKind    = 'UserProfileCursor'
            ScanUnder   = 'projects\*\agent-transcripts'
            Pattern     = '(?i)^projects\\[^\\]+\\agent-transcripts\\([^\\]+)\\\1\.jsonl$'
            Examples    = @('projects\c-Users-YOU-app\agent-transcripts\6f1e\6f1e.jsonl')
            Disposition = 'Archive'
        },
        [pscustomobject]@{
            Class       = 'AgentTranscriptOther'
            RootKind    = 'UserProfileCursor'
            ScanUnder   = 'projects\*\agent-transcripts'
            Pattern     = '(?i)^projects\\[^\\]+\\agent-transcripts\\'
            Examples    = @(
                'projects\c-Users-YOU-app\agent-transcripts\sub\t3.txt',
                'projects\c-Users-YOU-app\agent-transcripts\6f1e\other.jsonl',
                'projects\c-Users-YOU-app\agent-transcripts\flat.jsonl'
            )
            Disposition = 'Report'
        },
        [pscustomobject]@{
            Class       = 'GlobalChatDb'
            RootKind    = 'AppDataCursorUser'
            ScanUnder   = 'globalStorage'
            Pattern     = '(?i)^globalStorage\\state\.vscdb(-wal|-shm|\.backup)?$'
            Examples    = @(
                'globalStorage\state.vscdb',
                'globalStorage\state.vscdb-wal',
                'globalStorage\state.vscdb-shm',
                'globalStorage\state.vscdb.backup'
            )
            Disposition = 'Report'
        },
        [pscustomobject]@{
            Class       = 'WorkspaceChatTree'
            RootKind    = 'AppDataCursorUser'
            ScanUnder   = 'workspaceStorage\*'
            Pattern     = '(?i)^workspaceStorage\\[^\\]+\\.+$'
            Examples    = @(
                'workspaceStorage\abc123\state.vscdb',
                'workspaceStorage\abc123\state.vscdb-wal',
                'workspaceStorage\abc123\workspace.json',
                'workspaceStorage\abc123\images\x.png'
            )
            Disposition = 'Report'
        }
    )
}

function Get-CursorRoots {
    $profileRoot = $Script:CursorUserProfileOverride
    if (-not $profileRoot) { $profileRoot = $env:USERPROFILE }
    $appDataRoot = $Script:CursorAppDataOverride
    if (-not $appDataRoot) { $appDataRoot = $env:APPDATA }
    if (-not $profileRoot) { throw 'USERPROFILE is not set.' }
    if (-not $appDataRoot) { throw 'APPDATA is not set.' }
    return [pscustomobject]@{
        UserProfileCursor = (Join-Path $profileRoot '.cursor')
        AppDataCursorUser = (Join-Path $appDataRoot 'Cursor\User')
    }
}

function Resolve-CursorRoot {
    param(
        [Parameter(Mandatory = $true)][string]$RootKind,
        [Parameter(Mandatory = $true)]$Roots
    )
    switch ($RootKind) {
        'UserProfileCursor' { return $Roots.UserProfileCursor }
        'AppDataCursorUser' { return $Roots.AppDataCursorUser }
        default { throw "unhandled RootKind $RootKind" }
    }
}

function Resolve-PathClass {
    param(
        [Parameter(Mandatory = $true)][string]$RootKind,
        [Parameter(Mandatory = $true)][string]$RelativeKey
    )
    $key = ($RelativeKey -replace '/', '\').TrimStart('\')
    foreach ($row in Get-PathClassTable) {
        if ($row.RootKind -ne $RootKind) { continue }
        if ($key -match $row.Pattern) { return $row }
    }
    return $null
}

function ConvertTo-RelativeKey {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$FullPath
    )
    $root = [System.IO.Path]::GetFullPath($RootPath.TrimEnd('\', '/'))
    $full = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is not under root: $FullPath"
    }
    $rel = $full.Substring($root.Length).TrimStart('\', '/')
    if ($rel -match '\.\.' -or $rel -match ':') {
        throw "Invalid relative key: $rel"
    }
    return ($rel -replace '/', '\')
}

function Get-ExpectedSlug {
    param([Parameter(Mandatory = $true)][string]$FolderPath)
    $p = $FolderPath.TrimEnd('\')
    if ($p -match '^([A-Za-z]):(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2]
    } else {
        return $null
    }
    $rest = $rest -replace '[\\.]', '-'
    $rest = $rest -replace '\s+', '-'
    $rest = $rest -replace '[()]', ''
    $rest = [regex]::Replace($rest, '[^\x00-\x7F]', '-')
    $rest = $rest -replace '--+', '-'
    $rest = $rest.Trim('-')
    return "$drive-$rest"
}

function Get-SlugKey {
    param([Parameter(Mandatory = $true)][string]$Text)
    return ([regex]::Replace($Text.ToLowerInvariant(), '[^a-z0-9]+', '-')).Trim('-')
}

function Normalize-FsPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    try {
        $decoded = [uri]::UnescapeDataString($Path)
        $decoded = $decoded -replace '^file:///', '' -replace '^file:/', ''
        return ($decoded -replace '/', '\').TrimEnd('\')
    } catch {
        return $Path.TrimEnd('\')
    }
}

function Find-ProjectSlug {
    param(
        [Parameter(Mandatory = $true)][string]$FolderPath,
        [Parameter(Mandatory = $true)][string]$ProjectsRoot
    )
    $expected = Get-ExpectedSlug $FolderPath
    if ($expected -and (Test-Path (Join-Path $ProjectsRoot $expected))) {
        return $expected
    }
    $key = Get-SlugKey $FolderPath
    $found = @(Get-ChildItem $ProjectsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { (Get-SlugKey $_.Name) -eq $key })
    if ($found.Count -eq 1) { return $found[0].Name }
    return $expected
}

function New-ClassifiedFile {
    param(
        [Parameter(Mandatory = $true)][string]$RootKind,
        [Parameter(Mandatory = $true)][string]$RelativeKey,
        [Parameter(Mandatory = $true)][string]$FullPath,
        [Parameter(Mandatory = $true)][long]$Length,
        [Parameter(Mandatory = $true)][datetime]$LastWriteTimeUtc,
        [string]$ProjectPath,
        [string]$Slug,
        [string]$WorkspaceHash,
        [string]$ScopeKey
    )
    $row = Resolve-PathClass -RootKind $RootKind -RelativeKey $RelativeKey
    if (-not $row) { throw "Unclassified file: $RelativeKey" }
    if ($Length -lt 0) { throw 'Length must be non-negative.' }
    if ($RelativeKey -match '\.\.' -or $RelativeKey -match ':' -or $RelativeKey.StartsWith('\')) {
        throw "Invalid RelativeKey: $RelativeKey"
    }
    [pscustomobject]@{
        Class             = $row.Class
        Disposition       = $row.Disposition
        RootKind          = $RootKind
        RelativeKey       = $RelativeKey
        FullPath          = $FullPath
        Length            = $Length
        LastWriteTimeUtc  = $LastWriteTimeUtc
        ProjectPath       = $ProjectPath
        Slug              = $Slug
        WorkspaceHash     = $WorkspaceHash
        ScopeKey          = $ScopeKey
    }
}

function New-WorkspaceBinding {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceHash,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [string]$Slug
    )
    [pscustomobject]@{
        WorkspaceHash = $WorkspaceHash
        ProjectPath   = $ProjectPath
        Slug          = $Slug
    }
}

function New-WorkspaceRollup {
    param(
        [Parameter(Mandatory = $true)][string]$ScopeKey,
        [string]$ProjectPath,
        [string]$Slug,
        [string]$WorkspaceHash,
        [Parameter(Mandatory = $true)][long]$TranscriptBytes,
        [Parameter(Mandatory = $true)][long]$ChatBytes,
        [AllowNull()]
        [datetime]$LastActivityUtc,
        [Parameter(Mandatory = $true)][int]$TranscriptFiles,
        [Parameter(Mandatory = $true)][int]$ChatFiles
    )
    [pscustomobject]@{
        ScopeKey         = $ScopeKey
        ProjectPath      = $ProjectPath
        Slug             = $Slug
        WorkspaceHash    = $WorkspaceHash
        TranscriptBytes  = $TranscriptBytes
        ChatBytes        = $ChatBytes
        TotalBytes       = ($TranscriptBytes + $ChatBytes)
        LastActivityUtc  = $LastActivityUtc
        TranscriptFiles  = $TranscriptFiles
        ChatFiles        = $ChatFiles
    }
}

function New-ManifestEntry {
    param(
        [Parameter(Mandatory = $true)][string]$RelativeKey,
        [Parameter(Mandatory = $true)][string]$RootKind,
        [Parameter(Mandatory = $true)][string]$Class,
        [Parameter(Mandatory = $true)][long]$Length,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][datetime]$LastWriteTimeUtc,
        [string]$ProjectPath,
        [Parameter(Mandatory = $true)][datetime]$ArchivedUtc
    )
    $hash = $Sha256.ToUpperInvariant()
    if ($hash -notmatch '^[0-9A-F]{64}$') { throw 'Sha256 must be 64 uppercase hex digits.' }
    if (-not $Class) { throw 'Class is required.' }
    [pscustomobject]@{
        RelativeKey      = $RelativeKey
        RootKind         = $RootKind
        Class            = $Class
        Length           = $Length
        Sha256           = $hash
        LastWriteTimeUtc = $LastWriteTimeUtc
        ProjectPath      = $ProjectPath
        ArchivedUtc      = $ArchivedUtc
    }
}

function New-ManifestDocument {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Entries)
    $seen = @{}
    foreach ($e in $Entries) {
        if ($seen.ContainsKey($e.RelativeKey)) { throw "Duplicate RelativeKey: $($e.RelativeKey)" }
        $seen[$e.RelativeKey] = $true
    }
    [pscustomobject]@{
        ManifestVersion = 1
        Entries         = $Entries
    }
}

function New-LiveProbe {
    param(
        [Parameter(Mandatory = $true)][string]$RelativeKey,
        [Parameter(Mandatory = $true)][bool]$Exists,
        [string]$Sha256,
        [long]$Length
    )
    [pscustomobject]@{
        RelativeKey = $RelativeKey
        Exists      = $Exists
        Sha256      = $Sha256
        Length      = $Length
    }
}

function New-FileAction {
    param(
        [Parameter(Mandatory = $true)][string]$Outcome,
        [Parameter(Mandatory = $true)][string]$RelativeKey,
        [string]$RootKind,
        [string]$Class,
        [string]$LivePath,
        [long]$Length,
        [string]$LiveSha256,
        [string]$ArchiveSha256,
        [string]$ProjectPath
    )
    $writeOutcomes = @('CopyThenDelete', 'DeleteLive', 'Extract', 'AlreadyThere')
    if ($writeOutcomes -contains $Outcome) {
        if (-not $Class) { throw "Class required for outcome $Outcome" }
        $row = Resolve-PathClass -RootKind $RootKind -RelativeKey $RelativeKey
        if (-not $row -or $row.Class -ne $Class -or $row.Disposition -ne 'Archive') {
            throw "Outcome $Outcome requires an Archive class match for $RelativeKey"
        }
    }
    switch ($Outcome) {
        'Conflict' {
            if (-not $LiveSha256 -or -not $ArchiveSha256) { throw 'Conflict requires both hashes.' }
            if ($LiveSha256 -eq $ArchiveSha256) { throw 'Conflict requires different hashes.' }
        }
        'Rejected' { }
        { $_ -in $writeOutcomes } { }
        default { throw "unhandled Outcome $Outcome" }
    }
    [pscustomobject]@{
        Outcome       = $Outcome
        RelativeKey   = $RelativeKey
        RootKind      = $RootKind
        Class         = $Class
        LivePath      = $LivePath
        Length        = $Length
        LiveSha256    = $LiveSha256
        ArchiveSha256 = $ArchiveSha256
        ProjectPath   = $ProjectPath
    }
}

function Get-DefaultArchivePath {
    $profileRoot = $Script:CursorUserProfileOverride
    if (-not $profileRoot) { $profileRoot = $env:USERPROFILE }
    return (Join-Path $profileRoot 'cursor-transcript-archives\cursor-transcripts.zip')
}

function Get-ArchiveSidecars {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)
    return @{
        Partial = "$ArchivePath.partial"
        Prev    = "$ArchivePath.prev"
        Lock    = "$ArchivePath.lock"
    }
}

function ConvertTo-ZipEntryName {
    param([Parameter(Mandatory = $true)][string]$RelativeKey)
    return 'files/' + ($RelativeKey -replace '\\', '/')
}

function Join-WorkspaceBindings {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$WorkspaceRows,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SlugNames,
        [Parameter(Mandatory = $true)][string]$ProjectsRoot
    )
    $bindings = @()
    $usedSlugs = @{}
    foreach ($row in $WorkspaceRows) {
        $slug = $null
        if ($row.ProjectPath) {
            $candidate = Find-ProjectSlug -FolderPath $row.ProjectPath -ProjectsRoot $ProjectsRoot
            if ($candidate -and ($SlugNames -contains $candidate)) {
                $slug = $candidate
                $usedSlugs[$slug] = $true
            }
        }
        $bindings += (New-WorkspaceBinding -WorkspaceHash $row.WorkspaceHash -ProjectPath $row.ProjectPath -Slug $slug)
    }
    $unmatched = @($SlugNames | Where-Object { -not $usedSlugs.ContainsKey($_) })
    return @{
        Bindings        = $bindings
        UnmatchedSlugs  = $unmatched
    }
}

function Get-ScopedClassifiedFiles {
    param(
        [Parameter(Mandatory = $true)][array]$Files,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Bindings
    )
    $byHash = @{}
    $bySlug = @{}
    foreach ($b in $Bindings) {
        if ($b.ProjectPath) { $byHash[$b.WorkspaceHash] = $b }
        if ($b.Slug) { $bySlug[$b.Slug] = $b }
    }
    $out = @()
    foreach ($f in $Files) {
        $projectPath = $f.ProjectPath
        $slug = $f.Slug
        $workspaceHash = $f.WorkspaceHash
        $scopeKey = $f.ScopeKey
        switch ($f.Class) {
            'GlobalChatDb' {
                $scopeKey = 'global'
                $projectPath = $null
            }
            'WorkspaceChatTree' {
                $parts = $f.RelativeKey -split '\\'
                $hash = $parts[1]
                $workspaceHash = $hash
                $b = $byHash[$hash]
                if ($b -and $b.ProjectPath) {
                    $scopeKey = 'path:' + $b.ProjectPath.ToLowerInvariant()
                    $projectPath = $b.ProjectPath
                    $slug = $b.Slug
                } else {
                    $scopeKey = 'hash:' + $hash
                    $projectPath = $null
                }
            }
            { $_ -in 'AgentTranscriptJsonl', 'AgentTranscriptOther' } {
                $parts = $f.RelativeKey -split '\\'
                $slug = $parts[1]
                $b = $bySlug[$slug]
                if ($b -and $b.ProjectPath) {
                    $scopeKey = 'path:' + $b.ProjectPath.ToLowerInvariant()
                    $projectPath = $b.ProjectPath
                    $workspaceHash = $b.WorkspaceHash
                } else {
                    $scopeKey = 'slug:' + $slug
                    $projectPath = $null
                }
            }
            default { }
        }
        $out += (New-ClassifiedFile -RootKind $f.RootKind -RelativeKey $f.RelativeKey -FullPath $f.FullPath `
            -Length $f.Length -LastWriteTimeUtc $f.LastWriteTimeUtc -ProjectPath $projectPath `
            -Slug $slug -WorkspaceHash $workspaceHash -ScopeKey $scopeKey)
    }
    return $out
}

function Get-WorkspaceRollup {
    param([Parameter(Mandatory = $true)][array]$Files)
    $groups = $Files | Group-Object -Property ScopeKey
    $rollups = @()
    foreach ($g in $groups) {
        $items = @($g.Group)
        $first = $items[0]
        $transcriptClasses = @('AgentTranscriptJsonl', 'AgentTranscriptOther')
        $chatClasses = @('WorkspaceChatTree', 'GlobalChatDb')
        $transcriptItems = @($items | Where-Object { $_.Class -in $transcriptClasses })
        $chatItems = @($items | Where-Object { $_.Class -in $chatClasses })
        $last = $null
        foreach ($t in $transcriptItems) {
            if (-not $last -or $t.LastWriteTimeUtc -gt $last) { $last = $t.LastWriteTimeUtc }
        }
        $transcriptSum = ($transcriptItems | Measure-Object -Property Length -Sum).Sum
        $chatSum = ($chatItems | Measure-Object -Property Length -Sum).Sum
        if (-not $transcriptSum) { $transcriptSum = 0 }
        if (-not $chatSum) { $chatSum = 0 }
        $rollupParams = @{
            ScopeKey        = $g.Name
            ProjectPath     = $first.ProjectPath
            Slug            = $first.Slug
            WorkspaceHash   = $first.WorkspaceHash
            TranscriptBytes = $transcriptSum
            ChatBytes       = $chatSum
            TranscriptFiles = $transcriptItems.Count
            ChatFiles       = $chatItems.Count
        }
        if ($last) { $rollupParams.LastActivityUtc = $last }
        $rollup = New-WorkspaceRollup @rollupParams
        $rollups += $rollup
    }
    return @($rollups | Sort-Object -Property @{ Expression = 'TotalBytes'; Descending = $true }, ScopeKey)
}

function Test-Archivable {
    param(
        [Parameter(Mandatory = $true)]$ClassifiedFile,
        [Parameter(Mandatory = $true)][datetime]$CutoffUtc
    )
    return ($ClassifiedFile.Disposition -eq 'Archive' -and $ClassifiedFile.LastWriteTimeUtc -lt $CutoffUtc)
}

function Get-ArchivePlan {
    param(
        [Parameter(Mandatory = $true)][array]$Files,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][datetime]$CutoffUtc,
        [Parameter(Mandatory = $true)][hashtable]$HashByRelativeKey
    )
    $manifestByKey = @{}
    foreach ($e in $Manifest.Entries) { $manifestByKey[$e.RelativeKey] = $e }
    $liveByKey = @{}
    foreach ($f in $Files) { $liveByKey[$f.RelativeKey] = $f }
    $actions = @()
    $handledKeys = @{}

    foreach ($f in $Files) {
        if ($f.Disposition -eq 'Report') { continue }
        if (-not (Test-Archivable -ClassifiedFile $f -CutoffUtc $CutoffUtc)) { continue }
        $liveHash = $HashByRelativeKey[$f.RelativeKey]
        if (-not $liveHash) { throw "Missing hash for $($f.RelativeKey)" }
        $entry = $manifestByKey[$f.RelativeKey]
        if (-not $entry) {
            $actions += (New-FileAction -Outcome 'CopyThenDelete' -RelativeKey $f.RelativeKey `
                -RootKind $f.RootKind -Class $f.Class -LivePath $f.FullPath -Length $f.Length `
                -LiveSha256 $liveHash -ArchiveSha256 $liveHash -ProjectPath $f.ProjectPath)
        } elseif ($entry.Sha256 -eq $liveHash) {
            $actions += (New-FileAction -Outcome 'DeleteLive' -RelativeKey $f.RelativeKey `
                -RootKind $f.RootKind -Class $f.Class -LivePath $f.FullPath -Length $f.Length `
                -LiveSha256 $liveHash -ArchiveSha256 $entry.Sha256 -ProjectPath $f.ProjectPath)
        } else {
            $actions += (New-FileAction -Outcome 'Conflict' -RelativeKey $f.RelativeKey `
                -RootKind $f.RootKind -Class $f.Class -LivePath $f.FullPath -Length $f.Length `
                -LiveSha256 $liveHash -ArchiveSha256 $entry.Sha256 -ProjectPath $f.ProjectPath)
        }
        $handledKeys[$f.RelativeKey] = $true
    }

    foreach ($key in $manifestByKey.Keys) {
        if ($handledKeys.ContainsKey($key)) { continue }
        $entry = $manifestByKey[$key]
        $live = $liveByKey[$key]
        $livePath = $null
        if ($live) { $livePath = $live.FullPath }
        else {
            $rootKind = $entry.RootKind
            $roots = Get-CursorRoots
            $livePath = Join-Path (Resolve-CursorRoot -RootKind $rootKind -Roots $roots) $key
        }
        if (-not (Test-Path -LiteralPath $livePath)) {
            $actions += (New-FileAction -Outcome 'AlreadyThere' -RelativeKey $key `
                -RootKind $entry.RootKind -Class $entry.Class -LivePath $livePath `
                -Length $entry.Length -ArchiveSha256 $entry.Sha256 -ProjectPath $entry.ProjectPath)
        }
    }

    return @($actions | Sort-Object RelativeKey)
}

function Get-RestorePlan {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][array]$Probes
    )
    $probeByKey = @{}
    foreach ($p in $Probes) { $probeByKey[$p.RelativeKey] = $p }
    $actions = @()
    foreach ($entry in $Manifest.Entries) {
        $roots = Get-CursorRoots
        $livePath = Join-Path (Resolve-CursorRoot -RootKind $entry.RootKind -Roots $roots) $entry.RelativeKey
        $row = Resolve-PathClass -RootKind $entry.RootKind -RelativeKey $entry.RelativeKey
        if (-not $row -or $row.Class -ne $entry.Class -or $row.Disposition -ne 'Archive') {
            $actions += (New-FileAction -Outcome 'Rejected' -RelativeKey $entry.RelativeKey `
                -RootKind $entry.RootKind -Class $entry.Class -ArchiveSha256 $entry.Sha256)
            continue
        }
        $probe = $probeByKey[$entry.RelativeKey]
        if (-not $probe -or -not $probe.Exists) {
            $actions += (New-FileAction -Outcome 'Extract' -RelativeKey $entry.RelativeKey `
                -RootKind $entry.RootKind -Class $entry.Class -LivePath $livePath -Length $entry.Length `
                -ArchiveSha256 $entry.Sha256 -ProjectPath $entry.ProjectPath)
        } elseif ($probe.Sha256 -eq $entry.Sha256) {
            $actions += (New-FileAction -Outcome 'AlreadyThere' -RelativeKey $entry.RelativeKey `
                -RootKind $entry.RootKind -Class $entry.Class -LivePath $livePath `
                -Length $entry.Length -LiveSha256 $probe.Sha256 -ArchiveSha256 $entry.Sha256 `
                -ProjectPath $entry.ProjectPath)
        } else {
            $actions += (New-FileAction -Outcome 'Conflict' -RelativeKey $entry.RelativeKey `
                -RootKind $entry.RootKind -Class $entry.Class -LivePath $livePath -Length $entry.Length `
                -LiveSha256 $probe.Sha256 -ArchiveSha256 $entry.Sha256 -ProjectPath $entry.ProjectPath)
        }
    }
    return @($actions | Sort-Object RelativeKey)
}

function Test-CursorProcessPresent {
    param([string[]]$ProcessNames = @('Cursor'))
    foreach ($name in $ProcessNames) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Assert-CursorClosed {
    param([string[]]$ProcessNames = @('Cursor'))
    if (Test-CursorProcessPresent -ProcessNames $ProcessNames) {
        throw 'Quit Cursor before using -Apply.'
    }
}

function Test-PathUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    try {
        $p = [System.IO.Path]::GetFullPath($Path)
        $r = [System.IO.Path]::GetFullPath($Root)
        if ($p.Length -lt $r.Length) { return $false }
        if (-not $p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ($p.Length -eq $r.Length) { return $true }
        $sep = [System.IO.Path]::DirectorySeparatorChar
        return ($p[$r.Length] -eq $sep)
    } catch {
        return $false
    }
}

function Assert-ArchiveLocation {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)]$Roots
    )
    if ($ArchivePath -notmatch '(?i)\.zip$') {
        throw 'Archive path must end with .zip'
    }
    $leaf = Split-Path -Leaf $ArchivePath
    if ($leaf -match '(?i)\.(partial|prev|lock)$') {
        throw 'Archive path must not use a sidecar extension.'
    }
    $full = [System.IO.Path]::GetFullPath($ArchivePath)
    if ((Test-PathUnderRoot -Path $full -Root $Roots.UserProfileCursor) `
        -or (Test-PathUnderRoot -Path $full -Root $Roots.AppDataCursorUser)) {
        throw 'Archive zip must not sit inside a Cursor data directory.'
    }
}

function Ensure-ZipAssemblies {
    if (-not ('System.IO.Compression.ZipFile' -as [type])) {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
    }
}

function Find-ClassifiedFiles {
    param([Parameter(Mandatory = $true)]$Roots)
    $table = Get-PathClassTable
    $results = New-Object System.Collections.ArrayList
    $scanKeys = @{}

    function Add-FilesFromRoot {
        param(
            [string]$RootKind,
            [string]$RootPath,
            [string[]]$FullPaths
        )
        foreach ($full in $FullPaths) {
            if (-not (Test-Path -LiteralPath $full)) { continue }
            $fi = Get-Item -LiteralPath $full
            if ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $rootFull = [System.IO.Path]::GetFullPath($RootPath)
            if (-not $fi.FullName.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $rel = ConvertTo-RelativeKey -RootPath $RootPath -FullPath $fi.FullName
            $row = Resolve-PathClass -RootKind $RootKind -RelativeKey $rel
            if (-not $row) { continue }
            [void]$results.Add((New-ClassifiedFile -RootKind $RootKind -RelativeKey $rel -FullPath $fi.FullName `
                -Length $fi.Length -LastWriteTimeUtc $fi.LastWriteTimeUtc.ToUniversalTime() `
                -ProjectPath $null -Slug $null -WorkspaceHash $null -ScopeKey $null))
        }
    }

    foreach ($row in $table) {
        $scanKey = "$($row.RootKind)|$($row.ScanUnder)"
        if ($scanKeys.ContainsKey($scanKey)) { continue }
        $scanKeys[$scanKey] = $true
        $rootKind = $row.RootKind
        $scanUnder = $row.ScanUnder
        $rootPath = Resolve-CursorRoot -RootKind $rootKind -Roots $Roots
        if (-not (Test-Path -LiteralPath $rootPath)) { continue }

        if ($scanUnder -eq 'globalStorage') {
            $scanBase = Join-Path $rootPath 'globalStorage'
            if (-not (Test-Path -LiteralPath $scanBase)) { continue }
            $paths = @(Get-ChildItem -LiteralPath $scanBase -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            Add-FilesFromRoot -RootKind $rootKind -RootPath $rootPath -FullPaths $paths
            continue
        }

        if ($scanUnder -eq 'projects\*\agent-transcripts') {
            $projectsRoot = Join-Path $rootPath 'projects'
            if (-not (Test-Path -LiteralPath $projectsRoot)) { continue }
            $paths = @()
            foreach ($slugDir in Get-ChildItem -LiteralPath $projectsRoot -Directory -ErrorAction SilentlyContinue) {
                $atRoot = Join-Path $slugDir.FullName 'agent-transcripts'
                if (-not (Test-Path -LiteralPath $atRoot)) { continue }
                $paths = @($paths) + @(Get-ChildItem -LiteralPath $atRoot -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                    ForEach-Object { $_.FullName })
            }
            Add-FilesFromRoot -RootKind $rootKind -RootPath $rootPath -FullPaths $paths
            continue
        }

        if ($scanUnder -eq 'workspaceStorage\*') {
            $wsRoot = Join-Path $rootPath 'workspaceStorage'
            if (-not (Test-Path -LiteralPath $wsRoot)) { continue }
            $paths = @()
            foreach ($hashDir in Get-ChildItem -LiteralPath $wsRoot -Directory -ErrorAction SilentlyContinue) {
                $paths = @($paths) + @(Get-ChildItem -LiteralPath $hashDir.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                    ForEach-Object { $_.FullName })
            }
            Add-FilesFromRoot -RootKind $rootKind -RootPath $rootPath -FullPaths $paths
        }
    }

    return @($results.ToArray())
}

function Read-WorkspaceBindings {
    param([Parameter(Mandatory = $true)]$Roots)
    $wsRoot = Join-Path (Resolve-CursorRoot -RootKind 'AppDataCursorUser' -Roots $Roots) 'workspaceStorage'
    $projectsRoot = Join-Path (Resolve-CursorRoot -RootKind 'UserProfileCursor' -Roots $Roots) 'projects'
    $slugNames = @()
    if (Test-Path -LiteralPath $projectsRoot) {
        $slugNames = @(Get-ChildItem -LiteralPath $projectsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    $rows = @()
    if (Test-Path -LiteralPath $wsRoot) {
        foreach ($dir in Get-ChildItem -LiteralPath $wsRoot -Directory -ErrorAction SilentlyContinue) {
            $projectPath = $null
            $wj = Join-Path $dir.FullName 'workspace.json'
            if (Test-Path -LiteralPath $wj) {
                try {
                    $folder = (Get-Content -LiteralPath $wj -Raw | ConvertFrom-Json).folder
                    $projectPath = Normalize-FsPath $folder
                    if (-not $projectPath) { $projectPath = $null }
                } catch { $projectPath = $null }
            }
            $rows += [pscustomobject]@{ WorkspaceHash = $dir.Name; ProjectPath = $projectPath }
        }
    }
    return (Join-WorkspaceBindings -WorkspaceRows $rows -SlugNames $slugNames -ProjectsRoot $projectsRoot)
}

function Read-Manifest {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)
    $side = Get-ArchiveSidecars -ArchivePath $ArchivePath
    $readPath = $ArchivePath
    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        if (Test-Path -LiteralPath $side.Prev) { $readPath = $side.Prev }
        else { return (New-ManifestDocument -Entries @()) }
    }
    Ensure-ZipAssemblies
    $zip = [System.IO.Compression.ZipFile]::OpenRead($readPath)
    try {
        $entry = $zip.GetEntry('manifest.json')
        if (-not $entry) { throw 'manifest.json missing from archive.' }
        $sr = New-Object System.IO.StreamReader($entry.Open())
        try {
            $json = $sr.ReadToEnd()
        } finally { $sr.Dispose() }
        $doc = $json | ConvertFrom-Json
        if ($doc.ManifestVersion -ne 1) {
            throw 'Manifest version must be 1.'
        }
        $entries = @()
        foreach ($wire in @($doc.Entries)) {
            if (-not $wire.RelativeKey -or -not $wire.Class) { throw 'Invalid manifest entry.' }
            $entryLen = [long]$wire.Length
            $entries += (New-ManifestEntry -RelativeKey $wire.RelativeKey -RootKind $wire.RootKind `
                -Class $wire.Class -Length $entryLen -Sha256 $wire.Sha256 `
                -LastWriteTimeUtc ([datetime]$wire.LastWriteTimeUtc) -ProjectPath $wire.ProjectPath `
                -ArchivedUtc ([datetime]$wire.ArchivedUtc))
        }
        return (New-ManifestDocument -Entries $entries)
    } finally {
        $zip.Dispose()
    }
}

function Get-ContentSha256 {
    param([Parameter(Mandatory = $true)][string]$FullPath)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [System.IO.File]::OpenRead($FullPath)
        try {
            $bytes = $sha.ComputeHash($fs)
        } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
    return ([BitConverter]::ToString($bytes) -replace '-', '')
}

function ConvertTo-ManifestWire {
    param([Parameter(Mandatory = $true)]$Manifest)
    $entries = @($Manifest.Entries | ForEach-Object {
        @{
            RelativeKey      = $_.RelativeKey
            RootKind         = $_.RootKind
            Class            = $_.Class
            Length           = $_.Length
            Sha256           = $_.Sha256
            LastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
            ProjectPath      = $_.ProjectPath
            ArchivedUtc      = $_.ArchivedUtc.ToString('o')
        }
    })
    return @{
        ManifestVersion = 1
        Entries         = $entries
    } | ConvertTo-Json -Depth 6 -Compress
}

function Write-ArchiveZip {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][array]$FilesToAdd
    )
    Ensure-ZipAssemblies
    $side = Get-ArchiveSidecars -ArchivePath $ArchivePath
    $partial = $side.Partial
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    $addKeys = @{}
    foreach ($f in $FilesToAdd) { $addKeys[$f.RelativeKey] = $f }

    $existingPath = $ArchivePath
    if (-not (Test-Path -LiteralPath $existingPath) -and (Test-Path -LiteralPath $side.Prev)) {
        $existingPath = $side.Prev
    }

    $zip = [System.IO.Compression.ZipFile]::Open($partial, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        if (Test-Path -LiteralPath $existingPath) {
            $srcZip = [System.IO.Compression.ZipFile]::OpenRead($existingPath)
            try {
                foreach ($srcEntry in $srcZip.Entries) {
                    if ($srcEntry.FullName -eq 'manifest.json') { continue }
                    if ($srcEntry.FullName.StartsWith('files/')) {
                        $rel = $srcEntry.FullName.Substring(6) -replace '/', '\'
                        if ($addKeys.ContainsKey($rel)) { continue }
                    }
                    $dest = $zip.CreateEntry($srcEntry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
                    $in = $srcEntry.Open()
                    $out = $dest.Open()
                    try { $in.CopyTo($out) } finally { $in.Dispose(); $out.Dispose() }
                }
            } finally { $srcZip.Dispose() }
        }

        $now = [datetime]::UtcNow
        $newEntries = @()
        foreach ($f in $FilesToAdd) {
            $hash = Get-ContentSha256 -FullPath $f.FullPath
            $newEntries += (New-ManifestEntry -RelativeKey $f.RelativeKey -RootKind $f.RootKind `
                -Class $f.Class -Length $f.Length -Sha256 $hash `
                -LastWriteTimeUtc $f.LastWriteTimeUtc -ProjectPath $f.ProjectPath -ArchivedUtc $now)
            $entryName = ConvertTo-ZipEntryName -RelativeKey $f.RelativeKey
            $dest = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $out = $dest.Open()
            try {
                $in = [System.IO.File]::OpenRead($f.FullPath)
                try { $in.CopyTo($out) } finally { $in.Dispose() }
            } finally { $out.Dispose() }
        }

        $kept = @($Manifest.Entries | Where-Object { -not $addKeys.ContainsKey($_.RelativeKey) })
        $merged = New-ManifestDocument -Entries (@($kept + $newEntries))
        $manifestJson = ConvertTo-ManifestWire -Manifest $merged
        $manifestEntry = $zip.CreateEntry('manifest.json', [System.IO.Compression.CompressionLevel]::Optimal)
        $ms = New-Object System.IO.StreamWriter($manifestEntry.Open())
        try { $ms.Write($manifestJson) } finally { $ms.Dispose() }
    } finally {
        $zip.Dispose()
    }

    $verifyZip = [System.IO.Compression.ZipFile]::OpenRead($partial)
    try {
        foreach ($f in $FilesToAdd) {
            $entryName = ConvertTo-ZipEntryName -RelativeKey $f.RelativeKey
            $ent = $verifyZip.GetEntry($entryName)
            if (-not $ent) { throw "Zip verify failed for $($f.RelativeKey)" }
            $tmp = [System.IO.Path]::GetTempFileName()
            try {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($ent, $tmp, $true)
                $h = Get-ContentSha256 -FullPath $tmp
                $expected = Get-ContentSha256 -FullPath $f.FullPath
                if ($h -ne $expected) { throw "Zip hash mismatch for $($f.RelativeKey)" }
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    } finally { $verifyZip.Dispose() }

    if (Test-Path -LiteralPath $ArchivePath) {
        if (Test-Path -LiteralPath $side.Prev) { Remove-Item -LiteralPath $side.Prev -Force }
        Move-Item -LiteralPath $ArchivePath -Destination $side.Prev -Force
    }
    Move-Item -LiteralPath $partial -Destination $ArchivePath -Force
    if (Test-Path -LiteralPath $side.Prev) { Remove-Item -LiteralPath $side.Prev -Force }
}

function Remove-ArchivedLiveFiles {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Actions)
    if ($null -eq $Actions) { return }
    foreach ($a in $Actions) {
        if ($a.Outcome -notin @('CopyThenDelete', 'DeleteLive')) { continue }
        if (-not (Test-Path -LiteralPath $a.LivePath)) { continue }
        $fresh = Get-ContentSha256 -FullPath $a.LivePath
        if ($fresh -ne $a.ArchiveSha256) {
            $a.Outcome = 'Conflict'
            $a.LiveSha256 = $fresh
            continue
        }
        Remove-Item -LiteralPath $a.LivePath -Force
    }
}

function Expand-RestoredFiles {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][array]$Actions
    )
    Ensure-ZipAssemblies
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($a in $Actions) {
            if ($a.Outcome -ne 'Extract') { continue }
            if (Test-Path -LiteralPath $a.LivePath) { continue }
            $entryName = ConvertTo-ZipEntryName -RelativeKey $a.RelativeKey
            $ent = $zip.GetEntry($entryName)
            if (-not $ent) { continue }
            $dir = Split-Path -Parent $a.LivePath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            $tmp = "$($a.LivePath).restore-tmp"
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($ent, $tmp, $false)
            $hash = Get-ContentSha256 -FullPath $tmp
            if ($hash -ne $a.ArchiveSha256) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                throw "Zip bytes do not match the manifest for $($a.RelativeKey)"
            }
            Move-Item -LiteralPath $tmp -Destination $a.LivePath -Force
        }
    } finally { $zip.Dispose() }
}

function Enter-ArchiveLock {
    param([Parameter(Mandatory = $true)][string]$LockPath)
    $dir = Split-Path -Parent $LockPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
}

function Get-InventoryFiles {
    $roots = Get-CursorRoots
    $raw = Find-ClassifiedFiles -Roots $roots
    $bindingInfo = Read-WorkspaceBindings -Roots $roots
    return (Get-ScopedClassifiedFiles -Files $raw -Bindings @($bindingInfo.Bindings))
}

function Get-CursorDiskReport {
    $files = Get-InventoryFiles
    return (Get-WorkspaceRollup -Files $files)
}

function Invoke-CursorArchive {
    param(
        [Parameter(Mandatory = $true)][int]$OlderThanDays,
        [string]$ArchivePath,
        [switch]$Apply,
        [string[]]$CursorProcessNames
    )
    if (-not $ArchivePath) { $ArchivePath = Get-DefaultArchivePath }
    $roots = Get-CursorRoots
    Assert-ArchiveLocation -ArchivePath $ArchivePath -Roots $roots
    $cutoff = [datetime]::UtcNow.AddDays(-1 * $OlderThanDays)
    $files = Get-InventoryFiles
    $manifest = Read-Manifest -ArchivePath $ArchivePath
    $manifestKeys = @{}
    foreach ($e in $manifest.Entries) { $manifestKeys[$e.RelativeKey] = $true }

    $hashByKey = @{}
    foreach ($f in $files) {
        $needHash = (Test-Archivable -ClassifiedFile $f -CutoffUtc $cutoff) -or $manifestKeys.ContainsKey($f.RelativeKey)
        if ($needHash) {
            $hashByKey[$f.RelativeKey] = (Get-ContentSha256 -FullPath $f.FullPath)
        }
    }

    $actions = @(Get-ArchivePlan -Files $files -Manifest $manifest -CutoffUtc $cutoff -HashByRelativeKey $hashByKey)
    $bytes = ($actions | Where-Object { $_.Outcome -eq 'CopyThenDelete' } | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }

    if (-not $Apply) {
        return [pscustomobject]@{
            Mode        = 'DryRun'
            ArchivePath = $ArchivePath
            CutoffUtc   = $cutoff
            BytesToMove = $bytes
            Actions     = $actions
        }
    }

    $procNames = @('Cursor')
    if ($CursorProcessNames) { $procNames = $CursorProcessNames }
    Assert-CursorClosed -ProcessNames $procNames

    $side = Get-ArchiveSidecars -ArchivePath $ArchivePath
    $lock = Enter-ArchiveLock -LockPath $side.Lock
    try {
        $copyKeys = @{}
        foreach ($a in ($actions | Where-Object { $_.Outcome -eq 'CopyThenDelete' })) {
            $copyKeys[$a.RelativeKey] = $true
        }
        $toCopy = @($files | Where-Object { $copyKeys.ContainsKey($_.RelativeKey) })
        if ($toCopy.Count -gt 0) {
            Write-ArchiveZip -ArchivePath $ArchivePath -Manifest $manifest -FilesToAdd $toCopy
            $manifest = Read-Manifest -ArchivePath $ArchivePath
            foreach ($a in $actions) {
                if ($a.Outcome -eq 'CopyThenDelete') {
                    $me = $manifest.Entries | Where-Object { $_.RelativeKey -eq $a.RelativeKey } | Select-Object -First 1
                    if ($me) { $a.ArchiveSha256 = $me.Sha256 }
                }
            }
        }
        Remove-ArchivedLiveFiles -Actions $actions
    } finally {
        $lock.Dispose()
    }

    return [pscustomobject]@{
        Mode        = 'Applied'
        ArchivePath = $ArchivePath
        CutoffUtc   = $cutoff
        BytesToMove = $bytes
        Actions     = $actions
    }
}

function Invoke-CursorRestore {
    param(
        [string]$ArchivePath,
        [switch]$Apply,
        [string[]]$CursorProcessNames
    )
    if (-not $ArchivePath) { $ArchivePath = Get-DefaultArchivePath }
    $roots = Get-CursorRoots
    Assert-ArchiveLocation -ArchivePath $ArchivePath -Roots $roots
    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        throw "Archive zip not found: $ArchivePath"
    }
    $manifest = Read-Manifest -ArchivePath $ArchivePath
    if ($manifest.Entries.Count -eq 0) {
        throw 'Archive zip has no manifest entries.'
    }

    $probes = @()
    foreach ($entry in $manifest.Entries) {
        $livePath = Join-Path (Resolve-CursorRoot -RootKind $entry.RootKind -Roots $roots) $entry.RelativeKey
        $exists = Test-Path -LiteralPath $livePath
        $sha = $null
        $len = 0
        if ($exists) {
            $len = (Get-Item -LiteralPath $livePath).Length
            $sha = Get-ContentSha256 -FullPath $livePath
        }
        $probes += (New-LiveProbe -RelativeKey $entry.RelativeKey -Exists $exists -Sha256 $sha -Length $len)
    }

    $actions = Get-RestorePlan -Manifest $manifest -Probes $probes
    if (-not $Apply) {
        return [pscustomobject]@{
            Mode        = 'DryRun'
            ArchivePath = $ArchivePath
            Actions     = $actions
        }
    }

    $procNames = @('Cursor')
    if ($CursorProcessNames) { $procNames = $CursorProcessNames }
    Assert-CursorClosed -ProcessNames $procNames

    $side = Get-ArchiveSidecars -ArchivePath $ArchivePath
    $lock = Enter-ArchiveLock -LockPath $side.Lock
    try {
        Expand-RestoredFiles -ArchivePath $ArchivePath -Actions $actions
    } finally {
        $lock.Dispose()
    }

    return [pscustomobject]@{
        Mode        = 'Applied'
        ArchivePath = $ArchivePath
        Actions     = $actions
    }
}

function Format-ByteSize {
    param([Parameter(Mandatory = $true)][long]$Bytes)
    if ($Bytes -eq 0) { return '0 B' }
    $kb = 1024.0
    if ($Bytes -lt $kb) { return "$Bytes B" }
    $mb = $kb * 1024
    if ($Bytes -lt $mb) { return ('{0:N1} KB' -f ($Bytes / $kb)) }
    $gb = $mb * 1024
    if ($Bytes -lt $gb) { return ('{0:N1} MB' -f ($Bytes / $mb)) }
    return ('{0:N1} GB' -f ($Bytes / $gb))
}

function Write-DiskReport {
    param([Parameter(Mandatory = $true)][array]$Rollups)
    Write-Host ('{0,-32} {1,16} {2,16} {3,16} {4,16}' -f 'Project', 'Last activity', 'Transcripts', 'Chat', 'Total') -ForegroundColor Cyan
    foreach ($r in $Rollups) {
        $label = $r.ProjectPath
        if ($r.ScopeKey -eq 'global') { $label = '(global chat database)' }
        elseif ($r.ScopeKey -like 'slug:*') { $label = $r.ScopeKey }
        elseif ($r.ScopeKey -like 'hash:*') { $label = $r.ScopeKey }
        if (-not $label) { $label = $r.ScopeKey }
        $last = ''
        if ($r.LastActivityUtc) {
            $last = $r.LastActivityUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
        }
        Write-Host ('{0,-32} {1,16} {2,16} {3,16} {4,16}' -f $label, $last,
            (Format-ByteSize $r.TranscriptBytes), (Format-ByteSize $r.ChatBytes), (Format-ByteSize $r.TotalBytes))
    }
    $sumTranscripts = ($Rollups | Measure-Object -Property TranscriptBytes -Sum).Sum
    $sumChat = ($Rollups | Measure-Object -Property ChatBytes -Sum).Sum
    $sumTotal = ($Rollups | Measure-Object -Property TotalBytes -Sum).Sum
    if (-not $sumTranscripts) { $sumTranscripts = 0 }
    if (-not $sumChat) { $sumChat = 0 }
    if (-not $sumTotal) { $sumTotal = 0 }
    Write-Host ('{0,-32} {1,16} {2,16} {3,16} {4,16}' -f 'Total', '',
        (Format-ByteSize $sumTranscripts), (Format-ByteSize $sumChat), (Format-ByteSize $sumTotal)) -ForegroundColor Cyan
}

function Write-ActionPlan {
    param([Parameter(Mandatory = $true)]$Result)
    Write-Host 'Plan' -ForegroundColor Cyan
    if ($Result.Mode -eq 'DryRun') {
        Write-Host 'MODE: DRY-RUN (read-only)' -ForegroundColor Yellow
    } else {
        Write-Host 'MODE: APPLIED' -ForegroundColor Green
    }
    foreach ($a in $Result.Actions) {
        $color = 'White'
        if ($a.Outcome -in @('Conflict', 'Rejected')) { $color = 'Red' }
        $size = Format-ByteSize $a.Length
        Write-Host "$($a.Outcome)  $size  $($a.RelativeKey)" -ForegroundColor $color
    }
    if ($Result.Mode -eq 'DryRun') {
        Write-Host 'Quit Cursor and re-run with -Apply to perform this plan.'
    }
}

function Get-ExitCodeFromActions {
    param([array]$Actions)
    if ($Actions | Where-Object { $_.Outcome -in @('Conflict', 'Rejected') }) { return 1 }
    return 0
}

function Test-ExitCodeTwoMessage {
    param([string]$Message)
    if ($Message -match 'Quit Cursor') { return $true }
    if ($Message -match 'Cursor data directory') { return $true }
    if ($Message -match 'Manifest version must be 1') { return $true }
    return $false
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($UserProfile -or $AppData) {
        Set-CursorRootOverride -UserProfile $UserProfile -AppData $AppData
    }

    $effectiveApply = $Apply.IsPresent -and -not $WhatIf.IsPresent

    try {
        switch ($PSCmdlet.ParameterSetName) {
            'Report' {
                $rollups = Get-CursorDiskReport
                Write-DiskReport -Rollups $rollups
                exit 0
            }
            'Archive' {
                $result = Invoke-CursorArchive -OlderThanDays $OlderThanDays -ArchivePath $ArchivePath -Apply:$effectiveApply
                Write-ActionPlan -Result $result
                exit (Get-ExitCodeFromActions -Actions $result.Actions)
            }
            'Restore' {
                $result = Invoke-CursorRestore -ArchivePath $ArchivePath -Apply:$effectiveApply
                Write-ActionPlan -Result $result
                exit (Get-ExitCodeFromActions -Actions $result.Actions)
            }
            default {
                throw "unhandled parameter set $($PSCmdlet.ParameterSetName)"
            }
        }
    } catch {
        $msg = $_.Exception.Message
        Write-Host $msg -ForegroundColor Red
        if (Test-ExitCodeTwoMessage -Message $msg) {
            exit 2
        }
        throw
    }
}
