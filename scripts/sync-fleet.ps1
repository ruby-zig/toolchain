[CmdletBinding()]
param(
    [string]$Organization = 'ruby-zig',
    [string]$Manifest,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
if (-not $Manifest) {
    $Manifest = Join-Path $PSScriptRoot '..\config\repositories.json'
}

if (-not $Apply) {
    Write-Host 'Dry run. Pass -Apply to fast-forward clean upstream branches.'
} else {
    gh auth status --hostname github.com
    if ($LASTEXITCODE -ne 0) { throw 'gh is not authenticated.' }
}

$inventory = Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json
foreach ($repository in $inventory.repositories) {
    $destination = "$Organization/$($repository.name)"
    if (-not $Apply) {
        Write-Host "would sync $destination from $($repository.upstream)"
        continue
    }

    gh repo sync $destination --source $repository.upstream --branch $repository.default_branch
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Sync needs attention: $destination"
    }
}
