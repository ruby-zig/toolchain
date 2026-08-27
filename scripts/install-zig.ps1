[CmdletBinding()]
param(
    [string]$Config,
    [string]$Destination,
    [string]$Platform
)

$ErrorActionPreference = 'Stop'
if (-not $Config) {
    $Config = Join-Path $PSScriptRoot '..\config\zig.json'
}
if (-not $Destination) {
    $Destination = Join-Path $PSScriptRoot '..\.ruby-zig\zig'
}
$settings = Get-Content -Raw -LiteralPath $Config | ConvertFrom-Json

if (-not $Platform) {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    $architecture = switch ($architecture) {
        'x64' { 'x86_64' }
        'arm64' { 'aarch64' }
        default { throw "Unsupported runner architecture: $architecture" }
    }
    $system = if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        'windows'
    } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        'macos'
    } else {
        'linux'
    }
    $Platform = "$architecture-$system"
}

$archive = $settings.archives.$Platform
if (-not $archive) { throw "No pinned Zig archive for $Platform." }

$destinationPath = [System.IO.Path]::GetFullPath($Destination)
$destinationRoot = [System.IO.Path]::GetPathRoot($destinationPath)
if ($destinationPath.TrimEnd('\', '/') -eq $destinationRoot.TrimEnd('\', '/')) {
    throw 'Refusing to install Zig into a filesystem root.'
}
$downloadDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "ruby-zig-$($settings.version)"
[System.IO.Directory]::CreateDirectory($downloadDirectory) | Out-Null
$fileName = [System.IO.Path]::GetFileName([Uri]$archive.url)
$downloadPath = Join-Path $downloadDirectory $fileName

Invoke-WebRequest -Uri $archive.url -OutFile $downloadPath
$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $downloadPath).Hash.ToLowerInvariant()
if ($actual -ne $archive.sha256) {
    throw "Zig archive digest mismatch for $Platform. Expected $($archive.sha256), got $actual."
}

if (Test-Path -LiteralPath $destinationPath) {
    Remove-Item -Recurse -Force -LiteralPath $destinationPath
}
[System.IO.Directory]::CreateDirectory($destinationPath) | Out-Null

if ($downloadPath.EndsWith('.zip')) {
    Expand-Archive -LiteralPath $downloadPath -DestinationPath $destinationPath
} else {
    & tar -xf $downloadPath -C $destinationPath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to extract the Zig archive.' }
}

$zigName = if ($Platform.EndsWith('-windows')) { 'zig.exe' } else { 'zig' }
$zig = Get-ChildItem -LiteralPath $destinationPath -Recurse -File -Filter $zigName |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $zig) { throw 'The extracted Zig executable was not found.' }

$reported = (& $zig version).Trim()
if ($reported -ne $settings.version) {
    throw "Expected Zig $($settings.version), got $reported."
}

Write-Host "Installed Zig $reported at $zig"
if ($env:GITHUB_OUTPUT) {
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "zig=$zig`n", $encoding)
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "version=$reported`n", $encoding)
    [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "sha256=$actual`n", $encoding)
}
Write-Output $zig
