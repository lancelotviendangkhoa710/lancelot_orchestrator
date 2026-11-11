$ErrorActionPreference = 'Stop'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('khoa-smoke-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $scratch 'package'
$repo = Join-Path $scratch 'repo'
New-Item -ItemType Directory -Path $package, $repo -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot '..\Invoke-KhoaWorker.ps1') $package
Copy-Item (Join-Path $PSScriptRoot '..\Invoke-KhoaIntegration.ps1') $package
Copy-Item (Join-Path $PSScriptRoot '..\opencode.jsonc') $package
Set-Content (Join-Path $package '.env') 'NINEROUTER_API_KEY=test-only-key'
& git -C $repo init -q
Set-Content (Join-Path $repo 'README.md') 'baseline'
& git -C $repo add README.md
& git -C $repo -c user.name=Smoke -c user.email=smoke@local.invalid commit -qm baseline
$contract = [ordered]@{
    task_id='smoke'; objective='Create one file'; context='Temporary repository';
    allowed_paths=@('allowed.md'); forbidden_actions=@('docker','deploy');
    implementation_requirements=@('Write allowed.md'); acceptance_criteria=@('File exists')
}
$contractPath = Join-Path $scratch 'contract.json'
$contract | ConvertTo-Json | Set-Content $contractPath
function global:opencode {
    Set-Content (Join-Path (Get-Location).Path 'allowed.md') 'worker result'
    $global:LASTEXITCODE = 0
    '{"type":"result","status":"ok"}'
}
try {
    & (Join-Path $package 'Invoke-KhoaWorker.ps1') -RepoPath $repo -ContractPath $contractPath *> $null
    $result = Get-ChildItem (Join-Path $package 'runs') -Filter result.json -Recurse | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    if ($result.status -ne 'completed' -or -not $result.commit_sha -or $result.changed_files -notcontains 'allowed.md') { throw 'Dispatch/report/commit check failed.' }
    $workerConfig = Join-Path (Split-Path $result.worktree) 'opencode.worker.json'
    $config = Get-Content $workerConfig -Raw | ConvertFrom-Json
    if (@($config.mcp.servers.PSObject.Properties).Count -ne 0 -or (@($config.permissions | Where-Object { $_.action -eq 'shell' -and $_.effect -eq 'deny' }).Count -ne 1)) { throw 'Worker permissions check failed.' }
    Write-Output 'worker dispatch, report and permissions: passed'
    function global:opencode {
        Set-Content (Join-Path (Get-Location).Path 'outside.md') 'scope violation'
        $global:LASTEXITCODE = 0
        '{"type":"result","status":"ok"}'
    }
    try { & (Join-Path $package 'Invoke-KhoaWorker.ps1') -RepoPath $repo -ContractPath $contractPath *> $null; throw 'Expected scope failure' }
    catch { if ($_.Exception.Message -notmatch 'outside allowed paths') { throw } }
    $allResults = @(Get-ChildItem (Join-Path $package 'runs') -Filter result.json -Recurse)
    $failed = @($allResults | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object status -eq 'scope_failed')
    if ($failed.Count -ne 1 -or $failed[0].commit_sha) { throw 'Failure recovery check failed.' }
    Write-Output 'scope violation and preserved worktree: passed'
    $global:quotaAttempt = 0
    function global:opencode {
        $global:quotaAttempt++
        $global:LASTEXITCODE = 0
        if ($global:quotaAttempt -eq 1) { '{"type":"error","error":{"code":"insufficient_credits","message":"token quota exhausted"}}' }
        else { Set-Content (Join-Path (Get-Location).Path 'allowed.md') 'fallback result'; '{"type":"result","status":"ok"}' }
    }
    & (Join-Path $package 'Invoke-KhoaWorker.ps1') -RepoPath $repo -ContractPath $contractPath -AllowModelFallback *> $null
    $allResults = @(Get-ChildItem (Join-Path $package 'runs') -Filter result.json -Recurse)
    $fallback = @($allResults | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.attempts.Count -eq 2 })
    if ($fallback.Count -ne 1 -or $fallback[0].status -ne 'completed' -or -not $fallback[0].attempts[0].quota_exhausted) { throw 'Quota fallback check failed.' }
    Write-Output 'quota detection and clean-worktree fallback: passed'

    $integration = Join-Path $package 'Invoke-KhoaIntegration.ps1'
    $resultPath = Get-ChildItem (Join-Path $package 'runs') -Filter result.json -Recurse | ForEach-Object FullName | Select-Object -Last 1
    try { & $integration -RepoPath $repo -WorkerResults $resultPath *> $null; throw 'Expected empty-check rejection' }
    catch { if ($_.Exception.Message -notmatch 'At least one integration check') { throw } }
    & $integration -RepoPath $repo -WorkerResults $resultPath -Checks @('Test-Path allowed.md') *> $null
    $integrationReport = Get-ChildItem (Join-Path $package 'runs') -Filter integration.json -Recurse | Select-Object -Last 1 | Get-Content -Raw | ConvertFrom-Json
    if ($integrationReport.status -ne 'passed') { throw 'Valid integration check did not pass.' }
    $beforeFail = $integrationReport.integration_commit
    try { & $integration -RepoPath $repo -WorkerResults $resultPath -Checks @('Test-Path missing.md') *> $null; throw 'Expected false check rejection' }
    catch { if ($_.Exception.Message -notmatch 'Integration check failed') { throw } }
    $failedReport = Get-ChildItem (Join-Path $package 'runs') -Filter integration.json -Recurse | Select-Object -Last 1 | Get-Content -Raw | ConvertFrom-Json
    if ($failedReport.status -ne 'failed' -or $failedReport.rollback_commit -ne $fallback[0].base_commit -or $failedReport.rollback_exit_code -ne 0) { throw 'False check or rollback validation failed.' }
    Write-Output 'integration required checks, false assertion and rollback: passed'
}
finally { Remove-Item Function:opencode -ErrorAction SilentlyContinue; Remove-Variable quotaAttempt -Scope Global -ErrorAction SilentlyContinue }
