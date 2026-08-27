[CmdletBinding()]
param(
    [string]$Organization = 'ruby-zig',
    [string]$Manifest,
    [switch]$ExcludeArchived,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
if (-not $Manifest) {
    $Manifest = Join-Path $PSScriptRoot '..\config\repositories.json'
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required.'
}

$inventory = Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json
$selected = @($inventory.repositories | Where-Object { -not ($ExcludeArchived -and $_.archived) })

if (-not $Apply) {
    Write-Host "Dry run for $($selected.Count) repositories. Pass -Apply to create public forks."
}

if ($Apply) {
    gh auth status --hostname github.com
    if ($LASTEXITCODE -ne 0) { throw 'gh is not authenticated.' }
    gh api "orgs/$Organization" --silent
    if ($LASTEXITCODE -ne 0) { throw "Organization $Organization is unavailable." }
}

foreach ($repository in $selected) {
    $destination = "$Organization/$($repository.name)"
    if (-not $Apply) {
        Write-Host "would fork $($repository.upstream) -> $destination"
        continue
    }

    gh repo view $destination --json nameWithOwner --jq .nameWithOwner 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "exists $destination"
        continue
    }

    Write-Host "forking $($repository.upstream) -> $destination"
    gh repo fork $repository.upstream --org $Organization --clone=false
    if ($LASTEXITCODE -ne 0) {
        throw "Fork failed for $($repository.upstream)."
    }

    Start-Sleep -Seconds 2
}
