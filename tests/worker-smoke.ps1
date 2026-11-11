$ErrorActionPreference = 'Stop'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('khoa-smoke-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $scratch 'package'
$repo = Join-Path $scratch 'repo'
New-Item -ItemType Directory -Path $package, $repo -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot '..\Invoke-KhoaWorker.ps1') $package
Copy-Item (Join-Path $PSScriptRoot '..\Invoke-KhoaSandbox.ps1') $package
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
    $workerOutput = @(& (Join-Path $package 'Invoke-KhoaWorker.ps1') -RepoPath $repo -ContractPath $contractPath -UnsafeHostExecution 2>$null)
    $resultFile = [string](($workerOutput | Where-Object { $_ -like 'Metadata: *' } | Select-Object -Last 1) -replace '^Metadata: ', '')
    if (-not $resultFile) { throw 'Worker did not identify its result metadata path.' }
    $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
    if ($result.status -ne 'completed' -or -not $result.commit_sha -or $result.changed_files -notcontains 'allowed.md') { throw 'Dispatch/report/commit check failed.' }
    if ($result.execution_mode -ne 'unsafe_host' -or -not $result.unsafe_host_execution -or -not $result.warnings.Count) { throw 'Unsafe host mode metadata warning was not recorded.' }
    $workerConfig = Join-Path (Split-Path $result.worktree) 'opencode.worker.json'
    $config = Get-Content $workerConfig -Raw | ConvertFrom-Json
    if (@($config.mcp.servers.PSObject.Properties).Count -ne 0 -or (@($config.permissions | Where-Object { $_.action -eq 'shell' -and $_.effect -eq 'deny' }).Count -ne 1)) { throw 'Worker permissions check failed.' }
    if ($config.providers.ninerouter.settings.baseURL -notmatch '^http://127\.0\.0\.1:20128/v1$') { throw 'Unsafe host mode should preserve its development provider endpoint.' }
    Write-Output 'worker dispatch, report and permissions: passed'
    function global:opencode {
        Set-Content (Join-Path (Get-Location).Path 'outside.md') 'scope violation'
        $global:LASTEXITCODE = 0
        '{"type":"result","status":"ok"}'
    }
    $resultsRoot = Join-Path $package 'runs'
    $beforeScope = @((Get-ChildItem $resultsRoot -Filter result.json -Recurse -ErrorAction SilentlyContinue).FullName)
    try { & (Join-Path $package 'Invoke-KhoaWorker.ps1') -RepoPath $repo -ContractPath $contractPath -UnsafeHostExecution *> $null; throw 'Expected scope failure' }
    catch { if ($_.Exception.Message -notmatch 'outside allowed paths') { throw } }
    $newScopeFiles = @(Get-ChildItem $resultsRoot -Filter result.json -Recurse | Where-Object { $beforeScope -notcontains $_.FullName })
    if ($newScopeFiles.Count -ne 1) { throw 'Could not uniquely identify scope failure metadata.' }
    $scopeResultFile = $newScopeFiles[0].FullName
    $scopeResult = Get-Content -LiteralPath $scopeResultFile -Raw | ConvertFrom-Json
    if ($scopeResult.status -ne 'scope_failed' -or $scopeResult.commit_sha) { throw 'Failure recovery check failed.' }
    Write-Output 'scope violation and preserved worktree: passed'
    $global:quotaAttempt = 0
    function global:opencode {
        $global:quotaAttempt++
        $global:LASTEXITCODE = 0
        if ($global:quotaAttempt -eq 1) { '{"type":"error","error":{"code":"insufficient_credits","message":"token quota exhausted"}}' }
        else { Set-Content (Join-Path (Get-Location).Path 'allowed.md') 'fallback result'; '{"type":"result","status":"ok"}' }
    }
    $fallbackOutput = @(& (Join-Path $package 'Invoke-KhoaWorker.ps1') -RepoPath $repo -ContractPath $contractPath -UnsafeHostExecution -AllowModelFallback 2>$null)
    $fallbackResultFile = [string](($fallbackOutput | Where-Object { $_ -like 'Metadata: *' } | Select-Object -Last 1) -replace '^Metadata: ', '')
    $fallbackResult = Get-Content -LiteralPath $fallbackResultFile -Raw | ConvertFrom-Json
    $allResults = @(Get-ChildItem (Join-Path $package 'runs') -Filter result.json -Recurse)
    if ($fallbackResult.status -ne 'completed' -or -not $fallbackResult.attempts[0].quota_exhausted -or $fallbackResult.attempts.Count -ne 2) { throw 'Quota fallback check failed.' }
    Write-Output 'quota detection and clean-worktree fallback: passed'

    $integration = Join-Path $package 'Invoke-KhoaIntegration.ps1'
    $resultPath = $fallbackResultFile
    try { & $integration -RepoPath $repo -WorkerResults $resultPath *> $null; throw 'Expected empty-check rejection' }
    catch { if ($_.Exception.Message -notmatch 'At least one integration check') { throw } }
    try { & $integration -RepoPath $repo -WorkerResults @() -Checks @('Test-Path allowed.md') *> $null; throw 'Expected empty-worker rejection' }
    catch { if ($_.Exception.Message -notmatch 'At least one completed worker result') { throw } }
    $integrationOutput = @(& $integration -RepoPath $repo -WorkerResults $resultPath -Checks @('Test-Path allowed.md') 2>$null)
    $integrationFile = [string](($integrationOutput | Where-Object { $_ -like 'Evidence: *' } | Select-Object -Last 1) -replace '^Evidence: ', '')
    $integrationReport = Get-Content -LiteralPath $integrationFile -Raw | ConvertFrom-Json
    if ($integrationReport.status -ne 'passed') { throw 'Valid integration check did not pass.' }
    $externalReport = Join-Path $scratch 'untrusted-result.json'
    Copy-Item -LiteralPath $resultPath -Destination $externalReport
    try { & $integration -RepoPath $repo -WorkerResults $externalReport -Checks @('Test-Path allowed.md') *> $null; throw 'Expected external report rejection' }
    catch { if ($_.Exception.Message -notmatch "result.json under this package's runs directory") { throw } }
    $failedFile = $null
    try { & $integration -RepoPath $repo -WorkerResults $resultPath -Checks @("Test-Path missing.md; Write-Output 'otherwise okay'") *> $null; throw 'Expected false check rejection' }
    catch {
        if ($_.Exception.Message -notmatch 'Integration check failed') { throw }
        if ($_.Exception.Message -match 'Evidence: (.+)$') { $failedFile = $Matches[1].Trim() }
    }
    if (-not $failedFile) { throw 'Failed integration did not identify its report path.' }
    $failedReport = Get-Content -LiteralPath $failedFile -Raw | ConvertFrom-Json
    if ($failedReport.status -ne 'failed' -or $failedReport.rollback_commit -ne $fallbackResult.base_commit -or $failedReport.rollback_exit_code -ne 0 -or -not $failedReport.rollback_verified) { throw 'False check or rollback validation failed.' }
    if ($failedReport.checks[-1].exit_code -eq 0) { throw 'Boolean false followed by other output incorrectly passed.' }
    Write-Output 'integration required checks, mixed false assertion and rollback: passed'

    $timeoutFile = $null
    $hungChildPidFile = Join-Path $scratch 'hung-child.pid'
    $hungCheck = "`$hungChild = Start-Process powershell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -PassThru; Set-Content -LiteralPath '$hungChildPidFile' `$hungChild.Id; Start-Sleep -Seconds 30"
    try { & $integration -RepoPath $repo -WorkerResults $resultPath -Checks @($hungCheck) -CheckTimeoutSeconds 2 *> $null; throw 'Expected integration check timeout' }
    catch {
        if ($_.Exception.Message -notmatch 'Integration check timed out') { throw }
        if ($_.Exception.Message -match 'Evidence: (.+)$') { $timeoutFile = $Matches[1].Trim() }
    }
    if (-not $timeoutFile) { throw 'Timed out integration did not identify its report path.' }
    $timeoutReport = Get-Content -LiteralPath $timeoutFile -Raw | ConvertFrom-Json
    if ($timeoutReport.status -ne 'failed' -or $timeoutReport.checks[-1].exit_code -ne 124 -or -not $timeoutReport.checks[-1].timed_out -or -not $timeoutReport.rollback_verified) { throw 'Timed check or rollback validation failed.' }
    if (Test-Path -LiteralPath $hungChildPidFile) {
        $childPid = [int](Get-Content -LiteralPath $hungChildPidFile -Raw)
        if (Get-Process -Id $childPid -ErrorAction SilentlyContinue) { throw 'Timed-out check left its child process running.' }
    } else { throw 'Hung integration check did not launch its child process.' }
    Write-Output 'bounded integration check and rollback: passed'

    # Tampering with report scope must not make the reviewed commit acceptable.
    $originalReport = Get-Content -LiteralPath $resultPath -Raw
    try {
        $tampered = $originalReport | ConvertFrom-Json
        $tampered.allowed_paths = @('outside.md')
        $tampered | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $resultPath -Encoding utf8
        try { & $integration -RepoPath $repo -WorkerResults $resultPath -Checks @('Test-Path allowed.md') *> $null; throw 'Expected scope metadata rejection' }
        catch { if ($_.Exception.Message -notmatch 'outside its allowlist') { throw } }
    } finally { Set-Content -LiteralPath $resultPath -Value $originalReport -Encoding utf8 }
    Write-Output 'tampered scope metadata rejection: passed'

    # A second independently based worker with the same changed path must be rejected before cherry-pick.
    $secondId = 'overlap-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $secondDir = Join-Path (Join-Path $package 'runs') $secondId
    $secondTree = Join-Path $secondDir 'worktree'
    $secondBranch = "khoa/worker/$secondId"
    New-Item -ItemType Directory -Path $secondDir -Force | Out-Null
    & git -C $repo worktree add --quiet -b $secondBranch $secondTree $fallbackResult.base_commit
    if ($LASTEXITCODE -ne 0) { throw 'Could not create overlapping test worktree.' }
    Set-Content (Join-Path $secondTree 'allowed.md') 'overlap result'
    & git -C $secondTree add -- allowed.md
    & git -C $secondTree -c user.name=Smoke -c user.email=smoke@local.invalid commit -qm overlap
    $secondCommit = (& git -C $secondTree rev-parse HEAD).Trim()
    $secondResult = [ordered]@{ run_id=$secondId; status='completed'; contract_enforced=$true; allowed_paths=@('allowed.md'); repo=$repo; base_commit=$fallbackResult.base_commit; worktree=$secondTree; branch=$secondBranch; commit_sha=$secondCommit; changed_files=@('allowed.md') }
    $secondResultPath = Join-Path $secondDir 'result.json'
    $secondResult | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $secondResultPath -Encoding utf8
    try { & $integration -RepoPath $repo -WorkerResults @($resultPath, $secondResultPath) -Checks @('Test-Path allowed.md') *> $null; throw 'Expected overlapping worker rejection' }
    catch { if ($_.Exception.Message -notmatch 'overlapping changes') { throw } }
    Write-Output 'overlapping worker rejection: passed'
}
finally { Remove-Item Function:opencode -ErrorAction SilentlyContinue; Remove-Variable quotaAttempt -Scope Global -ErrorAction SilentlyContinue }
