[CmdletBinding()]
param(
    [string] $RepoPath = (Get-Location).Path,

    [string] $ComposeFile,

    [string[]] $Services = @(),

    [string] $ReadyUrl,

    [string] $ExpectedText,

    [ValidateRange(30, 3600)]
    [int] $TimeoutSeconds = 300,

    [string] $RunId = ([guid]::NewGuid().ToString('N').Substring(0, 10))
)

$ErrorActionPreference = 'Stop'
function Test-PathUnderRoot([string] $Path, [string] $Root) {
    $relative = [IO.Path]::GetRelativePath($Root, [IO.Path]::GetFullPath($Path))
    return (-not [IO.Path]::IsPathRooted($relative)) -and $relative -ne '..' -and -not $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::Ordinal)
}

$repoRoot = (Resolve-Path -LiteralPath $RepoPath).Path
if ($ComposeFile) {
    $candidate = if ([IO.Path]::IsPathRooted($ComposeFile)) { $ComposeFile } else { Join-Path $repoRoot $ComposeFile }
    $composePath = (Resolve-Path -LiteralPath $candidate).Path
}
else {
    $candidates = @('compose.yaml','compose.yml','docker-compose.yaml','docker-compose.yml') | ForEach-Object { Join-Path $repoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }
    if ($candidates.Count -ne 1) { throw "Expected exactly one standard Compose file at repo root; found $($candidates.Count). Pass -ComposeFile explicitly." }
    $composePath = (Resolve-Path -LiteralPath $candidates[0]).Path
}
$resolvedRepoRoot = (Resolve-Path -LiteralPath $repoRoot).Path
if (-not (Test-PathUnderRoot $composePath $resolvedRepoRoot)) { throw 'Compose file must be inside RepoPath.' }
$projectDir = Split-Path -Parent $composePath
$projectName = "khoa-$($RunId.ToLowerInvariant())"
$logDir = Join-Path $PSScriptRoot "runs\docker-$RunId"
$null = New-Item -ItemType Directory -Path $logDir -Force
$composeArgs = @('--project-name', $projectName, '-f', $composePath)
$stdoutLog = Join-Path $logDir 'compose.stdout.log'
$stderrLog = Join-Path $logDir 'compose.stderr.log'
$statusLog = Join-Path $logDir 'compose.status.txt'
$serviceListPath = Join-Path $logDir 'services.json'

Push-Location $projectDir
try {
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Docker Engine is not reachable. Start Docker Desktop and retry.' }

    & docker compose @composeArgs config --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Compose configuration is invalid.' }

    $configJson = & docker compose @composeArgs config --format json
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect rendered Compose configuration.' }
    $composeConfig = ($configJson -join "`n") | ConvertFrom-Json
    foreach ($volume in @($composeConfig.volumes.PSObject.Properties | ForEach-Object Value)) {
        if ($volume.external) { throw 'External Docker volumes are blocked by default. Use an explicitly approved isolated test volume.' }
    }
    foreach ($network in @($composeConfig.networks.PSObject.Properties | ForEach-Object Value)) {
        if ($network.external) { throw 'External Docker networks are blocked by default. Use an explicitly approved isolated test network.' }
    }
    foreach ($service in @($composeConfig.services.PSObject.Properties | ForEach-Object Value)) {
        foreach ($mount in @($service.volumes | Where-Object { $_.type -eq 'bind' })) {
            $sourcePath = [IO.Path]::GetFullPath([string]$mount.source)
            if (-not (Test-PathUnderRoot $sourcePath $resolvedRepoRoot)) {
                throw "Bind mount source is outside the worker repo and is blocked: $sourcePath"
            }
        }
    }

    $allServices = @($composeConfig.services.PSObject.Properties.Name)
    $selected = if ($Services.Count) { $Services } else { $allServices }
    $unknown = @($selected | Where-Object { $_ -notin $allServices })
    if ($unknown.Count) { throw "Unknown Compose service(s): $($unknown -join ', ')" }
    $selected | ConvertTo-Json | Set-Content -LiteralPath $serviceListPath -Encoding utf8

    $upArgs = @('compose') + $composeArgs + @('up', '--build', '--detach', '--wait', '--wait-timeout', "$TimeoutSeconds") + $selected
    & docker @upArgs 1> $stdoutLog 2> $stderrLog
    if ($LASTEXITCODE -ne 0) {
        & docker compose @composeArgs ps --all | Set-Content -LiteralPath $statusLog -Encoding utf8
        & docker compose @composeArgs logs --no-color --tail 300 | Set-Content -LiteralPath (Join-Path $logDir 'compose.failure.log') -Encoding utf8
        throw "Compose build/start/readiness failed. Review logs under $logDir (port conflicts and migration/database errors are commonly visible there)."
    }

    if ($ReadyUrl) {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $ready = $false
        $lastStatus = 'no response yet'
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $response = Invoke-WebRequest -Uri $ReadyUrl -TimeoutSec 5 -UseBasicParsing
                $bodyText = [string]$response.Content
                $lastStatus = "HTTP $([int]$response.StatusCode)"
                if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400 -and (-not $ExpectedText -or $bodyText.Contains($ExpectedText))) {
                    $ready = $true
                    break
                }
            }
            catch { $lastStatus = $_.Exception.Message }
            Start-Sleep -Milliseconds 750
        }
        if (-not $ready) {
            & docker compose @composeArgs ps --all | Set-Content -LiteralPath $statusLog -Encoding utf8
            & docker compose @composeArgs logs --no-color --tail 300 | Set-Content -LiteralPath (Join-Path $logDir 'compose.readiness-failure.log') -Encoding utf8
            throw "Application did not become ready at $ReadyUrl within ${TimeoutSeconds}s ($lastStatus). Logs: $logDir"
        }
    }

    & docker compose @composeArgs ps --all | Set-Content -LiteralPath $statusLog -Encoding utf8
    Write-Output "Compose project '$projectName' is ready. Services: $($selected -join ', ')"
    Write-Output "Evidence: $logDir"
    Write-Output 'Resources were left running. This script never runs down, rm, prune, or volume deletion.'
}
finally { Pop-Location }
