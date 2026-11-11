[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepoPath,

    [string] $Task,

    [string] $ContractPath,

    [ValidateSet('ninerouter/claude-sonnet-4-6', 'ninerouter/claude-opus-4-6-thinking')]
    [string] $Model = 'ninerouter/claude-sonnet-4-6',

    [switch] $AllowModelFallback,

    [switch] $AutoApprove
)

$ErrorActionPreference = 'Stop'
if (-not $Task -and -not $ContractPath) { throw 'Provide -Task or -ContractPath.' }
$contract = $null
if ($ContractPath) {
    $contract = Get-Content -LiteralPath $ContractPath -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($field in @('objective','context','allowed_paths','forbidden_actions','implementation_requirements','acceptance_criteria')) {
        if (-not $contract.PSObject.Properties[$field] -or -not $contract.$field) { throw "Task contract requires $field." }
    }
    if (@($contract.allowed_paths).Count -eq 0) { throw 'allowed_paths must be nonempty.' }
    foreach ($path in @($contract.allowed_paths)) {
        if ([IO.Path]::IsPathRooted([string]$path) -or ([string]$path -match '(^|[\\/])\.\.([\\/]|$)')) { throw "Unsafe allowed path: $path" }
    }
    $Task = $contract | ConvertTo-Json -Depth 10
}
$repo = (Resolve-Path -LiteralPath $RepoPath).Path
$gitRoot = (& git -C $repo rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $gitRoot) {
    throw "RepoPath is not inside a Git repository: $RepoPath"
}
$gitRoot = (Resolve-Path -LiteralPath $gitRoot.Trim()).Path

$envFile = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path -LiteralPath $envFile)) {
    throw "Create $envFile from .env.example and add NINEROUTER_API_KEY."
}
$keyLine = Get-Content -LiteralPath $envFile -Encoding utf8 |
    Where-Object { $_ -match '^\s*NINEROUTER_API_KEY\s*=' } |
    Select-Object -First 1
if (-not $keyLine) { throw 'NINEROUTER_API_KEY is missing from .env.' }
$routerKey = ($keyLine -replace '^\s*NINEROUTER_API_KEY\s*=\s*', '').Trim().Trim('"').Trim("'")
if (-not $routerKey) { throw 'NINEROUTER_API_KEY is empty.' }

$runId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
$runDir = Join-Path $PSScriptRoot "runs\$runId"
$worktree = Join-Path $runDir 'worktree'
$branch = "khoa/worker/$runId"
$null = New-Item -ItemType Directory -Path $runDir -Force
$logPath = Join-Path $runDir 'worker.ndjson'
$metaPath = Join-Path $runDir 'result.json'
$prompt = @"
You are a bounded coding worker. Implement only this task in the current worktree.
Objective, context, allowed paths, forbidden actions, implementation requirements, and acceptance criteria follow:
$Task

Respect repository instructions. Do not run Docker, browser E2E, push, deploy, merge, delete project data, or edit outside allowed paths. The controller owns Git commit. Return a concise structured report: status, changed files, summary, checks, risks.
"@

$meta = [ordered]@{
    run_id = $runId
    repo = $gitRoot
    base_commit = (& git -C $gitRoot rev-parse HEAD).Trim()
    model = $Model
    worktree = $worktree
    branch = $branch
    log = $logPath
    started_at = (Get-Date).ToString('o')
    status = 'starting'
    attempts = @()
}

function Test-QuotaFailure([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        if ($line -notmatch '(?i)(rate.limit|quota|insufficient.credits|credit.balance|token.limit|tokens.exhausted|resource.exhausted|usage.limit|HTTP.429|status.?code.?429|status.?code.?402)') { continue }
        if ($line -match '(?i)("type"\s*:\s*"error"|"error"\s*:|"code"\s*:|"status"\s*:\s*(429|402)|^\s*(error|failed|HTTP))') { return $true }
    }
    return $false
}

$env:NINEROUTER_API_KEY = $routerKey
$env:OPENCODE_CONFIG = Join-Path $PSScriptRoot 'opencode.jsonc'
Remove-Variable routerKey, keyLine
try {
    & git -C $gitRoot worktree add --quiet -b $branch $worktree $meta.base_commit
    if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed.' }

    $workerConfig = Join-Path $runDir 'opencode.worker.json'
    $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'opencode.jsonc') -Raw -Encoding utf8 | ConvertFrom-Json
    $config.mcp.servers = [pscustomobject]@{}
    $config | Add-Member -NotePropertyName permissions -NotePropertyValue @(
        @{ action='shell'; resource='*'; effect='deny' },
        @{ action='external_directory'; resource='*'; effect='deny' }
    ) -Force
    $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $workerConfig -Encoding utf8
    $env:OPENCODE_CONFIG = $workerConfig

    $models = @($Model)
    if ($AllowModelFallback) {
        $models += if ($Model -eq 'ninerouter/claude-sonnet-4-6') { 'ninerouter/claude-opus-4-6-thinking' } else { 'ninerouter/claude-sonnet-4-6' }
    }
    for ($attempt = 0; $attempt -lt $models.Count; $attempt++) {
        $attemptLog = Join-Path $runDir "worker-attempt-$($attempt + 1).ndjson"
        Push-Location $worktree
        try {
            $commandArgs = @('--standalone', 'run', '--format', 'json', '--model', $models[$attempt], '--title', "Khoa worker $runId")
            if ($AutoApprove) { $commandArgs += '--auto' }
            $commandArgs += $prompt
            & opencode @commandArgs 2>&1 | Tee-Object -FilePath $attemptLog
            $attemptCode = $LASTEXITCODE
        }
        finally { Pop-Location }
        $quota = Test-QuotaFailure $attemptLog
        $meta.attempts += [ordered]@{ model=$models[$attempt]; exit_code=$attemptCode; quota_exhausted=$quota; log=$attemptLog }
        $meta.exit_code = $attemptCode
        $meta.status = if ($quota) { 'model_exhausted' } elseif ($attemptCode -eq 0) { 'completed' } else { 'failed' }
        Copy-Item -LiteralPath $attemptLog -Destination $logPath -Force
        if (-not $quota) { break }
        $dirty = @(& git -C $worktree ls-files --modified --others --deleted --exclude-standard)
        if ($dirty.Count -gt 0) { $meta.status = 'needs_review'; break }
    }

    $meta.completed_at = (Get-Date).ToString('o')
    $paths = @(& git -C $worktree ls-files --modified --others --deleted --exclude-standard)
    if ($contract) {
        $outside = @($paths | Where-Object {
            $candidate = $_
            -not (@($contract.allowed_paths | Where-Object { $candidate -like [string]$_ }).Count -gt 0)
        })
        if ($outside.Count) { $meta.status = 'scope_failed'; $meta.outside_paths = $outside }
    }
    if ($meta.status -eq 'completed' -and $paths.Count -gt 0) {
        & git -C $worktree add -- @paths
        if ($LASTEXITCODE -ne 0) { throw 'git add failed.' }
        & git -C $worktree -c user.name='Khoa Worker' -c user.email='worker@local.invalid' commit -m "khoa worker $runId"
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }
        $meta.commit_sha = (& git -C $worktree rev-parse HEAD).Trim()
    }
    $meta.diff_stat = (& git -C $worktree diff --stat)
    $meta.changed_files = $paths
    $meta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metaPath -Encoding utf8
    Write-Output "Worker $($meta.status). Review: $worktree"
    Write-Output "Log: $logPath"
    Write-Output "Metadata: $metaPath"
    if ($meta.status -eq 'scope_failed') { throw "Worker edited outside allowed paths: $($meta.outside_paths -join ', ')" }
    if ($meta.status -eq 'model_exhausted' -or $meta.status -eq 'needs_review') { throw "Worker model quota exhausted; status: $($meta.status). Review $metaPath before retrying." }
    if ($meta.exit_code -ne 0) { exit $meta.exit_code }
}
catch {
    $meta.error = $_.Exception.Message
    $meta.completed_at = (Get-Date).ToString('o')
    $meta | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metaPath -Encoding utf8
    throw
}
finally {
    Remove-Item Env:NINEROUTER_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:OPENCODE_CONFIG -ErrorAction SilentlyContinue
}
