param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $OpenCodeArgs
)

$ErrorActionPreference = 'Stop'
$envFile = Join-Path $PSScriptRoot '.env'

if (-not (Test-Path -LiteralPath $envFile)) {
    throw "Create $envFile from .env.example and paste your 9Router key there."
}

$entry = Get-Content -LiteralPath $envFile -Encoding utf8 |
    Where-Object { $_ -match '^\s*NINEROUTER_API_KEY\s*=' } |
    Select-Object -First 1

if (-not $entry) {
    throw 'Add NINEROUTER_API_KEY=your_key to .env.'
}

$key = ($entry -replace '^\s*NINEROUTER_API_KEY\s*=\s*', '').Trim().Trim('"').Trim("'")
if (-not $key) {
    throw 'NINEROUTER_API_KEY is empty in .env.'
}

$env:NINEROUTER_API_KEY = $key
$env:OPENCODE_CONFIG = Join-Path $PSScriptRoot 'opencode.jsonc'
Remove-Variable key, entry

Push-Location $PSScriptRoot
try {
    & opencode @OpenCodeArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
    Remove-Item Env:NINEROUTER_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:OPENCODE_CONFIG -ErrorAction SilentlyContinue
}
