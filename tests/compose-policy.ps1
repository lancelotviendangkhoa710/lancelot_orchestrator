$ErrorActionPreference = 'Stop'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('khoa-compose-policy-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $scratch 'package'
$repo = Join-Path $scratch 'repo'
New-Item -ItemType Directory -Path $package, $repo -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\Invoke-ComposeCheck.ps1') -Destination $package
Set-Content -LiteralPath (Join-Path $repo 'compose.yaml') -Value 'services: {app: {image: alpine}}'
$scriptPath = Join-Path $package 'Invoke-ComposeCheck.ps1'

function global:docker {
    $global:LASTEXITCODE = 0
    if ($args -contains '--format') {
        '{"services":{"app":{"privileged":true,"volumes":[]}},"volumes":{},"networks":{},"secrets":{},"configs":{}}'
    }
}

try {
    try {
        & $scriptPath -RepoPath $repo -RunId '../escape' *> $null
        throw 'Unsafe RunId was accepted.'
    }
    catch {
        if ($_.Exception.Message -notmatch 'RunId|ValidatePattern') { throw }
    }
    try {
        & $scriptPath -RepoPath $repo -RunId 'policytest' *> $null
        throw 'Privileged service was accepted.'
    }
    catch {
        if ($_.Exception.Message -notmatch 'Privileged services') { throw }
    }
    Write-Output 'Compose path and privileged service policies: passed'
}
finally {
    Remove-Item Function:docker -ErrorAction SilentlyContinue
}
