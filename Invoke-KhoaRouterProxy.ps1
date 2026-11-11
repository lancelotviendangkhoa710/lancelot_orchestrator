[CmdletBinding()]
param(
    [ValidateSet('Start','Stop')][string] $Action = 'Start',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,23}$')][string] $RunId
)

$ErrorActionPreference = 'Stop'
$image = 'nginx:1.27.4-alpine3.21@sha256:4ff102c5d78d254a6f0da062b3cf39eaf07f01eec0927fd21e219d0af8bc0591'
if ($Action -eq 'Stop' -and -not $RunId) { throw 'Provide the -RunId returned by the proxy start action.' }
if (-not $RunId) { $RunId = [guid]::NewGuid().ToString('N').Substring(0,12) }
$container = "khoa-routerproxy-$RunId"
$network = "khoa-routerproxy-$RunId"
$runDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "runs\router-proxy-$RunId"))
$configPath = Join-Path $runDir 'nginx.conf'
$markerPath = Join-Path $runDir 'router-proxy.owner'
$configLabel = 'khoa.router-proxy.owner'

function Test-OwnedRunDirectory {
    $runsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'runs')).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not $runDir.StartsWith($runsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $false }
    return ((Get-Content -LiteralPath $markerPath -Raw -ErrorAction SilentlyContinue).Trim() -eq $RunId)
}

function Invoke-Docker([string[]] $Arguments) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& docker @Arguments 2>&1)
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    return [pscustomobject]@{ ExitCode=$code; StdOut=$text; StdErr='' }
}
function Assert-Docker([string[]] $Arguments, [string] $Failure) {
    $result = Invoke-Docker $Arguments
    if ($result.ExitCode -ne 0) { throw "$Failure $($result.StdErr.Trim()) $($result.StdOut.Trim())" }
    return $result
}

$docker = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue
if (-not $docker) { throw 'Docker CLI is unavailable.' }
$info = Invoke-Docker @('info')
if ($info.ExitCode -ne 0) { throw 'Docker Engine is not reachable.' }

if ($Action -eq 'Stop') {
    $containerInfo = Invoke-Docker @('inspect',$container)
    if ($containerInfo.ExitCode -eq 0) {
        $item = @($containerInfo.StdOut | ConvertFrom-Json)[0]
        if ($item.Config.Labels.$configLabel -ne 'true' -or $item.Config.Labels.'khoa.router-proxy.run-id' -ne $RunId) { throw 'Refusing to remove a container not owned by this proxy run.' }
        $null = Assert-Docker @('rm','--force',$container) 'Could not remove owned proxy container.'
    }
    $networkInfo = Invoke-Docker @('network','inspect',$network)
    if ($networkInfo.ExitCode -eq 0) {
        $item = @($networkInfo.StdOut | ConvertFrom-Json)[0]
        if (-not $item.Internal -or $item.Labels.$configLabel -ne 'true' -or $item.Labels.'khoa.router-proxy.run-id' -ne $RunId) { throw 'Refusing to remove a network not owned by this proxy run.' }
        $null = Assert-Docker @('network','rm',$network) 'Could not remove owned proxy network.'
    }
    $filesRemoved = $false
    if (Test-Path -LiteralPath $runDir) {
        if (Test-OwnedRunDirectory) {
            Remove-Item -LiteralPath $runDir -Recurse -Force
            $filesRemoved = $true
            if (Test-Path -LiteralPath $runDir) { throw 'Owned proxy files were not fully removed.' }
        }
    }
    [pscustomobject]@{ action='stopped'; run_id=$RunId; container=$container; network=$network; files_removed=$filesRemoved }
    return
}

$imageResult = Invoke-Docker @('image','inspect','--format','{{.Id}}',$image)
if ($imageResult.ExitCode -ne 0 -or -not $imageResult.StdOut.Trim()) { throw "Pinned proxy image is not present locally: $image. Pull it explicitly before starting the proxy." }
foreach ($name in @($container,$network)) {
    $existing = if ($name -eq $container) { Invoke-Docker @('inspect',$name) } else { Invoke-Docker @('network','inspect',$name) }
    if ($existing.ExitCode -eq 0) { throw "Refusing to reuse existing Docker resource '$name'." }
}
if (Test-Path -LiteralPath $runDir) { throw "Refusing to reuse existing proxy run directory '$runDir'." }
$null = New-Item -ItemType Directory -Path $runDir -Force
Set-Content -LiteralPath $markerPath -Value $RunId -Encoding ascii
if ($configPath.Contains(',')) { throw 'The generated config path cannot contain commas.' }
$nginxConfig = @'
worker_processes 1;
pid /tmp/nginx.pid;
error_log stderr notice;
events { worker_connections 128; }
http {
    access_log off;
    client_body_temp_path /tmp/client_temp;
    proxy_temp_path /tmp/proxy_temp;
    fastcgi_temp_path /tmp/fastcgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;
    scgi_temp_path /tmp/scgi_temp;
    client_max_body_size 32m;
    server {
        listen 8080;
        server_name _;
        location ^~ /v1/ {
            proxy_pass http://host.docker.internal:20128;
            proxy_http_version 1.1;
            proxy_set_header Host host.docker.internal:20128;
            proxy_set_header Connection "";
            proxy_connect_timeout 5s;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
        }
        location / { return 404; }
    }
}
'@
Set-Content -LiteralPath $configPath -Value $nginxConfig -Encoding ascii
$sourcePath = $configPath.Replace('\','/')
try {
    $null = Assert-Docker @('network','create','--driver','bridge','--internal','--label','khoa.sandbox.isolated=true','--label',"$configLabel=true",'--label',"khoa.router-proxy.run-id=$RunId",$network) 'Could not create internal proxy network.'
    $dockerArgs = @(
        'run','--detach','--pull=never','--name',$container,
        '--label',"$configLabel=true",'--label',"khoa.router-proxy.run-id=$RunId",
        '--network','bridge','--add-host','host.docker.internal:host-gateway',
        '--mount',("type=bind,source=$sourcePath,target=/etc/nginx/nginx.conf,readonly"),
        '--tmpfs','/tmp:rw,noexec,nosuid,size=16m',
        '--read-only','--user','101:101','--security-opt','no-new-privileges:true',
        '--cap-drop','ALL','--pids-limit','32','--memory','64m','--cpus','0.50',
        '--entrypoint','nginx',$image,'-g','daemon off;','-c','/etc/nginx/nginx.conf'
    )
    $null = Assert-Docker $dockerArgs 'Could not start pinned proxy container.'
    $null = Assert-Docker @('network','connect','--alias','khoa-router-proxy',$network,$container) 'Could not attach proxy to worker network.'
    $null = Assert-Docker @('exec',$container,'nginx','-t','-c','/etc/nginx/nginx.conf') 'Nginx rejected generated proxy configuration.'
    $ready = $false
    for ($i=0; $i -lt 20; $i++) {
        $state = Invoke-Docker @('inspect','--format','{{.State.Running}}',$container)
        if ($state.ExitCode -ne 0 -or $state.StdOut.Trim() -ne 'true') { throw 'Proxy container exited during startup.' }
        $probe = Invoke-Docker @('exec',$container,'wget','-q','-O','/dev/null','http://host.docker.internal:20128/v1/models')
        if ($probe.ExitCode -eq 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw 'Host 9Router did not respond through the proxy container.' }

    $networkCheck = Invoke-Docker @('network','inspect',$network)
    $networkObject = @($networkCheck.StdOut | ConvertFrom-Json)[0]
    if (-not $networkObject.Internal -or $networkObject.Labels.$configLabel -ne 'true' -or $networkObject.Labels.'khoa.sandbox.isolated' -ne 'true') { throw 'Proxy worker network isolation verification failed.' }
    $containerCheck = Invoke-Docker @('inspect',$container)
    $proxy = @($containerCheck.StdOut | ConvertFrom-Json)[0]
    $mounts = @($proxy.Mounts)
    if ($proxy.Config.Image -ne $image -or $mounts.Count -ne 1 -or $mounts[0].Type -ne 'bind' -or $mounts[0].Destination -ne '/etc/nginx/nginx.conf' -or $mounts[0].RW -or $mounts[0].Source.Replace('\','/') -ne $sourcePath) { throw 'Proxy image or mount verification failed.' }
    if (-not $proxy.HostConfig.ReadonlyRootfs -or $proxy.Config.User -ne '101:101' -or @($proxy.HostConfig.CapDrop) -notcontains 'ALL' -or @($proxy.HostConfig.SecurityOpt) -notcontains 'no-new-privileges:true' -or $proxy.HostConfig.Privileged -or $proxy.HostConfig.PortBindings.Count -gt 0 -or $proxy.HostConfig.PidsLimit -ne 32 -or $proxy.HostConfig.Memory -lt 64MB -or $proxy.HostConfig.NanoCpus -lt 500000000) { throw 'Proxy container security/resource verification failed.' }
    $networkNames = @($proxy.NetworkSettings.Networks.PSObject.Properties.Name)
    if ($networkNames -notcontains 'bridge' -or $networkNames -notcontains $network -or $networkNames.Count -ne 2) { throw 'Proxy network attachment verification failed.' }
    [pscustomobject]@{ action='started'; run_id=$RunId; container=$container; network=$network; endpoint='http://khoa-router-proxy:8080'; image=$image; config_path=$configPath }
}
catch {
    $containerState = Invoke-Docker @('inspect',$container)
    if ($containerState.ExitCode -eq 0) {
        $ownedContainer = @($containerState.StdOut | ConvertFrom-Json)[0]
        if ($ownedContainer.Config.Labels.$configLabel -eq 'true' -and $ownedContainer.Config.Labels.'khoa.router-proxy.run-id' -eq $RunId) {
            $logs = Invoke-Docker @('logs',$container); if ($logs.StdOut) { Write-Warning $logs.StdOut }
            $null = Invoke-Docker @('rm','--force',$container)
        }
    }
    $networkState = Invoke-Docker @('network','inspect',$network)
    if ($networkState.ExitCode -eq 0) {
        $ownedNetwork = @($networkState.StdOut | ConvertFrom-Json)[0]
        if ($ownedNetwork.Labels.$configLabel -eq 'true' -and $ownedNetwork.Labels.'khoa.router-proxy.run-id' -eq $RunId) { $null = Invoke-Docker @('network','rm',$network) }
    }
    if (Test-OwnedRunDirectory) { Remove-Item -LiteralPath $runDir -Recurse -Force }
    throw
}
