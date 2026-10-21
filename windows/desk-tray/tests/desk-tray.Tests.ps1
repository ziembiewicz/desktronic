# Tests for the pure functions of desk-tray.ps1, in PowerShell 7 with Pester 4 (the syntax is Pester 4's):
#   Install-Module Pester -RequiredVersion 4.10.1 -Scope CurrentUser   # once
#   Import-Module Pester -RequiredVersion 4.10.1 -Force
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
    $json = '{"h":"85.0","status":"Idle","m":["85.0","115.5","120.900001525879","0.0"],"locked":"off","seq":0,"result":""}'
    It 'reads a normal push' {
        $p = ConvertFrom-DeskPush $json
        $p.h | Should Be 85.0
        $p.status | Should Be 'Idle'
        $p.locked | Should Be $false
        $p.result | Should Be ''
        $p.seq | Should Be 0
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
    It 'drops unknown status and result values' {
        $p = ConvertFrom-DeskPush '{"h":"85.0","status":"<b>x</b>","m":[],"locked":"off","seq":"x","result":"<script>"}'
        $p.status | Should Be ''
        $p.result | Should Be ''
        $p.seq | Should Be 0
    }
    It 'passes a result with its sequence number' {
        $p = ConvertFrom-DeskPush '{"h":"85.0","status":"Idle","m":[],"locked":"off","seq":7,"result":"too_soon"}'
        $p.result | Should Be 'too_soon'
        $p.seq | Should Be 7
        (ConvertFrom-DeskPush '{"h":"85.0","status":"Idle","m":[],"locked":"off","seq":8,"result":"ok"}').result | Should Be 'ok'
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

$t0 = [datetime]'2026-10-21T20:00:00Z'
function M([string]$json) { $json | ConvertFrom-Json }
function Taps($q, [string[]]$dirs, [datetime]$at) { foreach ($d in $dirs) { $q = Add-DeskPress $q (M "{`"type`":`"tap`",`"dir`":`"$d`"}") $at }; $q }

Describe 'Add-DeskPress' {
    It 'adds quick taps up into one step' {
        $q = Taps $null @('up', 'up', 'up', 'up', 'up') $t0
        $q.kind | Should Be 'step'
        $q.n | Should Be 5
    }
    It 'lets up and down cancel out' {
        (Taps $null @('up', 'up', 'up', 'up', 'up', 'down', 'down') $t0).n | Should Be 3
    }
    It 'waits 0.7 s after the last tap before the step may go' {
        $q = Taps $null @('up') $t0
        $q = Taps $q @('up') $t0.AddMilliseconds(500)
        $q.notBefore | Should Be $t0.AddMilliseconds(1200)
        $q.since | Should Be $t0
    }
    It 'replaces queued taps with a hold or a preset (the last decision wins)' {
        $q = Taps $null @('up', 'up') $t0
        $h = Add-DeskPress $q (M '{"type":"hold","dir":"down"}') $t0
        $h.kind | Should Be 'hold'; $h.dir | Should Be 'down'
        $p = Add-DeskPress $h (M '{"type":"preset","n":2}') $t0
        $p.kind | Should Be 'preset'; $p.n | Should Be 2
        (Taps $p @('up') $t0).kind | Should Be 'step'
    }
    It 'ignores anything else and never takes a height' {
        $q = Taps $null @('up') $t0
        (Add-DeskPress $q (M '{"type":"tap","dir":"sideways"}') $t0).n | Should Be 1
        (Add-DeskPress $q (M '{"type":"preset","n":5}') $t0).kind | Should Be 'step'
        (Add-DeskPress $q (M '{"type":"goto","h":58}') $t0).kind | Should Be 'step'
        Add-DeskPress $null (M '{"type":"hello"}') $t0 | Should BeNullOrEmpty
    }
}

Describe 'Get-DeskSend' {
    It 'sends nothing before the quiet time is over' {
        Get-DeskSend (Taps $null @('up') $t0) $t0.AddMilliseconds(600) | Should BeNullOrEmpty
        Get-DeskSend $null $t0 | Should BeNullOrEmpty
    }
    It 'sends the summed step' {
        $s = Get-DeskSend (Taps $null @('up', 'up', 'up') $t0) $t0.AddSeconds(1)
        $s.body.cmd | Should Be 'step'
        $s.body.n | Should Be 3
        $s.rest | Should BeNullOrEmpty
    }
    It 'sends at most 20 taps and keeps the rest queued' {
        $q = Taps $null (@('down') * 26) $t0
        $s = Get-DeskSend $q $t0.AddSeconds(1)
        $s.body.n | Should Be -20
        $s.item.n | Should Be -20
        $s.rest.n | Should Be -6
    }
    It 'drops taps that cancelled out, and items older than 3 minutes' {
        (Get-DeskSend (Taps $null @('up', 'down') $t0) $t0.AddSeconds(1)).drop | Should Be $true
        $old = Get-DeskSend (Taps $null @('up') $t0) $t0.AddSeconds(181)
        $old.drop | Should Be $true
        $old.why | Should Be 'too old'
    }
    It 'sends a hold and a preset at once' {
        (Get-DeskSend (Add-DeskPress $null (M '{"type":"hold","dir":"up"}') $t0) $t0).body.cmd | Should Be 'hold_up'
        $p = Get-DeskSend (Add-DeskPress $null (M '{"type":"preset","n":3}') $t0) $t0
        $p.body.cmd | Should Be 'preset'
        $p.body.n | Should Be 3
    }
}

Describe 'Merge-DeskResult' {
    $sent = @{ kind = 'step'; n = 3; since = $t0; notBefore = $t0 }
    It 'keeps the queue as it is after ok' {
        Merge-DeskResult $null $sent 'ok' $t0 | Should BeNullOrEmpty
        (Merge-DeskResult (Taps $null @('up') $t0) $sent 'ok' $t0).n | Should Be 1
    }
    It 'requeues a step refused for now, added to newer taps, and waits' {
        $q = Merge-DeskResult (Taps $null @('up', 'up') $t0) $sent 'too_soon' $t0
        $q.n | Should Be 5
        $q.since | Should Be $t0
        $q.notBefore | Should Be $t0.AddSeconds(1)
        (Merge-DeskResult $null $sent 'budget' $t0).notBefore | Should Be $t0.AddSeconds(3)
    }
    It 'lets a newer hold or preset win over a refused step' {
        $q = Merge-DeskResult (Add-DeskPress $null (M '{"type":"preset","n":1}') $t0) $sent 'busy' $t0
        $q.kind | Should Be 'preset'
    }
    It 'drops the item on a final refusal' {
        foreach ($r in 'locked', 'limit', 'no_preset', 'here', '') { Merge-DeskResult $null $sent $r $t0 | Should BeNullOrEmpty }
    }
    It 'does not change the item it was given' {
        $null = Merge-DeskResult (Taps $null @('up') $t0) $sent 'too_soon' $t0
        $sent.n | Should Be 3
    }
}
