param(
    [string]$Version = "r0.76"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$RootPrefix = $ProjectRoot.TrimEnd("\") + "\"

function Assert-InProject([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($RootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify path outside project: $full"
    }
    return $full
}

function Reset-Directory([string]$Path) {
    $full = Assert-InProject $Path
    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
    New-Item -ItemType Directory -Path $full -Force | Out-Null
}

$SourceRoot = Join-Path $ProjectRoot "source"
$SourceApp = Join-Path $SourceRoot "RGMusic"
$SourceLauncher = Join-Path $SourceRoot "RG Music.sh"
$AssetRoot = Join-Path $ProjectRoot "assets"
$IconPng = Join-Path $AssetRoot "RG Music.png"
$Readme = Join-Path $AssetRoot "README-APPS.txt"
$Packaging = Join-Path $ProjectRoot "packaging"
$AppsRoot = Join-Path $Packaging "APPS"
$AppsApp = Join-Path $AppsRoot "RGMusic"
$ImagesRoot = Join-Path $Packaging "Imgs"
$DistRoot = Join-Path $ProjectRoot "dist"
$ZipPath = Join-Path $DistRoot "RGMusic-APPS-$Version.zip"

$SourceBackend = Join-Path $SourceRoot "RGMusicNetease"
$BackendBinary = Join-Path $SourceApp "app\bin\rgmusic-netease.aarch64"
if (-not (Test-Path -LiteralPath $BackendBinary)) {
    & (Join-Path $PSScriptRoot "build_backend.ps1")
    if (-not (Test-Path -LiteralPath $BackendBinary)) {
        throw "Backend build did not create: $BackendBinary"
    }
}
foreach ($required in @($SourceLauncher, (Join-Path $SourceApp "app\main.lua"), $BackendBinary, $IconPng, $Readme, (Join-Path $SourceBackend "LICENSE-netease-music.txt"))) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Missing required file: $required"
    }
}

Reset-Directory $Packaging
New-Item -ItemType Directory -Path $AppsApp, $ImagesRoot -Force | Out-Null
Copy-Item -LiteralPath $SourceLauncher -Destination (Join-Path $AppsRoot "RG Music.sh")
Copy-Item -LiteralPath (Join-Path $SourceApp "app") -Destination $AppsApp -Recurse
$BinKeep = Join-Path $AppsApp "app\bin\.gitkeep"
if (Test-Path -LiteralPath $BinKeep) { Remove-Item -LiteralPath $BinKeep -Force }
Copy-Item -LiteralPath (Join-Path $SourceApp "runtime") -Destination $AppsApp -Recurse
Copy-Item -LiteralPath $IconPng -Destination (Join-Path $ImagesRoot "RG Music.png")
Copy-Item -LiteralPath $IconPng -Destination (Join-Path $AppsApp "app\assets\RG Music.png") -Force
$WindowsHelper = Join-Path $AppsApp "app\bin\rgmusic-netease.exe"
if (Test-Path -LiteralPath $WindowsHelper) { Remove-Item -LiteralPath $WindowsHelper -Force }
$ThirdParty = Join-Path $AppsApp "runtime\third-party"
New-Item -ItemType Directory -Path $ThirdParty -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $SourceBackend "LICENSE-netease-music.txt") -Destination $ThirdParty
Copy-Item -LiteralPath (Join-Path $SourceBackend "LICENSE-req-v3.txt") -Destination $ThirdParty
Copy-Item -LiteralPath (Join-Path $SourceBackend "LICENSE-go-qrcode.txt") -Destination $ThirdParty
Copy-Item -LiteralPath $Readme -Destination (Join-Path $Packaging "README-APPS.txt")

New-Item -ItemType Directory -Path $DistRoot -Force | Out-Null
if (Test-Path -LiteralPath $ZipPath) {
    Assert-InProject $ZipPath | Out-Null
    Remove-Item -LiteralPath $ZipPath -Force
}
& tar.exe -a -c -f $ZipPath -C $Packaging .
if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }

$hash = Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256
Write-Host "Package: $ZipPath"
Write-Host "SHA256 : $($hash.Hash)"