# Tests for the pure functions of desk-tray.ps1. Pester 3.4 (built into Windows) or Pester 4:
#   Import-Module Pester -MaximumVersion 4.99 -Force
#   Invoke-Pester .\tests
# Dot-sourcing the script only defines its functions; the tray does not start.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'desk-tray.ps1')

$token = 'a' * 48

Describe 'Read-DeskTrayConfig' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('desk-tray-test-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $dir
    $f = Join-Path $dir 'config.json'
    $good = @{ panel_webhook_url = 'http://192.0.2.10:8123/api/webhook/A'; panel_stop_webhook_url = 'http://192.0.2.10:8123/api/webhook/B'; push_token = $token }

    It 'reads a valid config' {
        $good | ConvertTo-Json | Set-Content $f
        (Read-DeskTrayConfig $f).panel_webhook_url | Should Be 'http://192.0.2.10:8123/api/webhook/A'
    }
    It 'rejects a missing file' {
        { Read-DeskTrayConfig (Join-Path $dir 'nope.json') } | Should Throw 'not found'
    }
    It 'rejects broken JSON without quoting it' {
        Set-Content $f "{ `"push_token`": `"$token`""
        try { Read-DeskTrayConfig $f; $msg = '' } catch { $msg = $_.Exception.Message }
        $msg | Should Match 'not valid JSON'
        $msg | Should Not Match $token
    }
    It 'rejects a missing or non-http stop URL' {
        $c = $good.Clone(); $c.Remove('panel_stop_webhook_url'); $c | ConvertTo-Json | Set-Content $f
        { Read-DeskTrayConfig $f } | Should Throw 'panel_stop_webhook_url'
        $c = $good.Clone(); $c.panel_stop_webhook_url = 'file:///c:/x'; $c | ConvertTo-Json | Set-Content $f
        { Read-DeskTrayConfig $f } | Should Throw 'panel_stop_webhook_url'
    }
    It 'rejects a short token' {
        $c = $good.Clone(); $c.push_token = 'short'; $c | ConvertTo-Json | Set-Content $f
        { Read-DeskTrayConfig $f } | Should Throw 'push_token'
    }
    Remove-Item -Recurse -Force $dir
}

Describe 'Test-DeskToken' {
    It 'accepts the same token' { Test-DeskToken $token $token | Should Be $true }
    It 'rejects a different token of the same length' { Test-DeskToken ('b' * 48) $token | Should Be $false }
    It 'rejects a prefix and a longer token' {
        Test-DeskToken ('a' * 47) $token | Should Be $false
        Test-DeskToken ('a' * 49) $token | Should Be $false
    }
    It 'rejects a missing header and an empty expected token' {
        Test-DeskToken $null $token | Should Be $false
        Test-DeskToken '' $token | Should Be $false
        Test-DeskToken '' '' | Should Be $false
    }
}

Describe 'ConvertTo-DeskNumber' {
    It 'parses Home Assistant states with a dot' {
        ConvertTo-DeskNumber '85.0' | Should Be 85.0
        ConvertTo-DeskNumber '120.900001525879' | Should Be 120.9
    }
    It 'returns nothing for non-numbers' {
        ConvertTo-DeskNumber 'unavailable' | Should BeNullOrEmpty
        ConvertTo-DeskNumber $null | Should BeNullOrEmpty
        ConvertTo-DeskNumber 'NaN' | Should BeNullOrEmpty
    }
    It 'does not depend on the system decimal comma' {
        $old = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'pl-PL'
            ConvertTo-DeskNumber '85.5' | Should Be 85.5
        }
        finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
}

Describe 'ConvertFrom-DeskPush' {
    $json = '{"h":"85.0","status":"Idle","m":["85.0","115.5","120.900001525879","0.0"],"locked":"off","refused":""}'
    It 'reads a normal push' {
        $p = ConvertFrom-DeskPush $json
        $p.h | Should Be 85.0
        $p.status | Should Be 'Idle'
        $p.locked | Should Be $false
        $p.refused | Should Be ''
    }
    It 'keeps only presets with a height, numbered by slot' {
        $p = ConvertFrom-DeskPush $json
        @($p.presets).Count | Should Be 3
        ($p.presets | ForEach-Object { "$($_.n)=$($_.h)" }) -join ' ' | Should Be '1=85 2=115.5 3=120.9'
    }
    It 'treats an unknown lock state as locked' {
        (ConvertFrom-DeskPush '{"h":"85.0","status":"Idle","m":[],"locked":"unknown"}').locked | Should Be $true
        (ConvertFrom-DeskPush '{"h":"85.0","status":"Idle","m":[]}').locked | Should Be $true
    }
    It 'drops unknown status and refusal values' {
        $p = ConvertFrom-DeskPush '{"h":"85.0","status":"<b>x</b>","m":[],"locked":"off","refused":"<script>"}'
        $p.status | Should Be ''
        $p.refused | Should Be ''
    }
    It 'passes a known refusal' {
        (ConvertFrom-DeskPush '{"h":"85.0","status":"Idle","m":[],"locked":"off","refused":"too_soon"}').refused | Should Be 'too_soon'
    }
    It 'gives no height for unavailable' {
        (ConvertFrom-DeskPush '{"h":"unavailable","status":"unavailable","m":["unknown"],"locked":"off"}').h | Should BeNullOrEmpty
    }
    It 'returns nothing for broken or non-object JSON' {
        ConvertFrom-DeskPush '{"h":' | Should BeNullOrEmpty
        ConvertFrom-DeskPush '[1,2]' | Should BeNullOrEmpty
        ConvertFrom-DeskPush '' | Should BeNullOrEmpty
    }
    It 'ignores more than four presets' {
        @((ConvertFrom-DeskPush '{"h":"85","status":"Idle","m":["1","2","3","4","5"],"locked":"off"}').presets).Count | Should Be 4
    }
}

Describe 'Get-DeskCommand' {
    function M([string]$json) { $json | ConvertFrom-Json }
    It 'maps taps and holds' {
        (Get-DeskCommand (M '{"type":"tap","dir":"up"}')).body.cmd | Should Be 'tap_up'
        (Get-DeskCommand (M '{"type":"tap","dir":"down"}')).body.cmd | Should Be 'tap_down'
        (Get-DeskCommand (M '{"type":"hold","dir":"up"}')).body.cmd | Should Be 'hold_up'
        (Get-DeskCommand (M '{"type":"hold","dir":"down"}')).body.cmd | Should Be 'hold_down'
    }
    It 'maps presets 1-4 only' {
        $c = Get-DeskCommand (M '{"type":"preset","n":2}')
        $c.body.cmd | Should Be 'preset'
        $c.body.n | Should Be 2
        Get-DeskCommand (M '{"type":"preset","n":5}') | Should BeNullOrEmpty
        Get-DeskCommand (M '{"type":"preset","n":"x"}') | Should BeNullOrEmpty
    }
    It 'maps stop to the stop webhook' {
        (Get-DeskCommand (M '{"type":"stop"}')).stop | Should Be $true
        (Get-DeskCommand (M '{"type":"tap","dir":"up"}')).stop | Should Be $false
    }
    It 'never sends a height or anything unknown' {
        Get-DeskCommand (M '{"type":"tap","dir":"sideways"}') | Should BeNullOrEmpty
        Get-DeskCommand (M '{"type":"goto","h":58}') | Should BeNullOrEmpty
        Get-DeskCommand (M '{"type":"hello"}') | Should BeNullOrEmpty
    }
}
