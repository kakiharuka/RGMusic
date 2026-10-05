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

$Packaging = Join-Path $ProjectRoot "packaging"
$AppsSource = Join-Path $Packaging "APPS"
$ImgsSource = Join-Path $Packaging "Imgs"
$DistRoot = Join-Path $ProjectRoot "dist"
$Stage = Join-Path $ProjectRoot ("release\distribution-" + $Version)
$ZipPath = Join-Path $DistRoot ("RGMusic-" + $Version + "-Distribution.zip")
$HashPath = $ZipPath + ".sha256.txt"

& (Join-Path $PSScriptRoot "build_apps_package.ps1") -Version $Version

Reset-Directory $Stage
Copy-Item -LiteralPath $AppsSource -Destination (Join-Path $Stage "APPS") -Recurse
Copy-Item -LiteralPath $ImgsSource -Destination (Join-Path $Stage "Imgs") -Recurse
Copy-Item -LiteralPath (Join-Path $ProjectRoot "LICENSES") -Destination (Join-Path $Stage "LICENSES") -Recurse

foreach ($name in @("INSTALL.txt", "LICENSE", "README.md", "THIRD_PARTY_NOTICES.md")) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot $name) -Destination (Join-Path $Stage $name)
}
Copy-Item -LiteralPath (Join-Path $ProjectRoot "assets\README-APPS.txt") -Destination (Join-Path $Stage "README-APPS.txt")
Set-Content -LiteralPath (Join-Path $Stage "VERSION.txt") -Value ("RG Music " + $Version) -Encoding UTF8

New-Item -ItemType Directory -Path $DistRoot -Force | Out-Null
if (Test-Path -LiteralPath $ZipPath) {
    Assert-InProject $ZipPath | Out-Null
    Remove-Item -LiteralPath $ZipPath -Force
}
& tar.exe -a -c -f $ZipPath -C $Stage .
if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }

$hash = Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256
$hash.Hash | Set-Content -LiteralPath $HashPath -Encoding ASCII
Write-Host "Distribution: $ZipPath"
Write-Host "SHA256      : $($hash.Hash)"