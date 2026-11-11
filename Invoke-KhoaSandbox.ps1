[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $WorktreePath,
    [Parameter(Mandatory)][string[]] $Command,
    [string] $Image = 'debian:12.9-slim',
    [ValidateRange(1, 3600)][int] $TimeoutSeconds = 300,
    [ValidateRange(128, 32768)][int] $MemoryMiB = 2048,
    [ValidateRange(0.25, 16)][double] $Cpus = 2,
    [ValidateRange(32, 4096)][int] $PidsLimit = 256,
    [string] $IsolatedNetwork,
    [string] $ContainerName,
    [string[]] $Environment = @(),
    [hashtable[]] $ReadOnlyMounts = @(),
    [string[]] $PassEnvironment = @(),
    [string] $RedactSecret,
    [switch] $PreflightOnly
)

$ErrorActionPreference = 'Stop'

function Quote-DockerArgument([string] $Value) {
    if ($Value -match '[\r\n\x00]') { throw 'Command arguments cannot contain newlines or NUL characters.' }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}
function Invoke-Docker([string[]] $Arguments) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $docker.Source
    $start.Arguments = (($Arguments | ForEach-Object { Quote-DockerArgument ([string]$_) }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Could not start Docker CLI.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode=$process.ExitCode; StdOut=$stdoutTask.Result; StdErr=$stderrTask.Result }
}
function Drain-Output([ref] $ReadTask, [ref] $Done, [Diagnostics.Process] $SourceProcess, [string] $Stream) {
    while ($ReadTask.Value -and $ReadTask.Value.IsCompleted) {
        $line = $ReadTask.Value.GetAwaiter().GetResult()
        if ($null -eq $line) { $Done.Value = $true; $ReadTask.Value = $null; break }
        if ($script:RedactSecret) { $line = $line.Replace($script:RedactSecret,'[REDACTED]') }
        $line = $line -replace '(?i)(NINEROUTER_API_KEY\s*[=:]\s*)[^\s"\\]+','$1[REDACTED]'
        [void]$script:outputBuffer.AppendLine($line)
        if ($script:outputBuffer.Length -gt 2097152) { $script:outputBuffer.Remove(0,$script:outputBuffer.Length - 2097152) | Out-Null }
        if ($Stream -eq 'stdout') { $ReadTask.Value = $SourceProcess.StandardOutput.ReadLineAsync() }
        else { $ReadTask.Value = $SourceProcess.StandardError.ReadLineAsync() }
    }
}

if (-not $Command -or $Command.Count -eq 0 -or [string]::IsNullOrWhiteSpace($Command[0])) { throw 'Provide a command to run in the sandbox.' }
if ($Image -match '(^|:)latest$' -or $Image -notmatch '(@sha256:[0-9a-fA-F]{64}$|:[A-Za-z0-9._-]+$)') { throw 'Image must use an explicit version tag or immutable sha256 digest; latest is not allowed.' }
# The runner never accepts or forwards environment values. Reject common credential-shaped arguments as a guardrail.
foreach ($arg in $Command) {
    if ($arg -match '(?i)(api[_-]?key|access[_-]?token|password|secret)\s*[=:]|\bsk-[A-Za-z0-9_-]{16,}|^--?(api[-_]?key|access[-_]?token|password|secret)$') { throw 'Credential-like command argument rejected. Provide credentials through a separate, reviewed runtime integration.' }
}
$worktree = (Resolve-Path -LiteralPath $WorktreePath).Path
if (-not (Test-Path -LiteralPath $worktree -PathType Container)) { throw 'WorktreePath must be an existing directory.' }
$mountSource = $worktree -replace '\\','/'
if ($mountSource.Contains(',')) { throw 'Worktree paths containing commas cannot be mounted safely by this runner.' }
$docker = Get-Command docker -ErrorAction SilentlyContinue
if (-not $docker) { throw 'Docker CLI is unavailable; sandbox launch is blocked.' }
$imageCheck = Invoke-Docker @('image','inspect','--format','{{.Id}}',$Image)
if ($imageCheck.ExitCode -ne 0 -or -not $imageCheck.StdOut) { throw "Pinned sandbox image is not present locally: $Image. Pull it explicitly, then retry." }

foreach ($pair in $Environment) {
    if ($pair -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$' -or $Matches[1] -match '(?i)(key|token|secret|password|credential)') { throw 'Sandbox environment accepts non-secret variables only.' }
}
foreach ($name in $PassEnvironment) {
    if ($name -ne 'NINEROUTER_API_KEY') { throw "PassEnvironment only permits NINEROUTER_API_KEY; rejected '$name'." }
    if (-not (Test-Path "Env:$name")) { throw "Required inherited environment variable is absent: $name" }
}
$validatedMounts = @()
foreach ($mount in $ReadOnlyMounts) {
    if (-not $mount.ContainsKey('Source') -or -not $mount.ContainsKey('Target')) { throw 'Each read-only mount requires Source and Target.' }
    $source = (Resolve-Path -LiteralPath ([string]$mount.Source)).Path
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or $source.Contains(',')) { throw 'Read-only auxiliary mounts must be existing files with mount-safe paths.' }
    $target = [string]$mount.Target
    if ($target -notmatch '^/run/khoa/[A-Za-z0-9._/-]+$' -or $target -match '(^|/)\.\.?(/|$)') { throw 'Read-only mount targets must be safe files under /run/khoa.' }
    $validatedMounts += [pscustomobject]@{ Source=$source; Target=$target }
}

$networkArgs = @('--network','none')
if ($IsolatedNetwork) {
    # A provider network must be explicitly named, internal, and pre-marked for this purpose.
    $networkResult = Invoke-Docker @('network','inspect',$IsolatedNetwork)
    if ($networkResult.ExitCode -ne 0 -or -not $networkResult.StdOut) { throw "Provider networking blocked: Docker network '$IsolatedNetwork' is unavailable." }
    $network = $networkResult.StdOut | ConvertFrom-Json
    if (-not $network.Internal -or $network.Labels.'khoa.sandbox.isolated' -ne 'true') {
        throw "Provider networking blocked: '$IsolatedNetwork' must be internal and labeled khoa.sandbox.isolated=true."
    }
    $networkArgs = @('--network', $IsolatedNetwork)
}

if ($PreflightOnly) {
    Write-Output 'Sandbox image and isolated network preflight passed.'
    return
}

if ($ContainerName) {
    if ($ContainerName -notmatch '^khoa-sandbox-[a-zA-Z0-9][a-zA-Z0-9_.-]{0,80}$') { throw 'ContainerName must use the khoa-sandbox- prefix and safe Docker name characters.' }
    $container = $ContainerName
} else { $container = 'khoa-sandbox-' + [guid]::NewGuid().ToString('N') }
$dockerArgs = @(
    'run','--pull=never','--log-driver','none','--detach','--name',$container,
    '--user','65532:65532','--read-only','--security-opt','no-new-privileges:true',
    '--cap-drop','ALL','--pids-limit',[string]$PidsLimit,
    '--memory',("${MemoryMiB}m"),'--cpus',[string]$Cpus,
    '--tmpfs','/tmp:rw,noexec,nosuid,nodev,size=64m,uid=65532,gid=65532',
    '--tmpfs','/home/opencode:rw,nosuid,nodev,size=256m,uid=65532,gid=65532',
    '--mount',("type=bind,source=$mountSource,target=/workspace"),
    '--workdir','/workspace'
) + $networkArgs
foreach ($mount in $validatedMounts) {
    $source = $mount.Source -replace '\\','/'
    if ($source.Contains(',')) { throw 'Read-only mount source contains a comma and cannot be represented safely.' }
    $dockerArgs += @('--mount',("type=bind,source=$source,target=$($mount.Target),readonly"))
}
foreach ($entry in $Environment) { $dockerArgs += @('--env',$entry) }
foreach ($name in $PassEnvironment) { $dockerArgs += @('--env',$name) }
$dockerArgs += @($Image) + $Command
$id = $null
$watch = [Diagnostics.Stopwatch]::StartNew()
$timedOut = $false
$exitCode = $null
$attach = $null
$script:RedactSecret = $RedactSecret
$script:outputBuffer = New-Object Text.StringBuilder
try {
    $runResult = Invoke-Docker $dockerArgs
    if ($runResult.ExitCode -ne 0 -or -not $runResult.StdOut) { throw 'Docker rejected the sandbox container configuration.' }
    $id = ($runResult.StdOut -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1).Trim()
    if (-not $id) { throw 'Docker did not return a container ID.' }
    $inspectResult = Invoke-Docker @('inspect',$id)
    if ($inspectResult.ExitCode -ne 0) { throw 'Could not inspect sandbox configuration.' }
    $actual = @($inspectResult.StdOut | ConvertFrom-Json)[0]
    $mounts = @($actual.Mounts)
    $expectedMounts = @([pscustomobject]@{ Source=($worktree -replace '\\','/'); Target='/workspace'; Writable=$true })
    $expectedMounts += @($validatedMounts | ForEach-Object { [pscustomobject]@{ Source=($_.Source -replace '\\','/'); Target=$_.Target; Writable=$false } })
    if ($mounts.Count -ne $expectedMounts.Count) { throw 'Sandbox mount policy verification failed: unexpected mount count.' }
    foreach ($expected in $expectedMounts) {
        $actualMount = @($mounts | Where-Object { $_.Destination -eq $expected.Target })
        if ($actualMount.Count -ne 1 -or $actualMount[0].Type -ne 'bind' -or [bool]$actualMount[0].RW -ne [bool]$expected.Writable -or (([string]$actualMount[0].Source) -replace '\\','/') -ne $expected.Source) { throw 'Sandbox mount policy verification failed.' }
    }
    if (-not $actual.HostConfig.ReadonlyRootfs -or $actual.Config.User -ne '65532:65532' -or @($actual.HostConfig.CapDrop) -notcontains 'ALL' -or @($actual.HostConfig.SecurityOpt) -notcontains 'no-new-privileges:true') { throw 'Sandbox privilege policy verification failed.' }
    if ($actual.HostConfig.NetworkMode -ne $(if ($IsolatedNetwork) { $IsolatedNetwork } else { 'none' })) { throw 'Sandbox network policy verification failed.' }
    if ($actual.HostConfig.Memory -lt ($MemoryMiB * 1MB) -or $actual.HostConfig.PidsLimit -ne $PidsLimit -or $actual.HostConfig.NanoCpus -lt ($Cpus * 1000000000)) { throw 'Sandbox resource limit verification failed.' }
    if ($actual.HostConfig.LogConfig.Type -ne 'none') { throw 'Sandbox log-driver policy verification failed.' }
    $attachStart = New-Object Diagnostics.ProcessStartInfo
    $attachStart.FileName = $docker.Source
    $attachStart.Arguments = ((@('attach','--no-stdin',$container) | ForEach-Object { Quote-DockerArgument $_ }) -join ' ')
    $attachStart.UseShellExecute = $false; $attachStart.CreateNoWindow = $true
    $attachStart.RedirectStandardOutput = $true; $attachStart.RedirectStandardError = $true
    $attach = New-Object Diagnostics.Process
    $attach.StartInfo = $attachStart
    if (-not $attach.Start()) { throw 'Could not attach to sandbox output stream.' }
    $stdoutRead = $attach.StandardOutput.ReadLineAsync()
    $stderrRead = $attach.StandardError.ReadLineAsync()
    $stdoutDone = $false; $stderrDone = $false
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Drain-Output ([ref]$stdoutRead) ([ref]$stdoutDone) $attach 'stdout'
        Drain-Output ([ref]$stderrRead) ([ref]$stderrDone) $attach 'stderr'
        $state = Invoke-Docker @('inspect','--format','{{.State.Running}}',$container)
        if ($state.ExitCode -ne 0) { throw 'Could not inspect sandbox container state.' }
        if ($state.StdOut.Trim() -eq 'false') {
            $code = Invoke-Docker @('wait',$container)
            if ($code.ExitCode -ne 0) { throw 'Could not collect sandbox exit status.' }
            $exitCode = [int]$code.StdOut.Trim()
            break
        }
        Start-Sleep -Milliseconds 250
    }
    if ($null -eq $exitCode) {
        $timedOut = $true
        $null = Invoke-Docker @('kill',$container)
        $exitCode = 124
    }
    $attach.WaitForExit()
    while (-not $stdoutDone -or -not $stderrDone) {
        Drain-Output ([ref]$stdoutRead) ([ref]$stdoutDone) $attach 'stdout'
        Drain-Output ([ref]$stderrRead) ([ref]$stderrDone) $attach 'stderr'
        if (-not $stdoutDone -or -not $stderrDone) { Start-Sleep -Milliseconds 20 }
    }
    $actualMountReport = @($mounts | ForEach-Object { [pscustomobject]@{ Type=$_.Type; Source=$_.Source; Target=$_.Destination; Writable=[bool]$_.RW } })
    return [pscustomobject]@{
        exit_code=$exitCode
        status=if($timedOut){'timed_out'}elseif($exitCode -eq 0){'completed'}else{'failed'}
        output=$script:outputBuffer.ToString()
        container_id=$id
        mounts=$actualMountReport
        readonly_rootfs=[bool]$actual.HostConfig.ReadonlyRootfs
        user=$actual.Config.User
        network=$actual.HostConfig.NetworkMode
        log_driver=$actual.HostConfig.LogConfig.Type
        cap_drop=@($actual.HostConfig.CapDrop)
        security_options=@($actual.HostConfig.SecurityOpt)
        memory_bytes=$actual.HostConfig.Memory
        nano_cpus=$actual.HostConfig.NanoCpus
        pids_limit=$actual.HostConfig.PidsLimit
        tmpfs=$actual.HostConfig.Tmpfs
    }
}
finally {
    $watch.Stop()
    if ($attach -and -not $attach.HasExited) { $attach.Kill(); $attach.WaitForExit() }
    if ($id) { $null = Invoke-Docker @('rm','--force',$container) }
    $script:RedactSecret = $null
    $script:outputBuffer = $null
}
