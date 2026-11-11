$ErrorActionPreference = 'Stop'
$sandboxScript = Join-Path $PSScriptRoot '..\Invoke-KhoaSandbox.ps1'
$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) { throw 'Docker boundary test blocked: Docker CLI is not installed.' }
$engineVersion = & $docker.Source version --format '{{.Server.Version}}'
if ($LASTEXITCODE -ne 0) { throw 'Docker boundary test blocked: Docker daemon is unavailable.' }
$null = & $docker.Source pull busybox:1.36.1
if ($LASTEXITCODE -ne 0) { throw 'Docker boundary test blocked: pinned BusyBox fixture image could not be fetched.' }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('khoa-sandbox-test-' + [guid]::NewGuid().ToString('N'))
$main = Join-Path $scratch 'main-repo'
$sibling = Join-Path $scratch 'sibling'
$homeDir = Join-Path $scratch 'home'
$worktree = Join-Path $scratch 'worktree'
New-Item -ItemType Directory -Path $main,$sibling,$homeDir,$worktree -Force | Out-Null
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) { & chmod 0777 $worktree; if ($LASTEXITCODE -ne 0) { throw 'Could not prepare isolated worktree fixture permissions.' } }
Set-Content (Join-Path $main 'marker.txt') 'main-marker'
Set-Content (Join-Path $sibling 'marker.txt') 'sibling-marker'
Set-Content (Join-Path $homeDir 'marker.txt') 'home-marker'
$inputFile = Join-Path $scratch 'readonly-input.txt'
[IO.File]::WriteAllText($inputFile,'readonly-fixture',[Text.Encoding]::ASCII)
$name = 'khoa-sandbox-test-' + [guid]::NewGuid().ToString('N').Substring(0,10)
$timeoutName = 'khoa-sandbox-test-' + [guid]::NewGuid().ToString('N').Substring(0,10)
$priorKeyExists = Test-Path Env:NINEROUTER_API_KEY
$priorKey = $env:NINEROUTER_API_KEY

try {
    $env:NINEROUTER_API_KEY = 'fixture-only'
    $probe = @'
set -eux
test "$(id -u)" = '65532'
! (touch /etc/khoa-sandbox-write-probe 2>/dev/null)
test "$(cat /run/khoa/test-input.txt)" = 'readonly-fixture'
if touch /run/khoa/test-input.txt 2>/dev/null; then exit 88; else echo read-only-input-write-blocked; fi
test "$NINEROUTER_API_KEY" = 'fixture-only'
test ! -e /boundary/main/marker.txt
test ! -e /boundary/sibling/marker.txt
test ! -e /boundary/home/marker.txt
! (cat /boundary/main/marker.txt >/dev/null 2>&1)
! (cat /boundary/sibling/marker.txt >/dev/null 2>&1)
! (cat /boundary/home/marker.txt >/dev/null 2>&1)
! (touch /boundary/main/created.txt 2>/dev/null)
! (touch /boundary/sibling/created.txt 2>/dev/null)
! (touch /boundary/home/created.txt 2>/dev/null)
printf '%s\n' 'sandbox-write-ok' > /workspace/result.txt
test "$(cat /workspace/result.txt)" = 'sandbox-write-ok'
printf '%s\n' "$NINEROUTER_API_KEY"
'@
    $probe = ($probe -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join '; '
    $run = & $sandboxScript -WorktreePath $worktree -Image 'busybox:1.36.1' -TimeoutSeconds 60 -ContainerName $name -Command @('sh','-c',($probe + '; sleep 2')) -ReadOnlyMounts @(@{Source=$inputFile;Target='/run/khoa/test-input.txt'}) -Environment @('BOUNDARY_CONFIG=/run/khoa/test-input.txt') -PassEnvironment @('NINEROUTER_API_KEY') -RedactSecret 'fixture-only'
    if ($run.status -ne 'completed' -or $run.exit_code -ne 0) { throw "Sandbox probe failed: $($run.status), exit $($run.exit_code): $($run.output)" }
    if (@($run.mounts).Count -ne 2 -or @($run.mounts | Where-Object { $_.Target -eq '/workspace' -and $_.Writable }).Count -ne 1 -or @($run.mounts | Where-Object { $_.Target -eq '/run/khoa/test-input.txt' -and -not $_.Writable }).Count -ne 1) { throw 'Docker inspect did not show exactly one writable worktree and the read-only input mount.' }
    if (-not $run.readonly_rootfs -or $run.user -ne '65532:65532' -or $run.network -ne 'none' -or $run.log_driver -ne 'none' -or @($run.cap_drop) -notcontains 'ALL') { throw 'Docker inspect runtime isolation configuration failed.' }
    if ($run.mounts.Source -match '(?i)docker\.sock|home|main-repo|sibling') { throw 'Docker inspect exposed an unapproved mount.' }
    if ((Get-Content (Join-Path $worktree 'result.txt') -Raw).Trim() -ne 'sandbox-write-ok') { throw 'Sandbox could not write to its worktree mount.' }
    if ($run.output -match 'fixture-only') { throw 'Sandbox output redaction failed.' }
    foreach ($path in @((Join-Path $main 'created.txt'),(Join-Path $sibling 'created.txt'),(Join-Path $homeDir 'created.txt'))) { if (Test-Path $path) { throw "Sandbox wrote outside worktree: $path" } }
    if ((Get-Content (Join-Path $main 'marker.txt') -Raw).Trim() -ne 'main-marker' -or (Get-Content (Join-Path $sibling 'marker.txt') -Raw).Trim() -ne 'sibling-marker' -or (Get-Content (Join-Path $homeDir 'marker.txt') -Raw).Trim() -ne 'home-marker') { throw 'Fixture files changed unexpectedly.' }
    if ((& $docker.Source ps --all --filter "name=^/$name$" --format '{{.Names}}') -contains $name) { throw 'Sandbox container was not cleaned up.' }

    $timeout = & $sandboxScript -WorktreePath $worktree -Image 'busybox:1.36.1' -TimeoutSeconds 2 -ContainerName $timeoutName -Command @('sh','-c','sleep 30')
    if ($timeout.status -ne 'timed_out' -or $timeout.exit_code -ne 124) { throw 'Sandbox timeout did not terminate the long-running command.' }
    if ((& $docker.Source ps --all --filter "name=^/$timeoutName$" --format '{{.Names}}') -contains $timeoutName) { throw 'Timed-out sandbox container was not cleaned up.' }
    Write-Output "sandbox boundary, read-only inputs, credential passthrough, redaction, and timeout passed on Docker Engine $engineVersion"
}
finally {
    $oldPreference = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $docker.Source rm --force $name *> $null; & $docker.Source rm --force $timeoutName *> $null }
    finally { $ErrorActionPreference = $oldPreference }
    if ($priorKeyExists) { $env:NINEROUTER_API_KEY = $priorKey } else { Remove-Item Env:NINEROUTER_API_KEY -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
