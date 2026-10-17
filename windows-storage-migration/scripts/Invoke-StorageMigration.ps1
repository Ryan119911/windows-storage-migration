param([Parameter(Mandatory=$true)][string]$PlanPath, [switch]$Apply, [switch]$StopBackground)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7 -or -not $IsWindows) { throw 'This engine requires PowerShell 7 on Windows.' }
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
if ($plan.schema_version -ne 1) { throw 'Unsupported migration plan schema.' }
foreach ($key in @('source', 'destination', 'recovery_root')) {
    if (-not $plan.$key -or $plan.$key -notmatch '^[A-Za-z]:\\') { throw "Plan $key must be an absolute local Windows path." }
}
$source = [IO.Path]::GetFullPath($plan.source).TrimEnd('\')
$destination = [IO.Path]::GetFullPath($plan.destination).TrimEnd('\')
$recoveryRoot = [IO.Path]::GetFullPath($plan.recovery_root).TrimEnd('\')
if ($plan.policy.conflicts -notin @('stop','archive-source-wins')) { throw 'Choose conflicts=stop or archive-source-wins explicitly.' }
if ($plan.policy.cleanup_source_backup -isnot [bool]) { throw 'Choose cleanup_source_backup=true/false explicitly.' }
function Resolve-PhysicalPath([string]$path) {
    $root = [IO.Path]::GetPathRoot($path)
    $current = $root
    foreach ($component in $path.Substring($root.Length).Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
        $next = Join-Path $current $component
        if (Test-Path -LiteralPath $next) {
            $entry = Get-Item -LiteralPath $next -Force
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $resolved = $entry.ResolveLinkTarget($true)
                if (-not $resolved) { throw "Cannot resolve reparse point: $next" }
                $next = $resolved.FullName
            }
        }
        $current = $next
    }
    return [IO.Path]::GetFullPath($current).TrimEnd('\')
}
function Test-Nested([string]$a, [string]$b) {
    return $a -ieq $b -or $a.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase) -or $b.StartsWith($a + '\', [StringComparison]::OrdinalIgnoreCase)
}
$physicalSource = Resolve-PhysicalPath $source
$physicalDestination = Resolve-PhysicalPath $destination
$physicalRecovery = Resolve-PhysicalPath $recoveryRoot
$alreadyExpectedLink = $false
if (Test-Path -LiteralPath $source) {
    $candidate = Get-Item -LiteralPath $source -Force
    $alreadyExpectedLink = $candidate.LinkType -eq 'Junction' -and @($candidate.Target)[0] -ieq $destination
}
if ((Test-Nested $physicalSource $physicalDestination) -and -not ($alreadyExpectedLink -and $physicalSource -ieq $physicalDestination)) {
    throw 'Source and destination overlap physically, including through parent junctions.'
}
if ((Test-Nested $physicalRecovery $physicalSource) -or (Test-Nested $physicalRecovery $physicalDestination)) { throw 'Recovery must be outside both data trees.' }
if (-not ('StorageMigrationVolume' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.ComponentModel;
public static class StorageMigrationVolume {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool GetVolumePathName(string path, StringBuilder root, uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool GetVolumeNameForVolumeMountPoint(string root, StringBuilder name, uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool GetDiskFreeSpaceEx(string root, out ulong available, out ulong total, out ulong free);
    public static string Id(string path) {
        var root = new StringBuilder(32768);
        var name = new StringBuilder(32768);
        if (!GetVolumePathName(path,root,32768) || !GetVolumeNameForVolumeMountPoint(root.ToString(),name,32768)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return name.ToString();
    }
    public static ulong Available(string path) {
        ulong available,total,free;
        if (!GetDiskFreeSpaceEx(path,out available,out total,out free)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return available;
    }
}
'@
}
function Get-ExistingAncestor([string]$path) {
    $current = $path
    while (-not [IO.Directory]::Exists($current)) {
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -ieq $current) { throw "No accessible volume ancestor: $path" }
        $current = $parent
    }
    return $current
}
$destinationVolumePath = Get-ExistingAncestor $physicalDestination
$recoveryVolumePath = Get-ExistingAncestor $physicalRecovery
if ([StorageMigrationVolume]::Id($destinationVolumePath) -ine [StorageMigrationVolume]::Id($recoveryVolumePath)) { throw 'Recovery and destination must be on the same physical volume, including through parent junctions.' }
foreach ($value in @($source,$destination,$recoveryRoot,$physicalSource,$physicalDestination,$physicalRecovery)) {
    if ($value -ieq [IO.Path]::GetPathRoot($value).TrimEnd('\')) { throw 'Drive roots cannot be migration entries.' }
}
$protected = @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, $env:WINDIR, $env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)})
foreach ($path in $protected) {
    if ($path -and (Resolve-PhysicalPath $path) -iin @($physicalSource,$physicalDestination,$physicalRecovery)) { throw 'A whole profile, AppData or system installation root cannot be a migration/recovery entry.' }
}
$runToken = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$runDirectory = Join-Path $recoveryRoot $runToken

function Get-MigrationProcesses {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $process = $_
        $matched = @($plan.processes.main_names) -contains $process.ProcessName
        foreach ($helperRule in @($plan.processes.helpers)) {
            if (@($helperRule.names) -contains $process.ProcessName) { $matched = $true }
        }
        if ($process.Path) {
            foreach ($root in @($source, $destination) + @($plan.processes.blocked_executable_roots)) {
                if ($root -and $process.Path.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $matched = $true }
            }
            foreach ($helperRule in @($plan.processes.helpers)) {
                foreach ($root in @($helperRule.executable_roots)) {
                    if ($root -and $process.Path.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $matched = $true }
                }
            }
        }
        $matched
    }
}
function Test-Helper($process) {
    if ($process.Id -eq $PID) { return $false }
    if (-not $process.Path) { return $false }
    if (@($plan.processes.main_names) -contains $process.ProcessName) { return $false }
    foreach ($rule in @($plan.processes.helpers)) {
        if (@($rule.names) -contains $process.ProcessName) {
            foreach ($root in @($rule.executable_roots)) {
                if ($root -and $process.Path.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
        }
    }
    return $false
}

function Assert-Closed([switch]$AllowHelpers) {
    $running = @(Get-MigrationProcesses | Where-Object { -not $AllowHelpers -or -not (Test-Helper $_) })
    if ($running.Count) {
        throw ('Save work and fully exit the selected application, including its tray UI. Running: ' + (($running | ForEach-Object { $_.ProcessName + ':' + $_.Id }) -join ', '))
    }
}
function Stop-Helpers {
    Assert-Closed -AllowHelpers
    for ($attempt=0; $attempt -lt 3; $attempt++) {
        Assert-Closed -AllowHelpers
        $helpers = @(Get-MigrationProcesses | Where-Object { Test-Helper $_ })
        if (-not $helpers.Count) { break }
        foreach ($helper in $helpers) {
            Write-Host "Stopping verified application helper: $($helper.ProcessName):$($helper.Id)"
            if (-not $helper.HasExited) {
                try { Stop-Process -InputObject $helper -Force } catch { if (-not $helper.HasExited) { throw } }
            }
        }
        Start-Sleep -Seconds 1
    }
    Assert-Closed
}
function Get-Manifest([string]$root) {
    $result = @{}
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($root)
    while ($pending.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            $key = $item.FullName.Substring($root.Length).TrimStart('\')
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $result[$key] = 'LINK:' + $item.LinkType + ':' + (@($item.Target) -join '|')
            } elseif ($item.PSIsContainer) {
                $result[$key] = 'DIRECTORY'
                $pending.Push($item.FullName)
            } else {
                $result[$key] = 'FILE:' + $item.Length + ':' + (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            }
        }
    }
    return ,$result
}
function Assert-Contains($expected, $actual, [switch]$Exact) {
    if ($Exact -and $expected.Count -ne $actual.Count) { throw 'Manifest entry counts differ.' }
    foreach ($key in $expected.Keys) {
        if (-not $actual.ContainsKey($key) -or $expected[$key] -cne $actual[$key]) { throw "Hash/type verification failed: $key; expected=$($expected[$key]); actual=$($actual[$key])" }
    }
}
function Set-PrivateAccess([string]$from, [string]$to) {
    $original = Get-Acl -LiteralPath $from
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $sections = [Security.AccessControl.AccessControlSections]::Access
    $acl.SetSecurityDescriptorSddlForm($original.GetSecurityDescriptorSddlForm($sections), $sections)
    $acl.SetAccessRuleProtection($true, $true)
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($to), $acl)
}
function Set-CopiedEntryAccess([string]$from, [string]$to, [bool]$directory) {
    $original = Get-Acl -LiteralPath $from
    if ($directory) { $acl = New-Object Security.AccessControl.DirectorySecurity }
    else { $acl = New-Object Security.AccessControl.FileSecurity }
    $sections = [Security.AccessControl.AccessControlSections]::Access
    $acl.SetSecurityDescriptorSddlForm($original.GetSecurityDescriptorSddlForm($sections), $sections)
    $acl.SetAccessRuleProtection($true, $true)
    if ($directory) { [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($to), $acl) }
    else { [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($to), $acl) }
}
function Prepare-SecureEntries($manifest) {
    foreach ($key in @($manifest.Keys | Sort-Object Length)) {
        $to = Get-SafeChild $destination $key
        if (Test-Path -LiteralPath $to) { continue }
        $from = Get-SafeChild $source $key
        if ($manifest[$key] -eq 'DIRECTORY') {
            New-Item -ItemType Directory -Path $to | Out-Null
            Set-CopiedEntryAccess $from $to $true
        } elseif ($manifest[$key].StartsWith('FILE:')) {
            [IO.File]::Open($to, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None).Dispose()
            Set-CopiedEntryAccess $from $to $false
        }
    }
}
function Copy-Tree([string]$from, [string]$to, [switch]$DataOnly) {
    $copyMode = if ($DataOnly) { '/COPY:DAT' } else { '/COPY:DATS' }
    & robocopy.exe $from $to /E $copyMode /DCOPY:DAT /SJ /SL /IS /IT /R:1 /W:1 /NP /NFL /NDL
    if ($LASTEXITCODE -ge 8) { throw "Robocopy failed: exit code $LASTEXITCODE. Original data and recovery copies are preserved." }
}
function Get-SafeChild([string]$root, [string]$key) {
    $resolved = [IO.Path]::GetFullPath((Join-Path $root $key))
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath($root) + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Path escaped the approved directory.' }
    return $resolved
}
function Assert-OrdinaryDirectory([string]$path) {
    $entry = Get-Item -LiteralPath $path -Force
    if (-not $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Expected an ordinary directory: $path" }
}
function Remove-BackupDeleteDeny([string]$path, [bool]$directory) {
    # Called only after Remove-Entry validates this is an archived C: backup.
    # Preserve other access rules; remove only current-user deny-delete bits.
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $original = Get-Acl -LiteralPath $path
    $sections = [Security.AccessControl.AccessControlSections]::Access
    if ($directory) { $acl = New-Object Security.AccessControl.DirectorySecurity }
    else { $acl = New-Object Security.AccessControl.FileSecurity }
    $acl.SetSecurityDescriptorSddlForm($original.GetSecurityDescriptorSddlForm($sections), $sections)
    $deleteMask = [int][Security.AccessControl.FileSystemRights]::Delete -bor [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
    $hasDeny = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
        $_.IdentityReference.Value -eq $identity.Value -and $_.AccessControlType -eq 'Deny' -and ([int]$_.FileSystemRights -band $deleteMask)
    }).Count -gt 0
    if (-not $hasDeny) { return }
    $acl.SetAccessRuleProtection($true, $true)
    foreach ($rule in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
        if ($rule.IdentityReference.Value -eq $identity.Value -and $rule.AccessControlType -eq 'Deny' -and ([int]$rule.FileSystemRights -band $deleteMask)) {
            $acl.RemoveAccessRuleSpecific($rule)
            $remaining = [int]$rule.FileSystemRights -band (-bnot $deleteMask)
            if ($remaining) {
                $replacement = New-Object Security.AccessControl.FileSystemAccessRule($rule.IdentityReference, [Security.AccessControl.FileSystemRights]$remaining, $rule.InheritanceFlags, $rule.PropagationFlags, [Security.AccessControl.AccessControlType]::Deny)
                $acl.AddAccessRule($replacement)
            }
        }
    }
    if ($directory) { [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($path), $acl) }
    else { [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($path), $acl) }
    Write-Host "Removed deny-delete bits only in verified old backup: $path"
}
function Remove-Entry([string]$path, [string]$approvedRoot) {
    if (-not $approvedRoot) { throw 'Backup cleanup requires an approved root.' }
    $rootPath = [IO.Path]::GetFullPath($approvedRoot)
    $full = [IO.Path]::GetFullPath($path)
    if (($rootPath -notmatch ('^' + [regex]::Escape($source) + '\.migration-backup-\d{8}-\d{6}$') -and $rootPath -ine ($source + '_old')) -or
        ($full -ine $rootPath -and -not $full.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Backup cleanup escaped the approved old-source path.'
    }
    $item = Get-Item -LiteralPath $path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($item.FullName) } else { [IO.File]::Delete($item.FullName) }
    } elseif ($item.PSIsContainer) {
        Remove-BackupDeleteDeny $path $true
        foreach ($child in @(Get-ChildItem -LiteralPath $path -Force)) { Remove-Entry $child.FullName $rootPath }
        $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        [IO.Directory]::Delete($item.FullName)
    } else {
        Remove-BackupDeleteDeny $path $false
        $item.Attributes = $item.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)
        [IO.File]::Delete($item.FullName)
    }
}
function Archive-And-RemoveBackup([string]$backup) {
    $full = [IO.Path]::GetFullPath($backup)
    if ($full -notmatch ('^' + [regex]::Escape($source) + '\.migration-backup-\d{8}-\d{6}$') -and $full -ine ($source + '_old')) {
        throw 'Backup cleanup path rejected.'
    }
    Assert-OrdinaryDirectory $full
    Assert-Closed
    $archive = Join-Path (Join-Path $runDirectory 'source-backups') (Split-Path -Leaf $full)
    New-Item -ItemType Directory -Path $archive -Force | Out-Null
    Set-PrivateAccess $full $archive
    $snapshot = Get-Manifest $full
    Copy-Tree $full $archive
    Assert-Contains $snapshot (Get-Manifest $archive) -Exact
    Assert-Contains $snapshot (Get-Manifest $full) -Exact
    Assert-Closed
    # Only the validated old source directory is removed; keep the live junction.
    if ($plan.policy.cleanup_source_backup) {
        Remove-Entry $full $full
        Write-Host "Old source backup removed after verified archival: $archive"
    } else {
        Write-Host "Old source backup retained by policy: $full. Verified archive: $archive"
    }
}

$discoveredBackups = @()
if (Test-Path -LiteralPath (Split-Path -Parent $source)) {
    $discoveredBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $source) -Force | Where-Object {
        $_.Name -match ('^' + [regex]::Escape((Split-Path -Leaf $source)) + '(\.migration-backup-\d{8}-\d{6}|_old)$')
    })
}
if (-not $Apply) {
    [ordered]@{
        mode='PLAN ONLY'; source=$source; destination=$destination; recovery_root=$recoveryRoot;
        conflicts=$plan.policy.conflicts; cleanup_source_backup=$plan.policy.cleanup_source_backup;
        stop_helpers_requested=[bool]$StopBackground; processes_will_be_stopped=$false;
        existing_backups=@($discoveredBackups.FullName); destination_physical_volume=[StorageMigrationVolume]::Id($destinationVolumePath)
    } | ConvertTo-Json
    Write-Host 'No files changed. Use -Apply only within the user-authorized scope.'
    exit 0
}
$mutex = New-Object Threading.Mutex($false, 'Local\WindowsStorageMigration_v1')
try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
if (-not $locked) { throw 'Another storage migration is already running.' }
if ($StopBackground) { Stop-Helpers }
Assert-Closed
if (-not (Get-Command robocopy.exe -ErrorAction SilentlyContinue)) { throw 'Robocopy not found.' }
$backups = $discoveredBackups
if ($plan.policy.cleanup_source_backup -or -not (Test-Path -LiteralPath $source)) {
    foreach ($backup in $backups) {
        if (@($plan.approved_existing_backups) -inotcontains $backup.FullName) { throw "Existing backup has not been reviewed in approved_existing_backups: $($backup.FullName). Preserving it." }
    }
}
if (-not (Test-Path -LiteralPath $source) -and $backups.Count -eq 1) {
    Assert-OrdinaryDirectory $backups[0].FullName
    Rename-Item -LiteralPath $backups[0].FullName -NewName (Split-Path -Leaf $source)
    $backups = @()
}
$entry = Get-Item -LiteralPath $source -Force
if (-not $entry.PSIsContainer) { throw 'Only directory migration is supported.' }
$already = $false
if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    if ($entry.LinkType -ne 'Junction' -or @($entry.Target)[0] -ine $destination) { throw 'Source is an unexpected link; preserving it.' }
    $already = $true
} elseif ($backups.Count) { throw 'Original and old backup both exist. Preserving both; inspect before running.' }
if (Test-Path -LiteralPath $destination) { Assert-OrdinaryDirectory $destination }
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Set-PrivateAccess $source $runDirectory
Start-Transcript -LiteralPath (Join-Path $runDirectory 'migration.log') | Out-Null
try {
    if ($already) {
        foreach ($backup in $backups) {
            if ($plan.policy.cleanup_source_backup) { Archive-And-RemoveBackup $backup.FullName }
            else { Write-Host "Old source backup retained by policy: $($backup.FullName)" }
        }
        Write-Host 'ALL DONE: File migration already complete; compatibility junction remains intact. Check the requested backup-cleanup policy separately.' -ForegroundColor Green
        exit 0
    }
    if (-not (Test-Path -LiteralPath $destination)) {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Set-PrivateAccess $source $destination
    }
    Write-Host 'Hashing source and existing destination data ...'
    $before = Get-Manifest $source
    $sourceBytes = [long]0
    foreach ($value in $before.Values) { if ($value.StartsWith('FILE:')) { $sourceBytes += [long]($value.Split(':')[1]) } }
    $required = 2 * $sourceBytes + 256MB
    $available = [StorageMigrationVolume]::Available((Resolve-PhysicalPath $destination))
    if ($available -lt $required) { throw "Insufficient destination/recovery free space. Need approximately $required bytes; have $available." }
    $existing = Get-Manifest $destination
    # Complete conflict preflight before moving any existing destination file.
    foreach ($key in $before.Keys) {
        if ($existing.ContainsKey($key) -and $existing[$key] -cne $before[$key]) {
            if (-not $before[$key].StartsWith('FILE:') -or -not $existing[$key].StartsWith('FILE:')) { throw "Conflicting directory/link types; preserving both trees: $key" }
            if ($plan.policy.conflicts -eq 'stop') { throw "Existing destination file differs; preserving both originals: $key" }
        }
    }
    # Different files at the same path are backed up, never silently discarded.
    foreach ($key in $before.Keys) {
        if ($existing.ContainsKey($key) -and $existing[$key] -cne $before[$key]) {
            if (-not $before[$key].StartsWith('FILE:') -or -not $existing[$key].StartsWith('FILE:')) {
                throw "Conflicting directory/link types; preserving both trees: $key"
            }
            if ($plan.policy.conflicts -eq 'stop') { throw "Existing destination file differs; preserving both originals: $key" }
            $from = Get-SafeChild $destination $key
            $saved = Get-SafeChild (Join-Path $runDirectory 'destination-conflicts') $key
            New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force | Out-Null
            # Move this one ordinary file to recovery so a same-size/same-time
            # target cannot be skipped by the native copy operation.
            Move-Item -LiteralPath $from -Destination $saved
            $savedItem = Get-Item -LiteralPath $saved -Force
            $savedValue = 'FILE:' + $savedItem.Length + ':' + (Get-FileHash -LiteralPath $saved).Hash
            if ($savedValue -cne $existing[$key]) { throw "Conflict backup verification failed: $key" }
            Write-Host "Preserved pre-existing D: file before using the C: version: $key"
        }
    }
    Write-Host 'Copying source; destination-only files and directories stay in place ...'
    # Never reset ACLs of existing target directories or unrelated task data.
    # Secure newly created entries before copying bytes into a potentially shared tree.
    Prepare-SecureEntries $before
    Copy-Tree $source $destination -DataOnly
    $merged = Get-Manifest $destination
    Write-Host 'Verifying the copied source against D: ...'
    Assert-Contains $before $merged
    $extra = @{}
    foreach ($key in $existing.Keys) { if (-not $before.ContainsKey($key)) { $extra[$key] = $existing[$key] } }
    Write-Host 'Verifying destination-only tasks and data remain unchanged ...'
    Assert-Contains $extra $merged
    Assert-Contains $before (Get-Manifest $source) -Exact
    Assert-Closed
    $backup = $source + '.migration-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    if (Test-Path -LiteralPath $backup) { throw 'Backup path already exists.' }
    Rename-Item -LiteralPath $source -NewName (Split-Path -Leaf $backup)
    try {
        New-Item -ItemType Junction -Path $source -Target $destination | Out-Null
        $link = Get-Item -LiteralPath $source -Force
        if ($link.LinkType -ne 'Junction' -or @($link.Target)[0] -ine $destination) { throw 'Junction target verification failed.' }
        Assert-Contains $before (Get-Manifest $source)
        Assert-Contains $extra (Get-Manifest $source)
    } catch {
        $failure = $_
        try { Assert-Closed } catch { throw "The application restarted; preserving current paths and backup: $backup" }
        if (Test-Path -LiteralPath $source) {
            $current = Get-Item -LiteralPath $source -Force
            if ($current.LinkType -ne 'Junction') { throw "Rollback blocked by unexpected source entry. Backup retained: $backup" }
            [IO.Directory]::Delete($source)
        }
        Rename-Item -LiteralPath $backup -NewName (Split-Path -Leaf $source)
        throw $failure
    }
    Archive-And-RemoveBackup $backup
    Write-Host "FILE MIGRATION VERIFIED: $source -> $destination. Existing destination-only entries preserved. cleanup_source_backup=$($plan.policy.cleanup_source_backup). Application functionality still needs verification." -ForegroundColor Green
    Write-Host "Recovery/log directory: $runDirectory"
    Write-Host 'Reopen the application and check its actual functions. Keep the compatibility junction. Report remaining old-source backups separately from file migration status.'
} finally { Stop-Transcript | Out-Null }
