param([string]$AppDir, [string]$PersistDir, [switch]$TestOnly, [switch]$DetachOnly)
$ErrorActionPreference = 'Stop'
function Get-TreeHash([string]$Root) {
    $Root = (Get-Item -LiteralPath $Root).FullName
    $result = @{}
    Get-ChildItem -LiteralPath $Root -File -Recurse -Force | ForEach-Object {
        $key = $_.FullName.Substring($Root.TrimEnd('\').Length).TrimStart('\')
        $result[$key] = [string]$_.Length + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
    return $result
}
function Link-Data([string]$Source, [string]$Target, [switch]$FailLink) {
    $Source = [IO.Path]::GetFullPath($Source).Replace('/', '\')
    $Target = [IO.Path]::GetFullPath($Target).Replace('/', '\')
    if (Test-Path -LiteralPath $Source) {
        $item = Get-Item -LiteralPath $Source -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            if ($item.Target -notcontains $Target) { throw "Unexpected junction: $Source" }
            return
        }
    }
    if (Test-Path -LiteralPath $Target) { throw "Refusing to merge existing destination: $Target" }
    $backup = $Source + '.scoop-backup'
    if (Test-Path -LiteralPath $backup) { throw "Backup already exists: $backup" }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    $hadSource = Test-Path -LiteralPath $Source
    try {
        if ($hadSource) {
            $nestedLinks = @(Get-ChildItem -LiteralPath $Source -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
            if ($nestedLinks.Count) { throw 'Nested reparse points require manual review.' }
            $acl = Get-Acl -LiteralPath $Source
            Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $Target -Recurse -Force
            Set-Acl -LiteralPath $Target -AclObject $acl
            $a = Get-TreeHash $Source; $b = Get-TreeHash $Target
            if ($a.Count -ne $b.Count) { throw 'File count mismatch.' }
            foreach ($key in $a.Keys) { if ($a[$key] -ne $b[$key]) { throw "Hash mismatch: $key" } }
            Move-Item -LiteralPath $Source -Destination $backup
        }
        if ($FailLink) { throw 'Injected link failure' }
        New-Item -ItemType Junction -Path $Source -Target $Target | Out-Null
        if ((Get-Item -LiteralPath $Source -Force).Target -notcontains $Target) { throw 'Junction verification failed.' }
        $probe = '.scoop-write-probe-' + [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText((Join-Path $Source $probe), 'verified')
        if ([IO.File]::ReadAllText((Join-Path $Target $probe)) -ne 'verified') { throw 'Write-through verification failed.' }
        Remove-Item -LiteralPath (Join-Path $Target $probe)
    } catch {
        if (Test-Path -LiteralPath $Source) {
            $item = Get-Item -LiteralPath $Source -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($Source, $false) }
        }
        if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $Source }
        Remove-Item -LiteralPath $Target -Recurse -Force
        throw
    }
}
if ($TestOnly) {
    $root = Join-Path $env:TMPDIR ('goodsync-link-test-' + [guid]::NewGuid().ToString('N'))
    $source = Join-Path $root 'live'; $target = Join-Path $root 'persist'
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'sample.txt'), 'preserve-me')
    $failed = $false
    try { Link-Data $source $target -FailLink } catch { $failed = $true }
    if (!$failed -or !(Test-Path (Join-Path $source 'sample.txt')) -or (Test-Path $target)) { throw 'Rollback test failed.' }
    Link-Data $source $target
    Link-Data $source $target
    [IO.Directory]::Delete($source, $false)
    if ([IO.File]::ReadAllText((Join-Path $target 'sample.txt')) -ne 'preserve-me') { throw 'Unlink preservation test failed.' }
    Remove-Item -LiteralPath $root -Recurse -Force
    Write-Output 'PASS: rollback, hashes, junction write-through, idempotent rerun, unlink preserves data'
    exit 0
}
if (!$AppDir -or !$PersistDir) { throw 'AppDir and PersistDir are required.' }
$program = Join-Path $env:ProgramFiles 'Siber Systems\GoodSync'
if (!(Test-Path $program)) { throw 'Installed GoodSync was not found.' }
if (Get-Process -Name GoodSync -ErrorAction SilentlyContinue) { throw 'Close GoodSync before migration.' }
$services = @(Get-CimInstance Win32_Service | Where-Object { $_.PathName -like '*Siber Systems\GoodSync*' -and $_.State -eq 'Running' })
try {
    foreach ($service in $services) { Stop-Service -Name $service.Name -Force }
    Get-Process -Name gs-server,gs-runner -ErrorAction SilentlyContinue | Stop-Process -Force
    if ($DetachOnly) {
        foreach ($pair in @(@((Join-Path $env:LOCALAPPDATA 'GoodSync'), (Join-Path $PersistDir 'client')), @((Join-Path $env:ProgramData 'GoodSync'), (Join-Path $PersistDir 'server')))) {
            if (Test-Path -LiteralPath $pair[0]) {
                $item = Get-Item -LiteralPath $pair[0] -Force
                if ($item.LinkType -ne 'Junction' -or $item.Target -notcontains $pair[1]) { throw 'Unexpected configuration location; refusing to detach.' }
                [IO.Directory]::Delete($pair[0], $false)
            }
        }
        Write-Output 'Configuration junctions detached; Scoop persist data preserved.'
        exit 0
    }
    Link-Data (Join-Path $env:LOCALAPPDATA 'GoodSync') (Join-Path $PersistDir 'client')
    Link-Data (Join-Path $env:ProgramData 'GoodSync') (Join-Path $PersistDir 'server')
    Link-Data $program (Join-Path $AppDir 'program')
    $backupRoot = Join-Path $PersistDir 'migration-backup'
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    foreach ($pair in @(@((Join-Path $env:LOCALAPPDATA 'GoodSync.scoop-backup'), 'client'), @((Join-Path $env:ProgramData 'GoodSync.scoop-backup'), 'server'), @(($program + '.scoop-backup'), 'program'))) {
        if (Test-Path -LiteralPath $pair[0]) {
            $dest = Join-Path $backupRoot $pair[1]
            if (Test-Path $dest) { throw "Backup target already exists: $dest" }
            Move-Item -LiteralPath $pair[0] -Destination $dest
        }
    }
} finally { foreach ($service in $services) { Start-Service -Name $service.Name } }
Write-Output 'GoodSync program and configuration migrated to Scoop.'
