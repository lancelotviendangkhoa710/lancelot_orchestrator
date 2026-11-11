[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepoPath,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $WorkerResults,
    [string[]] $Checks = @(),
    [ValidateRange(1,300)][int] $CheckTimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
if (-not $Checks -or $Checks.Count -eq 0) { throw 'At least one integration check is required.' }
if (-not $WorkerResults -or $WorkerResults.Count -eq 0) { throw 'At least one completed worker result is required.' }
$repo = (Resolve-Path -LiteralPath $RepoPath).Path
$root = (& git -C $repo rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $root) { throw 'RepoPath must be a Git repository.' }
$root = (Resolve-Path -LiteralPath $root.Trim()).Path
$runsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'runs'))
$runsPrefix = $runsRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$runDir = Join-Path $PSScriptRoot "runs\integration-$runId"
$tree = Join-Path $runDir 'worktree'
$branch = "khoa/integration/$runId"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$reportPath = Join-Path $runDir 'integration.json'
$report = [ordered]@{ status='starting'; repo=$root; worktree=$tree; branch=$branch; workers=@(); checks=@(); started_at=(Get-Date).ToString('o') }
$integrationLock = $null
try {
    $lockPath = Join-Path $PSScriptRoot 'runs\integration.lock'
    try { $integrationLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Another integration is running; repository integration lock is held.' }
    $base = (& git -C $root rev-parse HEAD).Trim()
    $workers = @()
    $resultPaths = @{}
    foreach ($resultFile in $WorkerResults) {
        $resolvedResult = (Resolve-Path -LiteralPath $resultFile -ErrorAction Stop).Path
        if (-not $resolvedResult.StartsWith($runsPrefix, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedResult) -ne 'result.json') { throw "Worker report must be a result.json under this package's runs directory: $resultFile" }
        $worker = Get-Content -LiteralPath $resolvedResult -Raw -Encoding utf8 | ConvertFrom-Json
        if (-not $worker.run_id -or $worker.run_id -notmatch '^[A-Za-z0-9-]+$' -or $resultPaths.ContainsKey([string]$worker.run_id)) { throw 'Worker reports must have unique, valid run_id values.' }
        $resultPaths[[string]$worker.run_id] = $resolvedResult
        $workers += $worker
    }
    $claimedPaths = @{}
    $seenCommits = @{}
    foreach ($worker in $workers) {
        if ($worker.status -ne 'completed' -or $worker.contract_enforced -ne $true -or @($worker.allowed_paths).Count -eq 0 -or -not $worker.commit_sha -or $worker.repo -ne $root -or $worker.base_commit -ne $base -or $worker.branch -ne "khoa/worker/$($worker.run_id)") { throw "Worker $($worker.run_id) lacks valid contract/provenance metadata or is not a completed commit from the current base." }
        $expectedWorktree = Join-Path (Split-Path $resultPaths[[string]$worker.run_id]) 'worktree'
        $expectedWorktree = [IO.Path]::GetFullPath($expectedWorktree)
        if (-not $worker.worktree -or [IO.Path]::GetFullPath([string]$worker.worktree) -ne $expectedWorktree -or -not (Test-Path -LiteralPath $expectedWorktree -PathType Container)) { throw "Worker $($worker.run_id) worktree metadata does not match its report location." }
        $actual = (& git -C $worker.worktree rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $actual -ne $worker.commit_sha) { throw "Worker $($worker.run_id) commit changed since review." }
        if ($seenCommits.ContainsKey([string]$worker.commit_sha)) { throw "Duplicate worker commit: $($worker.commit_sha)." }
        $seenCommits[[string]$worker.commit_sha] = $true
        $parents = (& git -C $root show -s --format=%P $worker.commit_sha).Trim()
        if ($LASTEXITCODE -ne 0 -or $parents -ne $base) { throw "Worker $($worker.run_id) commit is not a direct child of the declared base." }
        $changed = @(& git -C $worker.worktree diff-tree --no-commit-id --name-only -r $worker.commit_sha)
        if ($LASTEXITCODE -ne 0 -or -not $changed.Count) { throw "Worker $($worker.run_id) has no verifiable changed files." }
        if (@($worker.allowed_paths).Count -gt 0) {
            $outside = @($changed | Where-Object {
                $candidate = $_
                -not (@($worker.allowed_paths | Where-Object { $candidate -like [string]$_ }).Count -gt 0)
            })
            if ($outside.Count) { throw "Worker $($worker.run_id) commit contains paths outside its allowlist: $($outside -join ', ')" }
        }
        if (-not $worker.changed_files -or (@(Compare-Object @($worker.changed_files | Sort-Object -Unique) @($changed | Sort-Object -Unique)).Count -gt 0)) {
            throw "Worker $($worker.run_id) changed_files metadata does not match its commit."
        }
        foreach ($path in $changed) {
            if ($claimedPaths.ContainsKey([string]$path)) { throw "Workers $($claimedPaths[[string]$path]) and $($worker.run_id) have overlapping changes to $path." }
            $claimedPaths[[string]$path] = [string]$worker.run_id
        }
    }
    & git -C $root worktree add --quiet -b $branch $tree $base
    if ($LASTEXITCODE -ne 0) { throw 'Integration worktree creation failed.' }
    $integrationBase = $base
    foreach ($worker in $workers) {
        & git -C $tree cherry-pick --no-edit $worker.commit_sha *> (Join-Path $runDir "merge-$($worker.run_id).log")
        if ($LASTEXITCODE -ne 0) {
            & git -C $tree cherry-pick --abort *> $null
            throw "Integration conflict for worker $($worker.run_id)."
        }
        $report.workers += [ordered]@{ run_id=$worker.run_id; source_commit=$worker.commit_sha; integration_commit=(& git -C $tree rev-parse HEAD).Trim() }
    }
    $report.integration_commit = (& git -C $tree rev-parse HEAD).Trim()
    foreach ($check in $Checks) {
        $index = $report.checks.Count
        $log = Join-Path $runDir "check-$index.log"
        $stdoutLog = Join-Path $runDir "check-$index.stdout.log"
        $stderrLog = Join-Path $runDir "check-$index.stderr.log"
        $statusFile = Join-Path $runDir "check-$index.exit"
        $quotedStatusFile = $statusFile.Replace("'", "''")
        $wrappedCheck = "try { `$checkResult = & { $check }; `$falseResults = @(`$checkResult | Where-Object { `$_ -is [bool] -and `$_ -eq `$false }); if (`$falseResults.Count -gt 0) { [IO.File]::WriteAllText('$quotedStatusFile', '1'); exit 1 }; [IO.File]::WriteAllText('$quotedStatusFile', '0') } catch { [IO.File]::WriteAllText('$quotedStatusFile', '1'); exit 1 }"
        $encodedCheck = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrappedCheck))
        $powershellPath = (Get-Command powershell -CommandType Application -ErrorAction Stop).Source
        $timedOut = $false
        $process = $null
        try {
            $process = Start-Process -FilePath $powershellPath -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encodedCheck) -WorkingDirectory $tree -PassThru -NoNewWindow -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
            if (-not $process.WaitForExit($CheckTimeoutSeconds * 1000)) {
                $timedOut = $true
                $taskKill = Get-Command taskkill.exe -CommandType Application -ErrorAction SilentlyContinue
                if ($taskKill) { & $taskKill.Source /PID $process.Id /T /F *> $null }
                if (-not $process.HasExited) { $process.Kill() }
                $process.WaitForExit()
                $code = 124
            } else {
                $process.WaitForExit()
                if (Test-Path -LiteralPath $statusFile) { $code = [int](Get-Content -LiteralPath $statusFile -Raw) } else { $code = 1 }
            }
        }
        catch {
            if ($process -and -not $process.HasExited) {
                $taskKill = Get-Command taskkill.exe -CommandType Application -ErrorAction SilentlyContinue
                if ($taskKill) { & $taskKill.Source /PID $process.Id /T /F *> $null }
                if (-not $process.HasExited) { $process.Kill() }
                $process.WaitForExit()
            }
            throw
        }
        finally { if ($process) { $process.Dispose() } }
        @((Get-Content -LiteralPath $stdoutLog -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $stderrLog -ErrorAction SilentlyContinue)) | Set-Content -LiteralPath $log -Encoding utf8
        $checkHead = (& git -C $tree rev-parse HEAD 2>$null).Trim()
        $checkBranch = (& git -C $tree branch --show-current 2>$null).Trim()
        $checkDirty = @(& git -C $tree status --porcelain --untracked-files=all 2>$null)
        if ($LASTEXITCODE -ne 0 -or $checkHead -ne $report.integration_commit -or $checkBranch -ne $branch -or $checkDirty.Count -gt 0) { $code = 1 }
        $report.checks += [ordered]@{ command=$check; exit_code=$code; timed_out=$timedOut; timeout_seconds=$CheckTimeoutSeconds; log=$log }
        if ($code -ne 0) { if ($timedOut) { throw "Integration check timed out after $CheckTimeoutSeconds seconds: $check" } else { throw "Integration check failed: $check" } }
    }
    $report.status = 'passed'
}
catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
    if ($integrationBase -and (Test-Path -LiteralPath $tree)) {
        $rollbackBranch = (& git -C $tree branch --show-current 2>$null).Trim()
        if ($rollbackBranch -ne $branch) {
            $report.rollback_verified = $false
            $report.status = 'rollback_failed'
            $report.error += ' Rollback refused because the integration branch changed.'
        } else {
            & git -C $tree reset --hard $integrationBase *> $null
            $report.rollback_commit = $integrationBase
            $report.rollback_exit_code = $LASTEXITCODE
        }
        if ($report.rollback_exit_code -ne 0 -or -not $report.rollback_commit -or (& git -C $tree rev-parse HEAD 2>$null).Trim() -ne $integrationBase) {
            $report.rollback_verified = $false
            $report.status = 'rollback_failed'
            $report.error += ' Rollback could not be verified.'
        } else { $report.rollback_verified = $true }
    }
}
finally {
    try {
        $report.completed_at = (Get-Date).ToString('o')
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
    }
    finally { if ($integrationLock) { $integrationLock.Dispose() } }
}
Write-Output "Integration status: $($report.status)"
Write-Output "Evidence: $reportPath"
if ($report.status -ne 'passed') { throw "$($report.error) Evidence: $reportPath" }
