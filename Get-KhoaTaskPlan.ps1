[CmdletBinding()]
param([Parameter(Mandatory)][string[]] $ContractPaths)

$ErrorActionPreference = 'Stop'
if ($ContractPaths.Count -eq 0) { throw 'At least one task contract is required.' }
$tasks = @{}
foreach ($path in $ContractPaths) {
    $contract = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
    $id = [string]$contract.task_id
    if ($id -notmatch '^[A-Za-z0-9_-]+$' -or $tasks.ContainsKey($id)) { throw "Invalid or duplicate task ID: $id" }
    if (-not $contract.allowed_paths -or @($contract.allowed_paths).Count -eq 0) { throw "Task $id needs allowed_paths." }
    foreach ($field in @('dependencies','resource_locks')) {
        if ($contract.PSObject.Properties[$field] -and ($contract.$field -isnot [array] -or @($contract.$field | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)) { throw "Task $id has invalid $field." }
    }
    foreach ($scope in @($contract.allowed_paths)) {
        if ($scope -isnot [string] -or [string]::IsNullOrWhiteSpace($scope) -or [IO.Path]::IsPathRooted($scope) -or $scope -match '(^|[\\/])\.\.([\\/]|$)') { throw "Unsafe path scope in task ${id}: $scope" }
    }
    $tasks[$id] = [pscustomobject]@{
        task_id = $id
        contract_path = (Resolve-Path -LiteralPath $path).Path
        dependencies = @($contract.dependencies | Where-Object { $_ })
        allowed_paths = @($contract.allowed_paths)
        resource_locks = @($contract.resource_locks | Where-Object { $_ })
    }
}
foreach ($task in $tasks.Values) {
    foreach ($dependency in $task.dependencies) {
        if (-not $tasks.ContainsKey([string]$dependency)) { throw "Task $($task.task_id) has unknown dependency $dependency." }
        if ($dependency -eq $task.task_id) { throw "Task $($task.task_id) depends on itself." }
    }
}

function Test-TaskConflict($Left, $Right) {
    if (@(Compare-Object $Left.resource_locks $Right.resource_locks -IncludeEqual -ExcludeDifferent).Count -gt 0) { return $true }
    foreach ($leftPath in $Left.allowed_paths) {
        foreach ($rightPath in $Right.allowed_paths) {
            if ($leftPath -eq $rightPath -or $leftPath -match '[*?\[]' -or $rightPath -match '[*?\[]') { return $true }
            $leftNormalized = $leftPath.Replace('\','/')
            $rightNormalized = $rightPath.Replace('\','/')
            $leftPrefix = $leftNormalized.TrimEnd('/') + '/'
            $rightPrefix = $rightNormalized.TrimEnd('/') + '/'
            if ($leftNormalized.StartsWith($rightPrefix, [StringComparison]::OrdinalIgnoreCase) -or $rightNormalized.StartsWith($leftPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

$done = @{}
$waves = @()
while ($done.Count -lt $tasks.Count) {
    $ready = @($tasks.Values | Where-Object {
        -not $done.ContainsKey($_.task_id) -and @($_.dependencies | Where-Object { -not $done.ContainsKey([string]$_) }).Count -eq 0
    } | Sort-Object task_id)
    if ($ready.Count -eq 0) { throw 'Task dependency cycle detected.' }
    $wave = @()
    foreach ($task in $ready) {
        $conflict = $false
        foreach ($selected in $wave) { if (Test-TaskConflict $task $selected) { $conflict = $true; break } }
        if (-not $conflict -and $wave.Count -lt 2) { $wave += $task }
    }
    foreach ($task in $wave) { $done[$task.task_id] = $true }
    $waves += ,@($wave | ForEach-Object task_id)
}
[pscustomobject]@{ task_count=$tasks.Count; waves=$waves; tasks=@($tasks.Values | Sort-Object task_id) } | ConvertTo-Json -Depth 8
