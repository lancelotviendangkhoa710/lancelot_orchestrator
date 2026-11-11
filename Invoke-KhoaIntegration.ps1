[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepoPath,
    [Parameter(Mandatory)][string[]] $WorkerResults,
    [string[]] $Checks = @()
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath $RepoPath).Path
$root = (& git -C $repo rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $root) { throw 'RepoPath must be a Git repository.' }
$root = (Resolve-Path -LiteralPath $root.Trim()).Path
$runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$runDir = Join-Path $PSScriptRoot "runs\integration-$runId"
$tree = Join-Path $runDir 'worktree'
$branch = "khoa/integration/$runId"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$reportPath = Join-Path $runDir 'integration.json'
$report = [ordered]@{ status='starting'; repo=$root; worktree=$tree; branch=$branch; workers=@(); checks=@(); started_at=(Get-Date).ToString('o') }
try {
    $workers = @($WorkerResults | ForEach-Object { Get-Content -LiteralPath $_ -Raw -Encoding utf8 | ConvertFrom-Json })
    $base = (& git -C $root rev-parse HEAD).Trim()
    foreach ($worker in $workers) {
        if ($worker.status -ne 'completed' -or -not $worker.commit_sha -or $worker.repo -ne $root -or $worker.base_commit -ne $base) { throw "Worker $($worker.run_id) is not an accepted commit from the current base." }
        $actual = (& git -C $worker.worktree rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $actual -ne $worker.commit_sha) { throw "Worker $($worker.run_id) commit changed since review." }
    }
    & git -C $root worktree add --quiet -b $branch $tree $base
    if ($LASTEXITCODE -ne 0) { throw 'Integration worktree creation failed.' }
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
        Push-Location $tree
        try { & powershell -NoProfile -NonInteractive -Command $check *> $log; $code = $LASTEXITCODE }
        finally { Pop-Location }
        $report.checks += [ordered]@{ command=$check; exit_code=$code; log=$log }
        if ($code -ne 0) { throw "Integration check failed: $check" }
    }
    $report.status = 'passed'
}
catch { $report.status = 'failed'; $report.error = $_.Exception.Message }
finally {
    $report.completed_at = (Get-Date).ToString('o')
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
}
Write-Output "Integration status: $($report.status)"
Write-Output "Evidence: $reportPath"
if ($report.status -ne 'passed') { throw $report.error }
