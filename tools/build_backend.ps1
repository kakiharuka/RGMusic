param(
    [switch]$Windows,
    [string]$Output = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$BackendRoot = Join-Path $ProjectRoot "source\RGMusicNetease"
$BundledGo = Join-Path $ProjectRoot ".tools\go\bin\go.exe"
$Go = if (Test-Path -LiteralPath $BundledGo) { $BundledGo } else { "go" }

$env:CGO_ENABLED = "0"
$env:GOSUMDB = "off"
$env:GOPROXY = "https://goproxy.cn,direct"

if ($Windows) {
    $env:GOOS = "windows"
    $env:GOARCH = "amd64"
    if ($Output -eq "") { $Output = Join-Path $ProjectRoot ".tools\rgmusic-netease.exe" }
} else {
    $env:GOOS = "linux"
    $env:GOARCH = "arm64"
    if ($Output -eq "") { $Output = Join-Path $ProjectRoot "source\RGMusic\app\bin\rgmusic-netease.aarch64" }
}

$OutputDir = Split-Path -Parent $Output
if ($OutputDir) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Push-Location $BackendRoot
try {
    & $Go fmt ./...
    & $Go mod tidy
    & $Go build -trimpath -ldflags="-s -w" -o $Output .
    if ($LASTEXITCODE -ne 0) { throw "go build failed" }
} finally {
    Pop-Location
}

Write-Host "Built: $Output"