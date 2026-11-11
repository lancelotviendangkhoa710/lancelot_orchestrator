$ErrorActionPreference = 'Stop'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('khoa-recovery-' + [guid]::NewGuid().ToString('N'))
$runs = Join-Path $scratch 'runs'
$repo = Join-Path $scratch 'repo'
New-Item -ItemType Directory -Path (Join-Path $runs 'a'),(Join-Path $runs 'b'),$repo -Force | Out-Null
& git -C $repo init -q
Set-Content (Join-Path $repo 'README.md') 'base'
& git -C $repo add README.md
& git -C $repo -c user.name=Smoke -c user.email=smoke@local.invalid commit -qm base
[ordered]@{ run_id='a'; status='running'; worktree=(Join-Path $scratch 'missing'); sandbox_container_name=('missing-' + [guid]::NewGuid().ToString('N')) } |
    ConvertTo-Json | Set-Content (Join-Path $runs 'a\result.json')
[ordered]@{ run_id='b'; status='completed'; worktree=$repo; commit_sha=('a' * 40) } |
    ConvertTo-Json | Set-Content (Join-Path $runs 'b\result.json')
$results = @(& (Join-Path $PSScriptRoot '..\Get-KhoaRecovery.ps1') -RunsRoot $runs)
if ($results.Count -ne 2 -or @($results | Where-Object { $_.run_id -eq 'a' -and $_.assessment -eq 'needs_recovery' }).Count -ne 1 -or @($results | Where-Object { $_.run_id -eq 'b' -and $_.assessment -eq 'commit_mismatch' }).Count -ne 1) { throw 'Recovery scan missed stale or tampered run.' }
Write-Output 'stale run and commit mismatch recovery scan: passed'
