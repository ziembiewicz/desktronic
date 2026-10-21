<#
.SYNOPSIS
  One-time setup, as administrator, that lets Home Assistant push the desk height to desk-tray.ps1.

.DESCRIPTION
  Two changes, both scoped as narrowly as Windows allows:
    1. URL reservation  http://+:8765/desk/ for YOUR account only, so desk-tray.ps1 can listen without
                        admin rights (netsh http add urlacl).
    2. Firewall rule    "Desk tray push": inbound TCP 8765, only from Home Assistant's address, all profiles
                        (a network that Windows suddenly calls "Public" must not cut the height off).
  Run it from your normal account: it remembers who you are, then asks for admin rights (UAC) and passes
  your account name on. Started directly as another admin account, the reservation would go to that account.
  -Remove undoes both.

.NOTES
  PowerShell 7.4 or newer (Windows PowerShell 5.1 works too).
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\Set-DeskTrayFirewall.ps1 -HomeAssistant 192.0.2.10
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\Set-DeskTrayFirewall.ps1 -Remove
#>
[CmdletBinding()]
param(
    [string]$HomeAssistant,
    [int]$Port = 8765,
    [string]$User,
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$url = "http://+:$Port/desk/"
$rule = 'Desk tray push'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    if (-not $Remove -and -not $HomeAssistant) { throw 'Give -HomeAssistant <address of Home Assistant>, for example -HomeAssistant 192.0.2.10' }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Port', $Port, '-User', "`"$me`"")
    if ($Remove) { $argList += '-Remove' } else { $argList += @('-HomeAssistant', $HomeAssistant) }
    # The same PowerShell that runs this script, elevated.
    $p = Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "The elevated part failed (exit code $($p.ExitCode))." }
    'Done. Check: netsh http show urlacl url=' + $url
    return
}

if (-not $User) { throw 'Start this script from your normal account (it passes -User to the admin part).' }
try {
    $null = & netsh http delete urlacl url=$url 2>&1
    Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (-not $Remove) {
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($HomeAssistant, [ref]$ip)) { throw "-HomeAssistant must be an IP address, not '$HomeAssistant'" }
        $out = & netsh http add urlacl url=$url user=$User
        if ($LASTEXITCODE -ne 0) { throw "netsh urlacl failed: $out" }
        $null = New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol TCP -LocalPort $Port `
            -RemoteAddress $HomeAssistant -Action Allow -Profile Any
    }
    exit 0
}
catch {
    Write-Host $_.Exception.Message
    Read-Host 'Press Enter to close'
    exit 1
}
