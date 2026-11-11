[CmdletBinding()]
param([string] $RunsRoot = (Join-Path $PSScriptRoot 'runs'))

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $RunsRoot -PathType Container)) { return }
$docker = Get-Command docker -ErrorAction SilentlyContinue
foreach ($file in @(Get-ChildItem -LiteralPath $RunsRoot -Filter result.json -Recurse -File)) {
    $run = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json
    $treeExists = $run.worktree -and (Test-Path -LiteralPath ([string]$run.worktree) -PathType Container)
    $head = $null
    if ($treeExists) {
        $headResult = & git -C $run.worktree rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0) { $head = ($headResult | Select-Object -First 1).Trim() }
    }
    $containerState = 'unknown'
    if ($run.sandbox_container_name) {
        if ([string]$run.sandbox_container_name -notmatch '^khoa-sandbox-[A-Za-z0-9-]+$') { $containerState = 'invalid_name' }
        elseif ($docker) {
            $oldPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $running = & docker inspect --format '{{.State.Running}}' $run.sandbox_container_name 2>$null }
            finally { $ErrorActionPreference = $oldPreference }
            $containerState = if ($LASTEXITCODE -ne 0) { 'missing' } elseif (($running | Select-Object -First 1).Trim() -eq 'true') { 'running' } else { 'stopped' }
        }
    }
    $assessment = 'recorded'
    if ($run.status -in @('starting','running')) {
        $assessment = if ($containerState -eq 'running') { 'still_running' } else { 'needs_recovery' }
    }
    elseif ($run.status -eq 'completed' -and $run.commit_sha -and $head -ne $run.commit_sha) { $assessment = 'commit_mismatch' }
    elseif (-not $treeExists) { $assessment = 'worktree_missing' }
    [pscustomobject]@{
        run_id = $run.run_id
        recorded_status = $run.status
        assessment = $assessment
        worktree_exists = [bool]$treeExists
        head = $head
        commit_sha = $run.commit_sha
        container_name = $run.sandbox_container_name
        container_state = $containerState
        result_path = $file.FullName
    }
}
