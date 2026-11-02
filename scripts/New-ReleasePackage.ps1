<#
.SYNOPSIS
    Builds the distributable GitHub Release ZIP archive and SHA-256 checksum manifest.

.PARAMETER Version
    Release version tag (defaults to v1.0.0).

.PARAMETER OutputDir
    Output directory for the release archive (defaults to .\dist).
#>
[CmdletBinding()]
param(
    [string]$Version = "v1.0.0",
    [string]$OutputDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "dist"
}

$driversDir = Join-Path $repoRoot "drivers"
if (-not (Test-Path -LiteralPath (Join-Path $driversDir "HDXRT.CAT"))) {
    throw "Cannot build release archive: 'drivers\HDXRT.CAT' was not found under '$repoRoot'."
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$pkgName = "Realtek-HDA-Win11-Installer-$Version"
$stageRoot = Join-Path $OutputDir "_stage_$PID"
$pkgStage = Join-Path $stageRoot $pkgName
$zipPath = Join-Path $OutputDir "$pkgName.zip"
$sumsPath = Join-Path $OutputDir "SHA256SUMS.txt"

if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
if (Test-Path -LiteralPath $sumsPath) { Remove-Item -LiteralPath $sumsPath -Force }

try {
    New-Item -ItemType Directory -Path (Join-Path $pkgStage "drivers") -Force | Out-Null
    foreach ($file in @("Install-RealtekAudio.ps1", "README.md", "LICENSE")) {
        Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination (Join-Path $pkgStage $file) -Force
    }
    Copy-Item -Path (Join-Path $driversDir "*") -Destination (Join-Path $pkgStage "drivers") -Recurse -Force

    Write-Host "Compressing $pkgName.zip via System.IO.Compression.ZipFile..." -ForegroundColor Cyan
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stageRoot,
        $zipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sumLine = "$hash  $pkgName.zip"
    [System.IO.File]::WriteAllText($sumsPath, "$sumLine`n", [System.Text.UTF8Encoding]::new($false))

    $sizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
    Write-Host "Release package built: $zipPath ($sizeMb MB)" -ForegroundColor Green
    Write-Host "SHA-256: $hash" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
