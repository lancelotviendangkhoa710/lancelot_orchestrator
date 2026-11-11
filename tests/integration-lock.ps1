$ErrorActionPreference = 'Stop'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('khoa-integration-lock-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $scratch 'package'
$repo = Join-Path $scratch 'repo'
$runs = Join-Path $package 'runs'
New-Item -ItemType Directory -Path $package,$repo,$runs -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\Invoke-KhoaIntegration.ps1') -Destination $package
& git -C $repo init -q
Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value 'baseline'
& git -C $repo add README.md
& git -C $repo -c user.name=Smoke -c user.email=smoke@local.invalid commit -qm baseline
$lock = [IO.File]::Open((Join-Path $runs 'integration.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    try {
        & (Join-Path $package 'Invoke-KhoaIntegration.ps1') -RepoPath $repo -WorkerResults @('placeholder') -Checks @('Write-Output ok') *> $null
        throw 'Concurrent integration unexpectedly passed.'
    }
    catch { if ($_.Exception.Message -notmatch 'integration lock is held') { throw } }
    Write-Output 'integration lock rejection: passed'
}
finally { $lock.Dispose() }
