[CmdletBinding()]
param(
    [string]$Owner = 'ruby',
    [string]$OutputPath,
    [string]$NativeScopePath
)

$ErrorActionPreference = 'Stop'
if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot '..\config\repositories.json'
}
if (-not $NativeScopePath) {
    $NativeScopePath = Join-Path $PSScriptRoot '..\config\native-scope.json'
}

$nativeScope = Get-Content -Raw -LiteralPath $NativeScopePath | ConvertFrom-Json
$scopeByName = @{}
foreach ($name in $nativeScope.direct_native) {
    $scopeByName[$name] = 'direct-native'
}
foreach ($name in $nativeScope.native_test_scope) {
    $scopeByName[$name] = 'native-test'
}
foreach ($name in $nativeScope.fixture_template_or_example_scope) {
    $scopeByName[$name] = 'fixture-template-example'
}

$headers = @{ 'User-Agent' = 'ruby-zig-fleet-inventory' }
$repositories = [System.Collections.Generic.List[object]]::new()
$page = 1

do {
    $uri = "https://api.github.com/orgs/$Owner/repos?per_page=100&type=all&sort=full_name&page=$page"
    [object[]]$batch = Invoke-RestMethod -Headers $headers -Uri $uri
    $repositories.AddRange($batch)
    $page++
} while ($batch.Count -eq 100)

$items = foreach ($repository in ($repositories | Sort-Object full_name)) {
    $classification = if ($scopeByName.ContainsKey($repository.name)) {
        $scopeByName[$repository.name]
    } else {
        'none-detected'
    }
    [ordered]@{
        name              = $repository.name
        upstream          = $repository.full_name
        url               = $repository.html_url
        default_branch    = $repository.default_branch
        primary_language  = $repository.language
        archived          = [bool]$repository.archived
        upstream_is_fork  = [bool]$repository.fork
        disabled          = [bool]$repository.disabled
        pushed_at         = $repository.pushed_at
        native_scope      = $classification
        fleet_state       = 'not-forked'
    }
}

$manifest = [ordered]@{
    schema       = 1
    owner        = $Owner
    generated_at = [DateTime]::UtcNow.ToString('o')
    count        = $items.Count
    repositories = @($items)
}

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
$parent = [System.IO.Path]::GetDirectoryName($resolvedOutput)
[System.IO.Directory]::CreateDirectory($parent) | Out-Null
[System.IO.File]::WriteAllText(
    $resolvedOutput,
    (($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host "Wrote $($items.Count) repositories to $resolvedOutput"
