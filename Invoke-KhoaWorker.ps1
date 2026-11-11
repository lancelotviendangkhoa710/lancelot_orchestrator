[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RepoPath,

    [string] $Task,

    [string] $ContractPath,

    [switch] $UnsafeHostExecution,

    [string] $EnvFile,

    [string] $SandboxImage = 'ghcr.io/anomalyco/opencode:2.2.5@sha256:205e1bf535120ea110c1f93cbed0e91844fbb887725e7e70a44698f052f34328',

    [string] $ProviderNetwork,

    [ValidateSet('ninerouter/claude-sonnet-4-6', 'ninerouter/claude-opus-4-6-thinking')]
    [string] $Model = 'ninerouter/claude-sonnet-4-6',

    [switch] $AllowModelFallback,

    [switch] $AutoApprove
)

$ErrorActionPreference = 'Stop'
if (-not $Task -and -not $ContractPath) { throw 'Provide -Task or -ContractPath.' }
if (-not $UnsafeHostExecution -and $SandboxImage -notmatch '^ghcr\.io/anomalyco/opencode:[0-9][A-Za-z0-9._-]*@sha256:[0-9a-fA-F]{64}$') { throw 'SandboxImage must be the official ghcr.io/anomalyco/opencode image pinned by version and sha256 digest.' }
$contract = $null
if ($ContractPath) {
    $contract = Get-Content -LiteralPath $ContractPath -Raw -Encoding utf8 | ConvertFrom-Json
    foreach ($field in @('objective','context','allowed_paths','forbidden_actions','implementation_requirements','acceptance_criteria')) {
        if (-not $contract.PSObject.Properties[$field]) { throw "Task contract requires $field." }
    }
    foreach ($field in @('allowed_paths','forbidden_actions','implementation_requirements','acceptance_criteria')) {
        if ($contract.$field -isnot [array] -or @($contract.$field).Count -eq 0 -or @($contract.$field | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count) { throw "$field must be a nonempty array of nonempty strings." }
    }
    foreach ($field in @('objective','context')) { if ($contract.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($contract.$field)) { throw "$field must be a nonempty string." } }
    if ($contract.PSObject.Properties['timeout_seconds'] -and ($contract.timeout_seconds -isnot [int] -and $contract.timeout_seconds -isnot [long] -or $contract.timeout_seconds -lt 30 -or $contract.timeout_seconds -gt 90)) { throw 'timeout_seconds must be an integer between 30 and 90.' }
    if ($contract.PSObject.Properties['retry_limit'] -and ($contract.retry_limit -isnot [int] -and $contract.retry_limit -isnot [long] -or $contract.retry_limit -lt 0 -or $contract.retry_limit -gt 2)) { throw 'retry_limit must be an integer between 0 and 2.' }
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

$envFile = if ($EnvFile) { $EnvFile } else { Join-Path $PSScriptRoot '.env' }
if (-not (Test-Path -LiteralPath $envFile)) {
    throw "Create $envFile from .env.example and add NINEROUTER_API_KEY."
}
$keyLine = Get-Content -LiteralPath $envFile -Encoding utf8 |
    Where-Object { $_ -match '^\s*NINEROUTER_API_KEY\s*=' } |
    Select-Object -First 1
if (-not $keyLine) { throw 'NINEROUTER_API_KEY is missing from .env.' }
$routerKey = ($keyLine -replace '^\s*NINEROUTER_API_KEY\s*=\s*', '').Trim().Trim('"').Trim("'")
if (-not $routerKey) { throw 'NINEROUTER_API_KEY is empty.' }
$hadProcessApiKey = Test-Path Env:NINEROUTER_API_KEY
$previousProcessApiKey = $env:NINEROUTER_API_KEY

$runId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
$runDir = Join-Path $PSScriptRoot "runs\$runId"
$worktree = Join-Path $runDir 'worktree'
$branch = "khoa/worker/$runId"
$null = New-Item -ItemType Directory -Path $runDir -Force
$logPath = Join-Path $runDir 'worker.ndjson'
$metaPath = Join-Path $runDir 'result.json'
$promptPath = Join-Path $runDir 'task.prompt.md'
$script:metaPath = $metaPath
$script:meta = $null
$script:transientOutputPaths = @()
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
    contract_enforced = [bool]$contract
    allowed_paths = if ($contract) { @($contract.allowed_paths) } else { @() }
    model = $Model
    execution_mode = if ($UnsafeHostExecution) { 'unsafe_host' } else { 'docker_sandbox' }
    unsafe_host_execution = [bool]$UnsafeHostExecution
    sandbox_image = if ($UnsafeHostExecution) { $null } else { $SandboxImage }
    provider_network = if ($UnsafeHostExecution) { $null } else { $ProviderNetwork }
    sandbox_container_name = $null
    sandbox_container_id = $null
    sandbox_started_at = $null
    worktree = $worktree
    branch = $branch
    log = $logPath
    started_at = (Get-Date).ToString('o')
    status = 'starting'
    attempts = @()
}
$meta.warnings = if ($UnsafeHostExecution) { @('Unsafe host execution explicitly enabled; the worker process can access host-visible data and tools.') } else { @() }
if ($UnsafeHostExecution) { Write-Warning 'Unsafe host execution enabled; this worker is not isolated from host-visible resources.' }
$script:meta = $meta

function Save-WorkerMetadata {
    if (-not $script:meta) { return }
    $tmp = "$script:metaPath.tmp"
    $script:meta | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:metaPath -Force
}

function Resolve-WorktreePath([string] $RelativePath) {
    $cursor = $worktree
    foreach ($segment in ($RelativePath -split '[\\/]')) {
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            $entry = Get-Item -LiteralPath $cursor -Force
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
    }
    $candidate = Join-Path $worktree $RelativePath
    $parent = Split-Path -Parent $candidate
    while ($parent -and -not (Test-Path -LiteralPath $parent)) { $parent = Split-Path -Parent $parent }
    if (Test-Path -LiteralPath $candidate) { $resolved = (Resolve-Path -LiteralPath $candidate).Path }
    elseif ($parent) { $resolved = Join-Path (Resolve-Path -LiteralPath $parent).Path (Split-Path -Leaf $candidate) }
    else { $resolved = $candidate }
    $root = [IO.Path]::GetFullPath($worktree).TrimEnd('\') + '\'
    return [IO.Path]::GetFullPath($resolved).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

function Test-QuotaFailure([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        if ($line -notmatch '(?i)(rate.limit|quota|insufficient.credits|credit.balance|token.limit|tokens.exhausted|resource.exhausted|usage.limit|HTTP.429|status.?code.?429|status.?code.?402)') { continue }
        if ($line -match '(?i)("type"\s*:\s*"error"|"error"\s*:|"code"\s*:|"status"\s*:\s*(429|402)|^\s*(error|failed|HTTP))') { return $true }
    }
    return $false
}

$hostEnvSet = $false
if ($UnsafeHostExecution) {
    $env:NINEROUTER_API_KEY = $routerKey
    $env:OPENCODE_CONFIG = Join-Path $PSScriptRoot 'opencode.jsonc'
    $hostEnvSet = $true
}
Remove-Variable keyLine
$script:secretForRedaction = $routerKey
Save-WorkerMetadata
try {
    if (-not $UnsafeHostExecution) {
        if (-not $ProviderNetwork) { $meta.status='blocked'; throw 'Provider network is required for sandbox dispatch.' }
        $preflightRunner = Join-Path $PSScriptRoot 'Invoke-KhoaSandbox.ps1'
        if (-not (Test-Path -LiteralPath $preflightRunner -PathType Leaf)) { $meta.status='blocked'; throw 'Docker sandbox runner is missing; worker dispatch is blocked.' }
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { $meta.status='blocked'; throw 'Docker CLI is unavailable; sandbox worker dispatch is blocked.' }
        $imageCheck = & docker image inspect --format '{{.Id}}' $SandboxImage 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $imageCheck) { $meta.status='blocked'; throw "Pinned OpenCode sandbox image is not present locally: $SandboxImage. Pull it explicitly before dispatch." }
    }
    & git -C $gitRoot worktree add --quiet -b $branch $worktree $meta.base_commit
    if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed.' }

    $workerConfig = Join-Path $runDir 'opencode.worker.json'
    $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'opencode.jsonc') -Raw -Encoding utf8 | ConvertFrom-Json
    $config.mcp.servers = [pscustomobject]@{}
    if (-not $UnsafeHostExecution) { $config.providers.ninerouter.settings.baseURL = 'http://khoa-router-proxy:8080/v1' }
    $config | Add-Member -NotePropertyName permissions -NotePropertyValue @(
        @{ action='shell'; resource='*'; effect='deny' },
        @{ action='execute'; resource='*'; effect='deny' },
        @{ action='subagent'; resource='*'; effect='deny' },
        @{ action='external_directory'; resource='*'; effect='deny' }
    ) -Force
    $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $workerConfig -Encoding utf8
    $configMount = '/run/khoa/config/opencode.worker.json'
    $promptMount = '/run/khoa/prompt/task.prompt.md'
    Set-Content -LiteralPath $promptPath -Value $prompt -Encoding utf8
    if ($UnsafeHostExecution) { $env:OPENCODE_CONFIG = $workerConfig }
    else {
        try { $null = & $preflightRunner -PreflightOnly -WorktreePath $worktree -Command @('true') -Image $SandboxImage -IsolatedNetwork $ProviderNetwork }
        catch { $meta.status='blocked'; throw }
    }
    Remove-Variable routerKey

    $meta.status = 'running'
    Save-WorkerMetadata

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
            $stdoutPath = Join-Path $runDir "attempt-$($attempt + 1).stdout"
            $stderrPath = Join-Path $runDir "attempt-$($attempt + 1).stderr"
            $script:transientOutputPaths += @($stdoutPath, $stderrPath)
            $quotedArgs = @('--standalone','run','--format','json','--model',$models[$attempt],'--title',"Khoa worker $runId")
            if ($AutoApprove) { $quotedArgs += '--auto' }
            if ($UnsafeHostExecution) { $quotedArgs += $prompt }
            else { $quotedArgs += @('--file','/run/khoa/prompt/task.prompt.md','Implement the attached task prompt.') }
            $quoted = @($quotedArgs | ForEach-Object { '"' + ([string]$_ -replace '"','`"') + '"' })
            $timeout = if ($contract -and $contract.PSObject.Properties['timeout_seconds']) { [int]$contract.timeout_seconds } else { 90 }
            $opencodeCommand = $null
            if ($UnsafeHostExecution) { $opencodeCommand = Get-Command opencode -ErrorAction Stop }
            if ($UnsafeHostExecution -and $opencodeCommand.CommandType -eq 'Function') {
                # Supports local PowerShell harnesses; the real executable always uses the timeout-enforced child process.
                & opencode @quotedArgs 2>&1 | Set-Content -LiteralPath $stdoutPath -Encoding utf8
                $attemptCode = $LASTEXITCODE
                if ($null -eq $attemptCode) { $attemptCode = 0 }
                if (-not (Test-Path -LiteralPath $stderrPath)) { Set-Content -LiteralPath $stderrPath -Value '' }
            } elseif ($UnsafeHostExecution) {
                $launchFile = $opencodeCommand.Source
                if ($opencodeCommand.CommandType -eq 'ExternalScript') {
                    $launchFile = Join-Path $PSHOME 'powershell.exe'
                    $quoted = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $opencodeCommand.Source + '"')) + $quoted
                }
                $process = Start-Process -FilePath $launchFile -ArgumentList $quoted -PassThru -NoNewWindow -WorkingDirectory $worktree -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
                if (-not $process.WaitForExit($timeout * 1000)) {
                    if ($env:OS -eq 'Windows_NT') {
                        & taskkill.exe /PID $process.Id /T /F *> $null
                        if (-not $process.HasExited) { $process.Kill() }
                    } else { $process.Kill() }
                    $process.WaitForExit()
                    $attemptCode = 124
                    $meta.status = 'timed_out'
                } else { $attemptCode = $process.ExitCode }
            } else {
                $containerName = 'khoa-sandbox-' + $runId + '-a' + ($attempt + 1)
                $meta.sandbox_container_name = $containerName
                $meta.sandbox_started_at = (Get-Date).ToString('o')
                Save-WorkerMetadata
                $env:NINEROUTER_API_KEY = $script:secretForRedaction
                try {
                    $sandboxResult = & (Join-Path $PSScriptRoot 'Invoke-KhoaSandbox.ps1') -WorktreePath $worktree -Command $quotedArgs -Image $SandboxImage -TimeoutSeconds $timeout -IsolatedNetwork $ProviderNetwork -ContainerName $containerName -Environment @('OPENCODE_CONFIG=/run/khoa/config/opencode.worker.json','HOME=/home/opencode') -PassEnvironment @('NINEROUTER_API_KEY') -RedactSecret $script:secretForRedaction -ReadOnlyMounts @(
                        @{ Source=$workerConfig; Target='/run/khoa/config/opencode.worker.json' },
                        @{ Source=$promptPath; Target='/run/khoa/prompt/task.prompt.md' }
                    )
                } finally {
                    if ($hadProcessApiKey) { $env:NINEROUTER_API_KEY = $previousProcessApiKey }
                    else { Remove-Item Env:NINEROUTER_API_KEY -ErrorAction SilentlyContinue }
                }
                $attemptCode = [int]$sandboxResult.exit_code
                if ($sandboxResult.status -eq 'timed_out') { $meta.status='timed_out' }
                $meta.sandbox_container_id = $sandboxResult.container_id
                $sandboxResult.output -replace '(?i)(NINEROUTER_API_KEY\s*[=:]\s*)[^\s"\\]+','$1[REDACTED]' -replace [regex]::Escape($script:secretForRedaction),'[REDACTED]' | Set-Content -LiteralPath $attemptLog -Encoding utf8
            }
            if ($UnsafeHostExecution) { @((Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue)) |
                ForEach-Object { $_ -replace '(?i)(NINEROUTER_API_KEY\s*[=:]\s*)[^\s"\\]+','$1[REDACTED]' -replace [regex]::Escape($script:secretForRedaction),'[REDACTED]' } |
                Set-Content -LiteralPath $attemptLog -Encoding utf8 }
            Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
        }
        finally { Pop-Location }
        $quota = Test-QuotaFailure $attemptLog
        $meta.attempts += [ordered]@{ model=$models[$attempt]; exit_code=$attemptCode; quota_exhausted=$quota; log=$attemptLog; sandbox_container_name=if ($UnsafeHostExecution) { $null } else { $containerName } }
        $meta.exit_code = $attemptCode
        if ($meta.status -ne 'timed_out') { $meta.status = if ($quota) { 'model_exhausted' } elseif ($attemptCode -eq 0) { 'completed' } else { 'failed' } }
        Copy-Item -LiteralPath $attemptLog -Destination $logPath -Force
        Save-WorkerMetadata
        if ($meta.status -eq 'timed_out') { break }
        if (-not $quota) { break }
        $dirty = @(& git -C $worktree ls-files --modified --others --deleted --exclude-standard)
        if ($dirty.Count -gt 0) { $meta.status = 'needs_review'; break }
    }

    $meta.completed_at = (Get-Date).ToString('o')
    $paths = @(& git -C $worktree ls-files --modified --others --deleted --exclude-standard)
    if ($contract) {
        $outside = @($paths | Where-Object {
            $candidate = $_
            -not (Resolve-WorktreePath $candidate) -or -not (@($contract.allowed_paths | Where-Object { $candidate -like [string]$_ }).Count -gt 0)
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
    Save-WorkerMetadata
    Write-Output "Worker $($meta.status). Review: $worktree"
    Write-Output "Log: $logPath"
    Write-Output "Metadata: $metaPath"
    if ($meta.status -eq 'scope_failed') { throw "Worker edited outside allowed paths: $($meta.outside_paths -join ', ')" }
    if ($meta.status -eq 'model_exhausted' -or $meta.status -eq 'needs_review') { throw "Worker model quota exhausted; status: $($meta.status). Review $metaPath before retrying." }
    if ($meta.exit_code -ne 0) { exit $meta.exit_code }
}
catch {
    $meta.error = $_.Exception.Message -replace [regex]::Escape([string]$script:secretForRedaction),'[REDACTED]'
    if ($meta.status -in @('starting','running')) { $meta.status='failed' }
    $meta.completed_at = (Get-Date).ToString('o')
    Save-WorkerMetadata
    throw $meta.error
}
finally {
    if ($script:transientOutputPaths.Count -gt 0) { Remove-Item -LiteralPath $script:transientOutputPaths -Force -ErrorAction SilentlyContinue }
    if ($hostEnvSet) {
        if ($hadProcessApiKey) { $env:NINEROUTER_API_KEY = $previousProcessApiKey }
        else { Remove-Item Env:NINEROUTER_API_KEY -ErrorAction SilentlyContinue }
        Remove-Item Env:OPENCODE_CONFIG -ErrorAction SilentlyContinue
    }
    Remove-Variable secretForRedaction -Scope Script -ErrorAction SilentlyContinue
}
