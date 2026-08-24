# build.ps1 - builds the portable Encore release zip into dist\.
# Downloads the AutoHotkey v2 base into build\ on first run and caches it
# there. Works in Windows PowerShell 5.1 and PowerShell 7 (used by the
# GitHub Actions release workflow).
#
# The zip ships the UNMODIFIED official AutoHotkey64.exe renamed to
# Encore.exe, next to the plain-text script: run with no arguments, the
# interpreter loads the script matching its own name (Encore.ahk). The
# stock interpreter stays byte-identical to the official release and keeps
# its antivirus reputation.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = $PSScriptRoot
$tools = Join-Path $root 'build'
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $tools | Out-Null

# version from the script header ("; Encore - vX.Y.Z ...")
$header = (Get-Content (Join-Path $root 'Encore.ahk') -TotalCount 5) -join ' '
$version = if ($header -match 'v(\d+\.\d+\.\d+)') { $Matches[1] } else { '0.0.0' }
Write-Host "Building Encore $version"

$base = Join-Path $tools 'base\AutoHotkey64.exe'
if (-not (Test-Path $base)) {
    Write-Host 'Downloading AutoHotkey v2 base...'
    $rels = Invoke-RestMethod 'https://api.github.com/repos/AutoHotkey/AutoHotkey/releases'
    $v2 = $rels | Where-Object { $_.tag_name -like 'v2.0*' } | Select-Object -First 1
    $asset = $v2.assets | Where-Object { $_.name -like 'AutoHotkey_2*.zip' } | Select-Object -First 1
    Invoke-WebRequest $asset.browser_download_url -OutFile (Join-Path $tools 'ahk2.zip')
    Expand-Archive (Join-Path $tools 'ahk2.zip') (Join-Path $tools 'base') -Force
}

# clear dist with retries - sync clients/AV can hold freshly written files briefly
if (Test-Path $dist) {
    $cleared = $false
    foreach ($i in 1..5) {
        try {
            Remove-Item $dist -Recurse -Force -ErrorAction Stop
            $cleared = $true
            break
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $cleared) { throw "Could not clear $dist - is Encore.exe running or the folder open?" }
}
New-Item -ItemType Directory -Force $dist | Out-Null

# the renamed stock interpreter auto-loads Encore.ahk beside it
New-Item -ItemType Directory -Force (Join-Path $dist 'lib') | Out-Null
Copy-Item $base (Join-Path $dist 'Encore.exe')
Copy-Item (Join-Path $root 'Encore.ahk') $dist
Copy-Item (Join-Path $root 'ComVar.ahk') $dist
Copy-Item (Join-Path $root 'Promise.ahk') $dist
foreach ($f in 'WebView2.ahk', 'WebView2Loader.dll', 'JSON.ahk') {
    Copy-Item (Join-Path $root "lib\$f") (Join-Path $dist 'lib')
}
Copy-Item (Join-Path $root 'ui') (Join-Path $dist 'ui') -Recurse
Copy-Item (Join-Path $root 'app.ico') $dist
Copy-Item (Join-Path $root 'rec.ico') $dist
Copy-Item (Join-Path $root 'play.ico') $dist
Copy-Item (Join-Path $root 'README.md') $dist
Copy-Item (Join-Path $root 'LICENSE') $dist
Copy-Item (Join-Path $root 'THIRD-PARTY.txt') $dist

$zip = Join-Path $dist "Encore-$version.zip"
$contents = @('Encore.exe', 'Encore.ahk', 'ComVar.ahk', 'Promise.ahk', 'lib', 'ui', 'app.ico', 'rec.ico', 'play.ico', 'README.md', 'LICENSE', 'THIRD-PARTY.txt') | ForEach-Object { Join-Path $dist $_ }
Compress-Archive -Path $contents -DestinationPath $zip -Force
Write-Host "Done: $zip"
