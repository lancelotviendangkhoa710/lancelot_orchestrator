$ErrorActionPreference = 'Stop'
$proxyScript = Join-Path $PSScriptRoot '..\Invoke-KhoaRouterProxy.ps1'
$runId = 'test-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$workerName = "khoa-routerproxy-test-worker-$($runId.Substring(5))"
$workerImage = 'busybox:1.36.1@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662'
$proxy = $null
$workerCreated = $false

function Invoke-Docker([string[]] $Arguments) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& docker @Arguments 2>&1)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    [pscustomobject]@{ ExitCode=$code; StdOut=(($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine); StdErr='' }
}
function Assert-Docker([string[]] $Arguments, [string] $Failure) {
    $result = Invoke-Docker $Arguments
    if ($result.ExitCode -ne 0) { throw "$Failure $($result.StdErr.Trim()) $($result.StdOut.Trim())" }
    return $result
}

try {
    $safetyRunId = 'safe-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $unownedDir = Join-Path (Join-Path (Split-Path $proxyScript -Parent) 'runs') "router-proxy-$safetyRunId"
    $unownedFile = Join-Path $unownedDir 'keep.txt'
    $null = New-Item -ItemType Directory -Path $unownedDir -Force
    Set-Content -LiteralPath $unownedFile -Value 'unowned'
    $null = & $proxyScript -Action Stop -RunId $safetyRunId
    if (-not (Test-Path -LiteralPath $unownedFile)) { throw 'Stop removed an unowned run directory.' }
    Remove-Item -LiteralPath $unownedDir -Recurse -Force

    $proxy = & $proxyScript -Action Start -RunId $runId
    if ($proxy.network -ne "khoa-routerproxy-$runId" -or $proxy.endpoint -ne 'http://khoa-router-proxy:8080') { throw 'Proxy start metadata is invalid.' }
    $imageResult = Invoke-Docker @('image','inspect','--format','{{.Id}}',$workerImage)
    if ($imageResult.ExitCode -ne 0) { throw "Pinned BusyBox image is missing locally: $workerImage" }
    $networkInspect = Assert-Docker @('network','inspect',$proxy.network) 'Could not inspect proxy worker network.'
    $networkObject = @($networkInspect.StdOut | ConvertFrom-Json)[0]
    if (-not $networkObject.Internal -or $networkObject.Labels.'khoa.router-proxy.owner' -ne 'true' -or $networkObject.Labels.'khoa.router-proxy.run-id' -ne $runId -or $networkObject.Labels.'khoa.sandbox.isolated' -ne 'true') { throw 'Worker network is not an owned sandbox-compatible internal Docker network.' }
    $sandboxRunner = Join-Path $PSScriptRoot '..\Invoke-KhoaSandbox.ps1'
    $sandboxPreflight = @(& $sandboxRunner -WorktreePath (Split-Path $PSScriptRoot -Parent) -Command @('true') -Image $workerImage -IsolatedNetwork $proxy.network -PreflightOnly)
    if (($sandboxPreflight -join ' ') -notmatch 'preflight passed') { throw 'Invoke-KhoaSandbox did not accept the proxy worker network.' }

    $run = Assert-Docker @(
        'run','--detach','--pull=never','--name',$workerName,'--network',$proxy.network,
        '--add-host','host.docker.internal:host-gateway',
        '--read-only','--user','65532:65532','--security-opt','no-new-privileges:true','--cap-drop','ALL',
        '--pids-limit','32','--memory','64m','--cpus','0.50',$workerImage,'sleep','120'
    ) 'Could not start BusyBox test worker.'
    $workerCreated = $true
    $workerId = ($run.StdOut -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 1).Trim()
    $inspect = Assert-Docker @('inspect',$workerId) 'Could not inspect test worker.'
    $worker = @($inspect.StdOut | ConvertFrom-Json)[0]
    if ($worker.HostConfig.NetworkMode -ne $proxy.network -or $worker.HostConfig.Privileged -or -not $worker.HostConfig.ReadonlyRootfs -or @($worker.HostConfig.CapDrop) -notcontains 'ALL') { throw 'Test worker is missing the expected isolated container policy.' }
    $attached = @($worker.NetworkSettings.Networks.PSObject.Properties.Name)
    if ($attached.Count -ne 1 -or $attached[0] -ne $proxy.network) { throw 'Test worker is attached to an unexpected network.' }

    $proxyInspect = Assert-Docker @('inspect',$proxy.container) 'Could not inspect proxy container.'
    $proxyObject = @($proxyInspect.StdOut | ConvertFrom-Json)[0]
    if ($proxyObject.Config.Image -ne $proxy.image -or @($proxyObject.Mounts).Count -ne 1 -or $proxyObject.Mounts[0].Destination -ne '/etc/nginx/nginx.conf' -or $proxyObject.Mounts[0].RW) { throw 'Proxy live mount/image policy is invalid.' }
    if (-not $proxyObject.HostConfig.ReadonlyRootfs -or $proxyObject.Config.User -ne '101:101' -or @($proxyObject.HostConfig.CapDrop) -notcontains 'ALL' -or $proxyObject.HostConfig.Privileged -or $proxyObject.HostConfig.PortBindings.Count -gt 0 -or $proxyObject.HostConfig.PidsLimit -ne 32 -or $proxyObject.HostConfig.Memory -lt 64MB -or $proxyObject.HostConfig.NanoCpus -lt 500000000) { throw 'Proxy live resource/security policy is invalid.' }
    $proxyNetworks = @($proxyObject.NetworkSettings.Networks.PSObject.Properties.Name)
    if ($proxyNetworks.Count -ne 2 -or $proxyNetworks -notcontains 'bridge' -or $proxyNetworks -notcontains $proxy.network) { throw 'Proxy live network policy is invalid.' }

    $throughProxy = Assert-Docker @('exec',$workerName,'wget','-T','8','-qO','/dev/null','http://khoa-router-proxy:8080/v1/models') 'Worker could not reach host 9Router through the proxy.'
    $directHost = Invoke-Docker @('exec',$workerName,'wget','-T','2','-qO','/dev/null','http://host.docker.internal:20128/v1/models')
    if ($directHost.ExitCode -eq 0) { throw 'Worker reached host 9Router directly, bypassing the proxy.' }
    $directInternet = Invoke-Docker @('exec',$workerName,'wget','-T','2','-qO','/dev/null','http://1.1.1.1/')
    if ($directInternet.ExitCode -eq 0) { throw 'Worker reached the public internet directly.' }
    $otherPath = Invoke-Docker @('exec',$workerName,'wget','-T','3','-qO','/dev/null','http://khoa-router-proxy:8080/not-v1')
    if ($otherPath.ExitCode -eq 0) { throw 'Proxy accepted a path outside /v1/.' }
    Write-Output 'proxy /v1 request, direct-host denial, internet denial, path restriction and live inspect: passed'
}
finally {
    if ($workerCreated) { $null = Invoke-Docker @('rm','--force',$workerName) }
    if ($proxy) {
        $stopped = & $proxyScript -Action Stop -RunId $runId
        $proxyRunDir = Join-Path (Join-Path (Split-Path $proxyScript -Parent) 'runs') "router-proxy-$runId"
        if (-not $stopped.files_removed -or (Test-Path -LiteralPath $proxyRunDir)) { throw 'Router proxy test left generated config files behind.' }
    }
    $leftContainer = Invoke-Docker @('inspect',"khoa-routerproxy-$runId")
    $leftNetwork = Invoke-Docker @('network','inspect',"khoa-routerproxy-$runId")
    if ($leftContainer.ExitCode -eq 0 -or $leftNetwork.ExitCode -eq 0) { throw 'Router proxy test left an owned container or network behind.' }
    if ($workerCreated) {
        $leftWorker = Invoke-Docker @('inspect',$workerName)
        if ($leftWorker.ExitCode -eq 0) { throw 'Router proxy test left the BusyBox worker behind.' }
    }
}
