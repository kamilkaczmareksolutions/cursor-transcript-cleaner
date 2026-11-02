BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:CleanerScript = Join-Path $RepoRoot 'scripts/clean-cursor-transcripts.ps1'

    function Get-FunctionSource {
        param([string]$Path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $defs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
        return ($defs | ForEach-Object { $_.Extent.Text }) -join "`n"
    }

    . ([scriptblock]::Create((Get-FunctionSource $CleanerScript)))

    function Initialize-CleanerFixture {
        param(
            [string]$HomeRoot,
            [string]$AppDataRoot,
            [string]$ProjectFolder = 'C:\src\myapp',
            [string]$OrphanSlug = 'c-orphan-app',
            [string]$ProjectSlug = 'c-src-myapp',
            [string]$WorkspaceHash = 'wshash01'
        )

        $cursorUser = Join-Path $HomeRoot '.cursor'
        $projects = Join-Path $cursorUser 'projects'
        $appUser = Join-Path $AppDataRoot 'Cursor/User'
        $globalDir = Join-Path $appUser 'globalStorage'
        $wsDir = Join-Path $appUser "workspaceStorage/$WorkspaceHash"

        $oldUtc = [datetime]::UtcNow.AddDays(-100)
        $newUtc = [datetime]::UtcNow.AddDays(-1)
        $orphUtc = [datetime]::UtcNow.AddDays(-10)

        New-Item -ItemType Directory -Force -Path $globalDir, $wsDir, (Join-Path $projects $ProjectSlug), (Join-Path $projects $OrphanSlug) | Out-Null

        function Set-TestFile {
            param([string]$Path, [string]$Content, [datetime]$WriteUtc)
            $parent = Split-Path -Parent $Path
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            [System.IO.File]::WriteAllText($Path, $Content)
            if ($WriteUtc) { (Get-Item -LiteralPath $Path).LastWriteTimeUtc = $WriteUtc }
        }

        Set-TestFile (Join-Path $globalDir 'state.vscdb') ('G' * 100) $oldUtc
        Set-TestFile (Join-Path $globalDir 'state.vscdb-wal') ('W' * 10) $oldUtc
        Set-TestFile (Join-Path $globalDir 'state.vscdb-shm') ('S' * 5) $oldUtc
        Set-TestFile (Join-Path $globalDir 'state.vscdb.backup') ('B' * 8) $oldUtc
        Set-TestFile (Join-Path $globalDir 'other.db') ('X' * 50) $oldUtc

        $folderUri = 'file:///c%3A/src/myapp'
        $wj = @{ folder = $folderUri } | ConvertTo-Json -Compress
        Set-TestFile (Join-Path $wsDir 'workspace.json') $wj $oldUtc
        Set-TestFile (Join-Path $wsDir 'state.vscdb') ('C' * 200) $oldUtc
        Set-TestFile (Join-Path $wsDir 'images/pic.png') ('P' * 30) $oldUtc

        $oldJsonl = Join-Path $projects "$ProjectSlug/agent-transcripts/oldses/oldses.jsonl"
        $newJsonl = Join-Path $projects "$ProjectSlug/agent-transcripts/newses/newses.jsonl"
        Set-TestFile $oldJsonl '{"old":true}' $oldUtc
        Set-TestFile $newJsonl '{"new":true}' $newUtc
        Set-TestFile (Join-Path $projects "$ProjectSlug/agent-transcripts/flat.jsonl") 'flat' $oldUtc
        Set-TestFile (Join-Path $projects "$ProjectSlug/agent-transcripts/sub/note.txt") 'note' $oldUtc
        Set-TestFile (Join-Path $projects "$ProjectSlug/extra-beside-slug.txt") 'beside' $oldUtc
        Set-TestFile (Join-Path $projects "$OrphanSlug/agent-transcripts/orphses/orphses.jsonl") '{"orph":1}' $orphUtc

        $projTransRoot = Join-Path $projects "$ProjectSlug/agent-transcripts"
        $orphTransRoot = Join-Path $projects "$OrphanSlug/agent-transcripts"
        $projectTranscriptBytes = (Get-ChildItem -LiteralPath $projTransRoot -Recurse -File | Measure-Object -Property Length -Sum).Sum
        $orphTranscriptBytes = (Get-ChildItem -LiteralPath $orphTransRoot -Recurse -File | Measure-Object -Property Length -Sum).Sum
        $chatBytes = (Get-ChildItem -LiteralPath $wsDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
        $globalBytes = (Get-ChildItem -LiteralPath $globalDir -File | Where-Object {
            $_.Name -match '^state\.vscdb(\-wal|\-shm|\.backup)?$'
        } | Measure-Object -Property Length -Sum).Sum

        return [pscustomobject]@{
            OldJsonl       = $oldJsonl
            NewJsonl       = $newJsonl
            ProjectFolder  = $ProjectFolder
            OrphanSlug     = $OrphanSlug
            ProjectSlug    = $ProjectSlug
            GlobalBytes    = $globalBytes
            ProjectTranscriptBytes = $projectTranscriptBytes
            OrphanTranscriptBytes  = $orphTranscriptBytes
            ChatBytes      = $chatBytes
            LastActivityProject = $newUtc
        }
    }

    function Use-CleanerEnv {
        param([scriptblock]$Block, [string]$HomeRoot, [string]$AppDataRoot)
        Set-CursorRootOverride -UserProfile $HomeRoot -AppData $AppDataRoot
        try { & $Block } finally { Clear-CursorRootOverride }
    }
}

Describe 'Get-CursorDiskReport' {
    It 'lists global, bound project, and orphan slug rows sorted by TotalBytes descending' {
        $fakeHome = Join-Path $TestDrive 'report-home'
        $app = Join-Path $TestDrive 'report-app'
        $meta = $null
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            $meta = Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app
            $report = Get-CursorDiskReport
            $report.Count | Should -BeGreaterOrEqual 3
            for ($i = 0; $i -lt ($report.Count - 1); $i++) {
                $report[$i].TotalBytes | Should -BeGreaterOrEqual $report[$i + 1].TotalBytes
            }
            $global = $report | Where-Object { $_.ScopeKey -eq 'global' } | Select-Object -First 1
            $global | Should -Not -BeNullOrEmpty
            $global.ChatBytes | Should -Be $meta.GlobalBytes
            $global.TranscriptBytes | Should -Be 0

            $project = $report | Where-Object { $_.ProjectPath -eq 'C:\src\myapp' } | Select-Object -First 1
            $project | Should -Not -BeNullOrEmpty
            $project.TranscriptBytes | Should -Be $meta.ProjectTranscriptBytes
            $project.ChatBytes | Should -Be $meta.ChatBytes
            $project.LastActivityUtc | Should -Be $meta.LastActivityProject

            $orph = $report | Where-Object { $_.ScopeKey -eq "slug:$($meta.OrphanSlug)" } | Select-Object -First 1
            $orph | Should -Not -BeNullOrEmpty
            $orph.TranscriptBytes | Should -Be $meta.OrphanTranscriptBytes
        }
    }
}

Describe 'Invoke-CursorArchive' {
    It 'dry-run leaves live files and creates no zip' {
        $fakeHome = Join-Path $TestDrive 'arch-home1'
        $app = Join-Path $TestDrive 'arch-app1'
        $zip = Join-Path $TestDrive 'archives/dry.zip'
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            $meta = Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app
            $plan = Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $zip
            $plan.Mode | Should -Be 'DryRun'
            Test-Path -LiteralPath $meta.OldJsonl | Should -BeTrue
            Test-Path -LiteralPath $zip | Should -BeFalse
        }
    }

    It 'apply moves only old staff-shaped jsonl and leaves everything else' {
        $fakeHome = Join-Path $TestDrive 'arch-home2'
        $app = Join-Path $TestDrive 'arch-app2'
        $zip = Join-Path $TestDrive 'archives/apply.zip'
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            $meta = Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app
            $result = Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $zip -Apply
            $result.Mode | Should -Be 'Applied'
            Test-Path -LiteralPath $meta.OldJsonl | Should -BeFalse
            Test-Path -LiteralPath $meta.NewJsonl | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $fakeHome ".cursor/projects/$($meta.ProjectSlug)/agent-transcripts/flat.jsonl") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $fakeHome ".cursor/projects/$($meta.ProjectSlug)/agent-transcripts/sub/note.txt") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $app 'Cursor/User/globalStorage/state.vscdb') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $app "Cursor/User/workspaceStorage/wshash01/workspace.json") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $fakeHome ".cursor/projects/$($meta.ProjectSlug)/extra-beside-slug.txt") | Should -BeTrue
            Test-Path -LiteralPath $zip | Should -BeTrue
        }
    }

    It 'zip manifest version 1 sha256 matches archived bytes' {
        $fakeHome = Join-Path $TestDrive 'arch-home3'
        $app = Join-Path $TestDrive 'arch-app3'
        $zip = Join-Path $TestDrive 'archives/hash.zip'
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            $meta = Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app
            Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $zip -Apply | Out-Null
            $manifest = Read-Manifest -ArchivePath $zip
            $manifest.ManifestVersion | Should -Be 1
            $entry = $manifest.Entries | Select-Object -First 1
            $entry | Should -Not -BeNullOrEmpty
            Ensure-ZipAssemblies
            $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
            try {
                $ent = $z.GetEntry((ConvertTo-ZipEntryName -RelativeKey $entry.RelativeKey))
                $tmp = [System.IO.Path]::GetTempFileName()
                try {
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($ent, $tmp, $true)
                    $hash = Get-ContentSha256 -FullPath $tmp
                    $hash | Should -BeExactly $entry.Sha256
                } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            } finally { $z.Dispose() }
        }
    }

    It 'second apply returns AlreadyThere when live files are gone' {
        $fakeHome = Join-Path $TestDrive 'arch-home4'
        $app = Join-Path $TestDrive 'arch-app4'
        $zip = Join-Path $TestDrive 'archives/idempotent.zip'
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app | Out-Null
            Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $zip -Apply | Out-Null
            $again = Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $zip -Apply
            ($again.Actions | Where-Object { $_.Outcome -eq 'AlreadyThere' }).Count | Should -BeGreaterThan 0
        }
    }

    It 'second apply DeleteLive when live file matches zip hash' {
        $fakeHome = Join-Path $TestDrive 'arch-home5'
        $app = Join-Path $TestDrive 'arch-app5'
        $zip = Join-Path $TestDrive 'archives/deletelive.zip'
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            $meta = Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app
            Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $zip -Apply | Out-Null
            New-Item -ItemType Directory -Force -Path (Split-Path $meta.OldJsonl -Parent) | Out-Null
            [System.IO.File]::WriteAllText($meta.OldJsonl, '{"old":true}')
            (Get-Item -LiteralPath $meta.OldJsonl).LastWriteTimeUtc = (Get-Date).AddDays(-100).ToUniversalTime()
            $second = Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $zip -Apply
            ($second.Actions | Where-Object { $_.Outcome -eq 'DeleteLive' }).Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath $meta.OldJsonl | Should -BeFalse
        }
    }

    It 'refuses archive path inside Cursor user profile with exit 2' {
        $fakeHome = Join-Path $TestDrive 'arch-home6'
        $app = Join-Path $TestDrive 'arch-app6'
        $badZip = Join-Path $fakeHome '.cursor/bad.zip'
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app | Out-Null
            { Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $badZip -Apply } |
                Should -Throw '*Cursor data directory*'
            Test-Path -LiteralPath $badZip | Should -BeFalse
        }
    }

    It 'refuses archive path inside AppData Cursor directory with exit 2' {
        $fakeHome = Join-Path $TestDrive 'arch-home6b'
        $app = Join-Path $TestDrive 'arch-app6b'
        $badZip = Join-Path $app 'Cursor/User/bad.zip'
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app | Out-Null
            { Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $badZip -Apply } |
                Should -Throw '*Cursor data directory*'
            Test-Path -LiteralPath $badZip | Should -BeFalse
        }
    }

    It 'refuses apply when configured process name is running' {
        $fakeHome = Join-Path $TestDrive 'arch-home7'
        $app = Join-Path $TestDrive 'arch-app7'
        $zip = Join-Path $TestDrive 'archives/cursorproc.zip'
        $procName = (Get-Process -Id $PID).ProcessName
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app | Out-Null
            { Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $zip -Apply -CursorProcessNames @($procName) } |
                Should -Throw '*Quit Cursor*'
        }
    }
}

Describe 'Invoke-CursorRestore' {
    It 'restore apply writes bytes back and second restore is idempotent' {
        $fakeHome = Join-Path $TestDrive 'rest-home1'
        $app = Join-Path $TestDrive 'rest-app1'
        $zip = Join-Path $TestDrive 'archives/restore.zip'
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            $meta = Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app
            Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $zip -Apply | Out-Null
            Test-Path -LiteralPath $meta.OldJsonl | Should -BeFalse
            $restore = Invoke-CursorRestore -ArchivePath $zip -Apply
            ($restore.Actions | Where-Object { $_.Outcome -eq 'Extract' }).Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath $meta.OldJsonl | Should -BeTrue
            $hash1 = Get-ContentSha256 -FullPath $meta.OldJsonl
            $again = Invoke-CursorRestore -ArchivePath $zip -Apply
            ($again.Actions | Where-Object { $_.Outcome -eq 'AlreadyThere' }).Count | Should -BeGreaterThan 0
            Get-ContentSha256 -FullPath $meta.OldJsonl | Should -BeExactly $hash1
        }
    }

    It 'conflict keeps live bytes and reports Conflict' {
        $fakeHome = Join-Path $TestDrive 'rest-home2'
        $app = Join-Path $TestDrive 'rest-app2'
        $zip = Join-Path $TestDrive 'archives/conflict.zip'
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            $meta = Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app
            Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $zip -Apply | Out-Null
            New-Item -ItemType Directory -Force -Path (Split-Path $meta.OldJsonl -Parent) | Out-Null
            [System.IO.File]::WriteAllText($meta.OldJsonl, 'different-bytes')
            $restore = Invoke-CursorRestore -ArchivePath $zip -Apply
            ($restore.Actions | Where-Object { $_.Outcome -eq 'Conflict' }).Count | Should -BeGreaterThan 0
            Get-Content -LiteralPath $meta.OldJsonl -Raw | Should -BeExactly 'different-bytes'
        }
    }
}

Describe 'CLI entry' {
    It 'WhatIf with Apply performs no writes' {
        $fakeHome = Join-Path $TestDrive 'cli-home1'
        $app = Join-Path $TestDrive 'cli-app1'
        $zip = Join-Path $TestDrive 'archives/whatif.zip'
        New-Item -ItemType Directory -Force -Path (Split-Path $zip -Parent) | Out-Null
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            $meta = Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app
            & $CleanerScript -Archive -OlderThanDays 90 -ArchivePath $zip -Apply -WhatIf -UserProfile $fakeHome -AppData $app | Out-Null
            Test-Path -LiteralPath $meta.OldJsonl | Should -BeTrue
            Test-Path -LiteralPath $zip | Should -BeFalse
        }
    }

    It 'restore exits 2 when manifest version is not 1' {
        $fakeHome = Join-Path $TestDrive 'cli-home2'
        $app = Join-Path $TestDrive 'cli-app2'
        $zip = Join-Path $TestDrive 'archives/badmanifest.zip'
        Ensure-ZipAssemblies
        $bad = @{ ManifestVersion = 2; Entries = @() } | ConvertTo-Json -Compress
        $z = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $e = $z.CreateEntry('manifest.json')
            $w = New-Object System.IO.StreamWriter($e.Open())
            try { $w.Write($bad) } finally { $w.Dispose() }
        } finally { $z.Dispose() }
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app | Out-Null
            & $CleanerScript -Restore -ArchivePath $zip -Apply -UserProfile $fakeHome -AppData $app 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 2
        }
    }

    It 'restore conflict exits 1' {
        $fakeHome = Join-Path $TestDrive 'cli-home3'
        $app = Join-Path $TestDrive 'cli-app3'
        $zip = Join-Path $TestDrive 'archives/cliconflict.zip'
        Use-CleanerEnv -HomeRoot $fakeHome -AppDataRoot $app {
            $meta = Initialize-CleanerFixture -HomeRoot $fakeHome -AppDataRoot $app
            Invoke-CursorArchive -OlderThanDays 90 -ArchivePath $zip -Apply | Out-Null
            New-Item -ItemType Directory -Force -Path (Split-Path $meta.OldJsonl -Parent) | Out-Null
            [System.IO.File]::WriteAllText($meta.OldJsonl, 'other')
            & $CleanerScript -Restore -ArchivePath $zip -Apply -UserProfile $fakeHome -AppData $app | Out-Null
            $LASTEXITCODE | Should -Be 1
        }
    }
}
