<#
.SYNOPSIS
  Downloads what desk-tray.ps1 needs and is not in the repository: the WebView2 SDK and the DSEG7 font.

.DESCRIPTION
  Both downloads are pinned to a version and a hash. Everything is unpacked into a temporary folder first;
  only after every check passes do the files move into place, so a failed check leaves nothing behind.
    WebView2 SDK  Microsoft.Web.WebView2 1.0.4258.31 from nuget.org: SHA-512 of the package, then the
                  Authenticode signature of every DLL (Microsoft).            -> lib\webview2\
                  License: BSD-3-Clause (LICENSE.txt, NOTICE.txt travel with the DLLs).
    Font          DSEG v0.46 release zip from GitHub: SHA-256 of the zip; only DSEG7Modern-Bold.woff2 and the
                  license are kept.                                           -> lib\fonts\
                  (c) keshikan, SIL Open Font License 1.1, Reserved Font Name "DSEG".
  No admin rights needed. The WebView2 Runtime itself is part of Windows 11 and current Windows 10.

.NOTES
  Windows PowerShell 5.1. Plain ASCII. Run from the folder that holds desk-tray.ps1:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-DeskTrayDeps.ps1
#>
[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [string]$SdkVersion = '1.0.4258.31',
    [string]$SdkSha512 = '1E5195C2FC8FFC85A25C053C2B9ED59A0E7D9216370D630EC4C9C7E001EEB05472D3FBC3023288B5750854D5E25D76AAE022DF499C8D522735C0E2259CF2EC3D',
    [string]$FontUrl = 'https://github.com/keshikan/DSEG/releases/download/v0.46/fonts-DSEG_v046.zip',
    [string]$FontZipSha256 = 'A6C2F43520971CA8067262E78D49025E605F749BF716EC5394BAD9A0EE1C238C'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
# Windows PowerShell 5.1 does not offer TLS 1.2 by default; nuget.org and GitHub require it.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('desk-tray-deps-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmp

function Get-Pinned([string]$Url, [string]$File, [string]$Algorithm, [string]$Expected) {
    Invoke-WebRequest -Uri $Url -OutFile $File -UseBasicParsing
    $actual = (Get-FileHash -Path $File -Algorithm $Algorithm).Hash
    if ($actual -ne $Expected.ToUpperInvariant()) { throw "$Algorithm mismatch for $Url`n expected $Expected`n actual   $actual" }
}

function Expand-Entries([string]$Zip, [hashtable]$Map, [string]$Dest) {
    # Extracts only the listed entries (zip path -> relative output path). .nupkg is a zip with another name.
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($e in $z.Entries) {
            if ($Map.ContainsKey($e.FullName)) {
                $out = Join-Path $Dest $Map[$e.FullName]
                $null = New-Item -ItemType Directory -Force -Path (Split-Path $out -Parent)
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
                $Map.Remove($e.FullName)
            }
        }
    }
    finally { $z.Dispose() }
    if ($Map.Count -gt 0) { throw ('Missing in ' + (Split-Path -Leaf $Zip) + ': ' + ($Map.Keys -join ', ')) }
}

try {
    # WebView2 SDK
    $nupkg = Join-Path $tmp 'webview2.nupkg'
    Get-Pinned "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$SdkVersion/microsoft.web.webview2.$SdkVersion.nupkg" $nupkg 'SHA512' $SdkSha512
    $sdk = Join-Path $tmp 'webview2'
    Expand-Entries $nupkg @{
        'lib/net462/Microsoft.Web.WebView2.Core.dll'     = 'Microsoft.Web.WebView2.Core.dll'
        'lib/net462/Microsoft.Web.WebView2.WinForms.dll' = 'Microsoft.Web.WebView2.WinForms.dll'
        'runtimes/win-x64/native/WebView2Loader.dll'     = 'runtimes\win-x64\native\WebView2Loader.dll'
        'runtimes/win-arm64/native/WebView2Loader.dll'   = 'runtimes\win-arm64\native\WebView2Loader.dll'
        'LICENSE.txt'                                    = 'LICENSE.txt'
        'NOTICE.txt'                                     = 'NOTICE.txt'
    } $sdk
    Get-ChildItem $sdk -Recurse -Filter *.dll | ForEach-Object {
        $sig = Get-AuthenticodeSignature $_.FullName
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
            throw "Bad signature: $($_.Name) -> $($sig.Status) $($sig.SignerCertificate.Subject)"
        }
        '{0,-45} {1}' -f $_.FullName.Substring($sdk.Length), $sig.Status
    }

    # Font
    $fontZip = Join-Path $tmp 'dseg.zip'
    Get-Pinned $FontUrl $fontZip 'SHA256' $FontZipSha256
    $fonts = Join-Path $tmp 'fonts'
    Expand-Entries $fontZip @{
        'fonts-DSEG_v046/DSEG7-Modern/DSEG7Modern-Bold.woff2' = 'DSEG7Modern-Bold.woff2'
        'fonts-DSEG_v046/DSEG-LICENSE.txt'                    = 'DSEG-LICENSE.txt'
    } $fonts

    # Every check passed: move into place.
    foreach ($pair in @(@($sdk, 'lib\webview2'), @($fonts, 'lib\fonts'))) {
        $dest = Join-Path $Root $pair[1]
        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent)
        Move-Item -Path $pair[0] -Destination $dest
    }
    "OK -> $(Join-Path $Root 'lib')"
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
