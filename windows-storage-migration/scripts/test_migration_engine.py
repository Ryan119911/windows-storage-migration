"""Run isolated Windows integration tests; never use real app data as fixtures."""
import argparse
import json
import os
import subprocess
import uuid
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pwsh', required=True)
    parser.add_argument('--work-dir', required=True)
    args = parser.parse_args()
    engine = Path(__file__).with_name('Invoke-StorageMigration.ps1').resolve()
    root = Path(args.work_dir).resolve() / ('storage-skill-test-' + uuid.uuid4().hex[:10])
    root.mkdir(parents=True)
    results = []

    def ps(code):
        process = subprocess.run([args.pwsh, '-NoProfile', '-Command', code], capture_output=True, text=True, encoding='utf-8', errors='replace')
        if process.returncode:
            raise RuntimeError(process.stdout + process.stderr)
        return process.stdout

    def fixture(name):
        folder = root / name
        source, destination, recovery = folder / 'source' / 'app', folder / 'target' / 'app', folder / 'recovery'
        source.mkdir(parents=True)
        (source / 'settings.json').write_text('new-c-settings')
        (source / 'readonly.txt').write_text('read-only-file')
        os.chmod(source / 'readonly.txt', 0o444)
        (source / 'nested' / 'empty').mkdir(parents=True)
        destination.mkdir(parents=True)
        (destination / 'Claw').mkdir()
        (destination / 'Claw' / 'keep.txt').write_text('existing-d-only-task')
        (destination / 'settings.json').write_text('old-d-settings')
        plan = {'schema_version': 1, 'source': str(source), 'destination': str(destination),
                'recovery_root': str(recovery), 'approved_existing_backups': [], 'policy': {'conflicts': 'stop', 'cleanup_source_backup': True},
                'processes': {'main_names': ['__not_a_real_test_app__'], 'blocked_executable_roots': [], 'helpers': []}}
        return folder, source, destination, recovery, plan

    def run(folder, plan, apply=False, runner=engine, success=True):
        plan_path = folder / 'plan.json'
        plan_path.write_text(json.dumps(plan), encoding='utf-8')
        command = [args.pwsh, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(runner), '-PlanPath', str(plan_path)]
        if apply:
            command.append('-Apply')
        process = subprocess.run(command, capture_output=True, text=True, encoding='utf-8', errors='replace')
        (folder / ('run-' + uuid.uuid4().hex[:6] + '.log')).write_text(process.stdout + '\n' + process.stderr, encoding='utf-8')
        if (process.returncode == 0) != success:
            raise RuntimeError(process.stdout[-3000:] + '\n' + process.stderr[-1800:])
        return process

    folder, source, destination, recovery, plan = fixture('merge')
    long_dir = Path('\\\\?\\' + str(source / ('a' * 110) / ('b' * 110)))
    long_dir.mkdir(parents=True)
    (long_dir / 'deep.txt').write_text('long-path-file')
    protected = source / 'logs' / 'sdk'
    protected.mkdir(parents=True)
    (protected / 'cloud.log').write_text('protected-sdk-log')
    # Existing target is deliberately shared, while the source is private.
    # Neither default rejection nor an approved merge may reset target-only ACLs.
    ps(r'''
$source='__SOURCE__'
$destination='__DESTINATION__'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$flags=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
foreach($identity in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))){
 $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,[Security.AccessControl.FileSystemRights]::FullControl,$flags,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
}
[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($source),$acl)
$targetAcl=Get-Acl -LiteralPath $destination
$targetAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),[Security.AccessControl.FileSystemRights]::ReadAndExecute,$flags,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($destination),$targetAcl)
'''.replace('__SOURCE__', str(source)).replace('__DESTINATION__', str(destination)))

    def acl_signature(path):
        return ps("(Get-Acl -LiteralPath '" + str(path) + "').GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)").strip()

    original_target_acl = acl_signature(destination)
    original_task_acl = acl_signature(destination / 'Claw')
    ps(r'''
$folder='__FOLDER__'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$acl=Get-Acl -LiteralPath $folder
$rights=[Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
$flags=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
$rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,$rights,$flags,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny)
$acl.AddAccessRule($rule)
[IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($folder),$acl)
'''.replace('__FOLDER__', str(protected)))
    outside = folder / 'external-target'
    outside.mkdir()
    (outside / 'keep.txt').write_text('external-link-target')
    ps("New-Item -ItemType Junction -Path '" + str(source / 'linked') + "' -Target '" + str(outside) + "' | Out-Null")
    run(folder, plan)
    assert not source.is_junction() and not recovery.exists()
    assert (destination / 'settings.json').read_text() == 'old-d-settings'
    results.append('plan only: no data changes')
    run(folder, plan, apply=True, success=False)
    assert not source.is_junction() and (destination / 'settings.json').read_text() == 'old-d-settings'
    assert acl_signature(destination) == original_target_acl
    assert acl_signature(destination / 'Claw') == original_task_acl
    results.append('default conflict policy: preserves both originals')
    plan['policy']['conflicts'] = 'archive-source-wins'
    run(folder, plan, apply=True)
    assert source.is_junction()
    assert (source / 'settings.json').read_text() == 'new-c-settings'
    assert (source / 'Claw' / 'keep.txt').read_text() == 'existing-d-only-task'
    assert any(p.read_text() == 'old-d-settings' for p in recovery.glob('*/destination-conflicts/settings.json'))
    assert list(recovery.glob('*/source-backups/*/settings.json'))
    assert not list(source.parent.glob('app.migration-backup-*'))
    assert (outside / 'keep.txt').exists()
    assert acl_signature(destination) == original_target_acl
    assert acl_signature(destination / 'Claw') == original_task_acl
    ps(r'''
$acl=Get-Acl -LiteralPath '__NEWFILE__'
if(@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {$_.IdentityReference.Value -eq 'S-1-5-32-545' -and $_.AccessControlType -eq 'Allow'}).Count){throw 'Private copied data inherited shared destination Users permissions'}
'''.replace('__NEWFILE__', str(destination / 'settings.json')))
    ps(r'''
$acl=Get-Acl -LiteralPath '__FILE__'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$denies=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]) | Where-Object {$_.IdentityReference.Value -eq $sid.Value -and $_.AccessControlType -eq 'Deny' -and ([int]$_.FileSystemRights -band [int][Security.AccessControl.FileSystemRights]::Delete)})
if(-not $denies.Count){throw 'Live destination deny-delete rules were modified'}
'''.replace('__FILE__', str(destination / 'logs' / 'sdk' / 'cloud.log')))
    results.append('merge, SHA-256, long paths, read-only files, junctions, archive and narrow ACL cleanup')
    results.append('existing root/task ACLs preserved; new private files do not inherit shared target access')
    run(folder, plan, apply=True)
    backup = source.parent / 'app.migration-backup-20261017-130001'
    backup.mkdir()
    (backup / 'interrupted.txt').write_text('interrupted-cleanup')
    # A name alone does not authorize deleting an already-present backup.
    run(folder, plan, apply=True, success=False)
    assert backup.exists()
    plan['approved_existing_backups'] = [str(backup)]
    run(folder, plan, apply=True)
    assert not backup.exists() and list(recovery.glob('*/source-backups/*/interrupted.txt'))
    os.rmdir(source)  # Remove this synthetic junction only, never its target.
    backup.mkdir()
    (backup / 'restored.txt').write_text('interrupted-rename')
    run(folder, plan, apply=True)
    assert source.is_junction() and (source / 'restored.txt').exists()
    assert (source / 'Claw' / 'keep.txt').exists()
    results.append('idempotent rerun and both interruption recoveries')
    results.append('unreviewed pre-existing backup refused before cleanup')

    folder2, source2, destination2, recovery2, plan2 = fixture('retain')
    plan2['policy'] = {'conflicts': 'archive-source-wins', 'cleanup_source_backup': False}
    run(folder2, plan2, apply=True)
    backups = list(source2.parent.glob('app.migration-backup-*'))
    assert source2.is_junction() and len(backups) == 1
    archive_runs = len(list(recovery2.iterdir()))
    run(folder2, plan2, apply=True)
    assert backups[0].exists()
    assert len(list(recovery2.glob('*/source-backups/*'))) == 1
    results.append('retain-backup policy does not delete source backup or duplicate its archive on rerun')

    folder3, source3, destination3, recovery3, plan3 = fixture('rollback')
    plan3['policy']['conflicts'] = 'archive-source-wins'
    injected = engine.read_text('utf-8').replace('New-Item -ItemType Junction -Path $source -Target $destination | Out-Null', "throw 'Injected junction failure'")
    runner = folder3 / 'failure-engine.ps1'
    runner.write_text(injected, encoding='utf-8')
    run(folder3, plan3, apply=True, runner=runner, success=False)
    assert source3.is_dir() and not source3.is_junction()
    assert (source3 / 'settings.json').read_text() == 'new-c-settings'
    assert (destination3 / 'Claw' / 'keep.txt').exists()
    results.append('injected junction failure restores source')

    folder4, source4, destination4, recovery4, plan4 = fixture('alias')
    alias = folder4 / 'alias'
    ps("New-Item -ItemType Junction -Path '" + str(alias) + "' -Target '" + str(source4.parent) + "' | Out-Null")
    plan4['source'] = str(alias / 'app')
    plan4['destination'] = str(source4)
    result = run(folder4, plan4, success=False)
    assert 'overlap physically' in result.stderr
    results.append('physical overlap through ancestor junction rejected before mutation')

    windows = Path(os.environ.get('WINDIR', r'C:\Windows'))
    if root.anchor.casefold() != windows.anchor.casefold():
        redirect = folder4 / 'other-volume'
        ps("New-Item -ItemType Junction -Path '" + str(redirect) + "' -Target '" + str(windows) + "' | Out-Null")
        volume_plan = dict(plan4)
        volume_plan['source'] = str(source4)
        volume_plan['destination'] = str(redirect / 'Temp')
        result = run(folder4, volume_plan, success=False)
        assert 'same physical volume' in result.stderr
        results.append('same-letter parent junction to a different physical volume rejected')

    folder5, source5, destination5, recovery5, plan5 = fixture('partial-cleanup')
    plan5['policy']['conflicts'] = 'archive-source-wins'
    for index in range(6):
        (source5 / ('extra-' + str(index) + '.txt')).write_text('must-remain-in-full-archive-' + str(index))
    injected = engine.read_text('utf-8').replace('        [IO.File]::Delete($item.FullName)\n', '''        [IO.File]::Delete($item.FullName)
        $script:testDeletes++
        if ($script:testDeletes -eq 2) { throw 'Injected failure after actual partial deletion' }
''')
    partial_runner = folder5 / 'partial-cleanup-engine.ps1'
    partial_runner.write_text(injected, encoding='utf-8')
    run(folder5, plan5, apply=True, runner=partial_runner, success=False)
    partial_backups = list(source5.parent.glob('app.migration-backup-*'))
    assert source5.is_junction() and len(partial_backups) == 1
    full_archives = list(recovery5.glob('*/source-backups/*/extra-0.txt'))
    assert len(full_archives) == 1
    assert len(list(partial_backups[0].rglob('*.txt'))) < 7
    assert len(list(partial_backups[0].rglob('*.txt'))) > 0
    full_archive_bytes = full_archives[0].read_bytes()
    plan5['approved_existing_backups'] = [str(partial_backups[0])]
    run(folder5, plan5, apply=True)
    assert not partial_backups[0].exists() and source5.is_junction()
    assert full_archives[0].read_bytes() == full_archive_bytes
    assert (destination5 / 'Claw' / 'keep.txt').exists()
    results.append('actual partial deletion failure: full archive survives and reviewed rerun safely cleans remainder')

    folder6, source6, destination6, recovery6, plan6 = fixture('partial-copy')
    (destination6 / 'settings.json').unlink()
    interrupted = engine.read_text('utf-8').replace('    Copy-Tree $source $destination -DataOnly', "    throw 'Injected interruption after secure precreation'\n    Copy-Tree $source $destination -DataOnly")
    copy_runner = folder6 / 'partial-copy-engine.ps1'
    copy_runner.write_text(interrupted, encoding='utf-8')
    run(folder6, plan6, apply=True, runner=copy_runner, success=False)
    assert not source6.is_junction() and (destination6 / 'settings.json').stat().st_size == 0
    run(folder6, plan6, apply=True, success=False)
    assert (source6 / 'settings.json').read_text() == 'new-c-settings'
    # After reviewing this synthetic run's log, explicitly retain source authority.
    plan6['policy']['conflicts'] = 'archive-source-wins'
    run(folder6, plan6, apply=True)
    assert source6.is_junction() and (destination6 / 'settings.json').read_text() == 'new-c-settings'
    assert (destination6 / 'Claw' / 'keep.txt').exists()
    results.append('partial-copy placeholders safely refused; explicit source-authority recovery preserves target tasks')

    guard = engine.read_text('utf-8').split('if (-not $Apply) {', 1)[0]
    guard += r'''
$plan.processes.main_names=@('ExampleApp')
$plan.processes.helpers=@([pscustomobject]@{names=@('sandbox-cli-gc');executable_roots=@('D:\VerifiedApp')})
if(-not(Test-Helper ([pscustomobject]@{Id=123;ProcessName='sandbox-cli-gc';Path='D:\VerifiedApp\sandbox-cli-gc.exe'}))){throw 'Known helper rejected'}
if(Test-Helper ([pscustomobject]@{Id=123;ProcessName='sandbox-cli-gc';Path='D:\Unrelated\sandbox-cli-gc.exe'})){throw 'Unverified helper accepted'}
if(Test-Helper ([pscustomobject]@{Id=123;ProcessName='ExampleApp';Path='D:\VerifiedApp\ExampleApp.exe'})){throw 'Main app accepted as helper'}
if(Test-Helper ([pscustomobject]@{Id=$PID;ProcessName='sandbox-cli-gc';Path='D:\VerifiedApp\sandbox-cli-gc.exe'})){throw 'Current runtime accepted as helper'}
'''
    guard_runner = folder / 'guard-test.ps1'
    guard_runner.write_text(guard, encoding='utf-8')
    run(folder, plan, runner=guard_runner)
    results.append('helper name/path validation, main-app and own-runtime protection')
    print(json.dumps({'status': 'PASS', 'cases': results, 'evidence_directory': str(root)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
