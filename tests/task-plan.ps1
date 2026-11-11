$ErrorActionPreference = 'Stop'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('khoa-plan-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$planner = Join-Path $PSScriptRoot '..\Get-KhoaTaskPlan.ps1'
function New-Contract([string]$Id, [string[]]$Paths, [string[]]$Dependencies, [string[]]$Locks) {
    $path = Join-Path $scratch "$Id.json"
    [ordered]@{ task_id=$Id; allowed_paths=$Paths; dependencies=$Dependencies; resource_locks=$Locks } |
        ConvertTo-Json | Set-Content -LiteralPath $path
    return $path
}
$a = New-Contract 'a' @('src/a.ps1') @() @('db')
$b = New-Contract 'b' @('src/b.ps1') @() @('db')
$c = New-Contract 'c' @('docs/c.md') @('a') @()
$d = New-Contract 'd' @('src/d.ps1') @() @()
$plan = (& $planner -ContractPaths @($a,$b,$c,$d)) | ConvertFrom-Json
if ($plan.task_count -ne 4 -or @($plan.waves).Count -ne 2) { throw 'Plan shape is wrong.' }
if ($plan.waves[0] -notcontains 'a' -or $plan.waves[0] -contains 'b' -or $plan.waves[0] -contains 'c' -or $plan.waves[1] -notcontains 'b' -or $plan.waves[1] -notcontains 'c') { throw 'Resource lock or dependency order was ignored.' }

$x = New-Contract 'x' @('src/x.ps1') @('y') @()
$y = New-Contract 'y' @('src/y.ps1') @('x') @()
try { & $planner -ContractPaths @($x,$y) *> $null; throw 'Expected cycle rejection.' }
catch { if ($_.Exception.Message -notmatch 'cycle') { throw } }
$overlapA = New-Contract 'overlap_a' @('src/shared.ps1') @() @()
$overlapB = New-Contract 'overlap_b' @('src/shared.ps1') @() @()
$overlapPlan = (& $planner -ContractPaths @($overlapA,$overlapB)) | ConvertFrom-Json
if (@($overlapPlan.waves).Count -ne 2) { throw 'Overlapping write scopes were scheduled together.' }
Write-Output 'task dependency, resource lock, path overlap, and cycle planning: passed'
