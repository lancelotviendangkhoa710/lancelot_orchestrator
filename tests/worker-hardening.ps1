$ErrorActionPreference = 'Stop'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('khoa-hardening-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $scratch 'package'
$repo = Join-Path $scratch 'repo'
$bin = Join-Path $scratch 'bin'
New-Item -ItemType Directory -Path $package, $repo, $bin -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot '..\Invoke-KhoaWorker.ps1') $package
Copy-Item (Join-Path $PSScriptRoot '..\Invoke-KhoaSandbox.ps1') $package
Copy-Item (Join-Path $PSScriptRoot '..\opencode.jsonc') $package
Set-Content (Join-Path $package '.env') 'NINEROUTER_API_KEY=test-only-key'
@'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake.ps1" %*
'@ | Set-Content (Join-Path $bin 'opencode.cmd')
@'
if ($env:FAKE_MODE -eq 'sleep') { Start-Sleep -Seconds 40; exit 0 }
Set-Content (Join-Path (Get-Location).Path 'outside.md') 'out of scope'
Write-Output "NINEROUTER_API_KEY=$env:NINEROUTER_API_KEY"
Write-Output '{"type":"result","status":"ok"}'
'@ | Set-Content (Join-Path $bin 'fake.ps1')
& git -C $repo init -q
Set-Content (Join-Path $repo 'README.md') 'baseline'
& git -C $repo add README.md
& git -C $repo -c user.name=Smoke -c user.email=smoke@local.invalid commit -qm baseline
$contract = [ordered]@{
    task_id='hardening'; objective='Exercise worker boundaries'; context='Temporary repository';
    allowed_paths=@('allowed.md'); forbidden_actions=@('deploy');
    implementation_requirements=@('stay within scope'); acceptance_criteria=@('metadata persists');
    timeout_seconds=30; retry_limit=0
}
$contractPath = Join-Path $scratch 'contract.json'
$contract | ConvertTo-Json | Set-Content $contractPath
$oldPath = $env:PATH
try {
    $env:PATH = "$bin;$oldPath"
    function global:docker { $global:LASTEXITCODE=0; 'sha256:fixture' }
    $before = @(Get-ChildItem (Join-Path $package 'runs') -Filter result.json -Recurse -ErrorAction SilentlyContinue)
    try { & (Join-Path $package 'Invoke-KhoaWorker.ps1') -RepoPath $repo -ContractPath $contractPath *> $null; throw 'Expected default sandbox block.' }
    catch { if ($_.Exception.Message -notmatch 'Provider network is required') { throw } }
    $blocked = @(Get-ChildItem (Join-Path $package 'runs') -Filter result.json -Recurse | Where-Object { $before.FullName -notcontains $_.FullName })
    if ($blocked.Count -ne 1 -or (Get-Content $blocked[0].FullName -Raw | ConvertFrom-Json).status -ne 'blocked') { throw 'Default dispatch did not record a fail-closed status.' }
    @'
param([string]$WorktreePath,[string[]]$Command,[string]$Image,[string]$IsolatedNetwork,[string]$ContainerName,[string[]]$Environment,[string[]]$PassEnvironment,[string]$RedactSecret,[hashtable[]]$ReadOnlyMounts,[switch]$PreflightOnly)
if ($PreflightOnly) { return }
if ($Image -notmatch '^ghcr.io/anomalyco/opencode:2.2.5@sha256:' -or $IsolatedNetwork -ne 'fixture-isolated') { throw 'Sandbox image/network parameters were not passed.' }
if ($env:NINEROUTER_API_KEY -ne 'test-only-key' -or @($PassEnvironment) -notcontains 'NINEROUTER_API_KEY') { throw 'Credential was not passed via environment-name-only.' }
if (@($Command | Where-Object { $_ -match 'test-only-key' }).Count -or @($Environment | Where-Object { $_ -match 'test-only-key' }).Count) { throw 'Credential appeared in sandbox command/config arguments.' }
$configMount = @($ReadOnlyMounts | Where-Object { $_.Target -eq '/run/khoa/config/opencode.worker.json' })[0]
$promptMount = @($ReadOnlyMounts | Where-Object { $_.Target -eq '/run/khoa/prompt/task.prompt.md' })[0]
$config = Get-Content -LiteralPath $configMount.Source -Raw | ConvertFrom-Json
if ($config.providers.ninerouter.settings.baseURL -ne 'http://khoa-router-proxy:8080/v1') { throw 'Sandbox provider route was not rewritten to the proxy endpoint.' }
if ((Get-Content -LiteralPath $promptMount.Source -Raw) -notmatch 'Exercise worker boundaries') { throw 'Read-only task prompt was not mounted.' }
Set-Content -LiteralPath (Join-Path $WorktreePath 'allowed.md') 'sandbox result'
[pscustomobject]@{ exit_code=0; status='completed'; output="NINEROUTER_API_KEY=$env:NINEROUTER_API_KEY" }
'@ | Set-Content (Join-Path $package 'Invoke-KhoaSandbox.ps1')
    $beforeSandbox = @(Get-ChildItem (Join-Path $package 'runs') -Filter result.json -Recurse)
    $sandboxOutput = @(& (Join-Path $package 'Invoke-KhoaWorker.ps1') -RepoPath $repo -ContractPath $contractPath -ProviderNetwork 'fixture-isolated' 2>$null)
    $sandboxFiles = @(Get-ChildItem (Join-Path $package 'runs') -Filter result.json -Recurse | Where-Object { $beforeSandbox.FullName -notcontains $_.FullName })
    if ($sandboxFiles.Count -ne 1) { throw 'Could not identify default sandbox dispatch metadata.' }
    $sandboxResult = Get-Content $sandboxFiles[0].FullName -Raw | ConvertFrom-Json
    if ($sandboxResult.status -ne 'completed' -or $sandboxResult.execution_mode -ne 'docker_sandbox' -or $sandboxResult.unsafe_host_execution -or -not $sandboxResult.sandbox_container_name -or -not $sandboxResult.sandbox_started_at) { throw 'Default sandbox execution metadata is incomplete.' }
    foreach ($artifact in @(Get-ChildItem (Join-Path (Split-Path $sandboxFiles[0].FullName) '') -File -Recurse | Where-Object { $_.Extension -in @('.json','.ndjson') })) { if ((Get-Content $artifact.FullName -Raw) -match 'test-only-key') { throw 'API key leaked into sandbox result or log.' } }
    Write-Output 'default sandbox config, proxy route, credential name-only pass, and metadata: passed'

    Copy-Item (Join-Path $PSScriptRoot '..\Invoke-KhoaSandbox.ps1') (Join-Path $package 'Invoke-KhoaSandbox.ps1') -Force
    $env:FAKE_MODE = 'scope'
    try { & (Join-Path $package 'Invoke-KhoaWorker.ps1') -RepoPath $repo -ContractPath $contractPath -UnsafeHostExecution *> $null; throw 'Expected scope rejection.' }
    catch { if ($_.Exception.Message -notmatch 'outside allowed paths') { throw } }
    $scopeResult = Get-ChildItem (Join-Path $package 'runs') -Filter result.json -Recurse | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object status -eq 'scope_failed' | Select-Object -First 1
    if ($scopeResult.status -ne 'scope_failed' -or -not $scopeResult.outside_paths) { throw 'Scope failure metadata was not preserved.' }
    $artifacts = Get-ChildItem (Join-Path $package 'runs') -File -Recurse
    if (@($artifacts | Where-Object { $_.Name -match '\.(stdout|stderr)$' }).Count) { throw 'Raw process output was retained.' }
    foreach ($artifact in @($artifacts | Where-Object { $_.Extension -in @('.ndjson', '.json') })) {
        if ((Get-Content -LiteralPath $artifact.FullName -Raw) -match 'test-only-key') { throw "API key leaked into $($artifact.FullName)." }
    }

    $env:FAKE_MODE = 'sleep'
    $short = [ordered]@{
        task_id='hardening-timeout'; objective='Exercise worker timeout'; context='Temporary repository';
        allowed_paths=@('allowed.md'); forbidden_actions=@('deploy');
        implementation_requirements=@('respect timeout'); acceptance_criteria=@('timeout metadata persists');
        timeout_seconds=30; retry_limit=0
    }
    $shortPath = Join-Path $scratch 'timeout.json'; $short | ConvertTo-Json | Set-Content $shortPath
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $workerScript = Join-Path $package 'Invoke-KhoaWorker.ps1'
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$workerScript`"",'-RepoPath',"`"$repo`"",'-ContractPath',"`"$shortPath`"",'-UnsafeHostExecution')
    $child = Start-Process powershell.exe -ArgumentList $args -PassThru -Wait -NoNewWindow -RedirectStandardOutput (Join-Path $scratch 'timeout.out') -RedirectStandardError (Join-Path $scratch 'timeout.err')
    if ($child.ExitCode -ne 124) { throw "Expected timeout exit code 124, got $($child.ExitCode)." }
    $clock.Stop()
    $timeoutResult = Get-ChildItem (Join-Path $package 'runs') -Filter result.json -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Raw | ConvertFrom-Json
    if ($timeoutResult.status -ne 'timed_out' -or $clock.Elapsed.TotalSeconds -gt 38) { throw 'Process timeout or crash-resistant status failed.' }
    $config = Get-Content (Join-Path (Split-Path $timeoutResult.worktree) 'opencode.worker.json') -Raw | ConvertFrom-Json
    foreach ($action in @('shell','execute','subagent')) {
        if (@($config.permissions | Where-Object { $_.action -eq $action -and $_.effect -eq 'deny' }).Count -ne 1) { throw "Missing deny permission: $action" }
    }
    Write-Output 'worker scope rejection, timeout status, and permission policy: passed'
}
finally { $env:PATH = $oldPath; Remove-Item Env:FAKE_MODE -ErrorAction SilentlyContinue; Remove-Item Function:docker -ErrorAction SilentlyContinue }
