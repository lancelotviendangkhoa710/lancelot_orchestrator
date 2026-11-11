[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $TargetRepo
)

$ErrorActionPreference = 'Stop'
$sourceRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$targetRoot = (Resolve-Path -LiteralPath $TargetRepo).Path
$gitRoot = (& git -C $targetRoot rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $gitRoot) { throw "Target must be inside a Git repository: $TargetRepo" }
$targetRoot = (Resolve-Path -LiteralPath $gitRoot.Trim()).Path

$skillSource = Join-Path $sourceRoot '.agents\skills\master-worker'
$skillTarget = Join-Path $targetRoot '.agents\skills\master-worker'
$agentsPath = Join-Path $targetRoot 'AGENTS.md'
$begin = '<!-- KHOA_AGENT_BEGIN -->'
$end = '<!-- KHOA_AGENT_END -->'

if (Test-Path -LiteralPath $skillTarget) { throw "Skill directory already exists; refusing to overwrite: $skillTarget" }
$existing = if (Test-Path -LiteralPath $agentsPath) { Get-Content -LiteralPath $agentsPath -Raw -Encoding utf8 } else { '' }
if ($existing.Contains($begin) -or $existing.Contains($end)) { throw 'Khoa Agent managed section already exists or is incomplete. Review AGENTS.md before reinstalling.' }

$managedSection = @"
$begin
## Khoa Agent multi-agent default

- For requests involving subagents, workers, delegation, or parallel work, use OpenCode subagents through the configured 9Router by default. Use Codex-native subagents only when the user explicitly requests them.
- Do not silently switch agent providers. If OpenCode or 9Router is unavailable, report the blocker and ask before changing providers.
- Follow the `$master-worker skill installed at `.agents/skills/master-worker/SKILL.md` for task planning, isolation, review, testing, and integration.
- Codex Master owns review, merge decisions, and final acceptance. Workers do not push, deploy, or delete uncommitted work.
$end
"@

if ($PSCmdlet.ShouldProcess($targetRoot, 'Install Khoa Agent project instructions and skill')) {
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $skillTarget) -Force
    Copy-Item -LiteralPath $skillSource -Destination $skillTarget -Recurse
    $separator = if ($existing -and -not $existing.EndsWith("`n")) { "`r`n`r`n" } else { '' }
    Set-Content -LiteralPath $agentsPath -Value ($existing + $separator + $managedSection) -Encoding utf8
    Write-Output "Installed Codex skill: $skillTarget"
    Write-Output "Updated project guidance: $agentsPath"
    Write-Output "Open Codex from $targetRoot or start a new session there so it loads AGENTS.md and the skill."
    Write-Output "OpenCode worker runs use the package config: $(Join-Path $sourceRoot 'opencode.jsonc')"
}



