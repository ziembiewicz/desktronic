# Tests for the pure functions of meeting-reminder.ps1. Pester 3.4 (built into Windows) or Pester 4:
#   Import-Module Pester -MaximumVersion 4.99 -Force
#   Invoke-Pester .\tests
# Dot-sourcing the script only defines its functions; the main loop does not start.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'meeting-reminder.ps1')

function New-Time([int]$h, [int]$m, [int]$s = 0, [int]$day = 11) { New-Object DateTime 2026, 10, $day, $h, $m, $s }

Describe 'Get-MeetingStart' {
    It 'reads the start time from an Outlook reminder' {
        Get-MeetingStart -Text '17:00 Microsoft Teams Meeting' -Created (New-Time 16 45) | Should Be (New-Time 17 0)
    }
    It 'accepts a time without a location' {
        Get-MeetingStart -Text '17:00' -Created (New-Time 16 45) | Should Be (New-Time 17 0)
    }
    It 'accepts a one-digit hour' {
        Get-MeetingStart -Text '9:05 Room 1' -Created (New-Time 8 50) | Should Be (New-Time 9 5)
    }
    It 'rolls over midnight' {
        Get-MeetingStart -Text '00:05 Standup' -Created (New-Time 23 50) | Should Be (New-Time 0 5 0 12)
    }
    It 'accepts a lead of exactly 60 minutes' {
        Get-MeetingStart -Text '17:00 x' -Created (New-Time 16 0) | Should Be (New-Time 17 0)
    }
    It 'ignores text without a leading time' {
        Get-MeetingStart -Text 'This is where notifications will appear on your desktop.' -Created (New-Time 16 45) | Should BeNullOrEmpty
        Get-MeetingStart -Text 'Success!' -Created (New-Time 16 45) | Should BeNullOrEmpty
        Get-MeetingStart -Text '' -Created (New-Time 16 45) | Should BeNullOrEmpty
    }
    It 'ignores a 12-hour time' {
        Get-MeetingStart -Text '5:00 PM Room' -Created (New-Time 16 45) | Should BeNullOrEmpty
        Get-MeetingStart -Text '5:00pm Room' -Created (New-Time 16 45) | Should BeNullOrEmpty
    }
    It 'keeps a location that contains am or pm as a word' {
        Get-MeetingStart -Text '17:00 Room AM-2' -Created (New-Time 16 45) | Should Be (New-Time 17 0)
    }
    It 'ignores an invalid time' {
        Get-MeetingStart -Text '24:00 x' -Created (New-Time 23 50) | Should BeNullOrEmpty
        Get-MeetingStart -Text '17:60 x' -Created (New-Time 16 45) | Should BeNullOrEmpty
    }
    It 'ignores a reminder created after the start (snoozed or at the time of the event)' {
        Get-MeetingStart -Text '16:45 x' -Created (New-Time 16 50) | Should BeNullOrEmpty
        Get-MeetingStart -Text '17:00 x' -Created (New-Time 17 0 1) | Should BeNullOrEmpty
    }
    It 'ignores a start more than 60 minutes ahead' {
        Get-MeetingStart -Text '18:00 x' -Created (New-Time 16 45) | Should BeNullOrEmpty
    }
}

Describe 'Add-Meeting' {
    It 'queues a future meeting once' {
        $s = [System.Collections.ArrayList]::new()
        Add-Meeting -Schedule $s -Start (New-Time 17 0) -Now (New-Time 16 46) | Should Be 'queued'
        Add-Meeting -Schedule $s -Start (New-Time 17 0) -Now (New-Time 16 47) | Should Be 'duplicate'
        $s.Count | Should Be 1
    }
    It 'refuses a meeting too close to warn in time' {
        $s = [System.Collections.ArrayList]::new()
        Add-Meeting -Schedule $s -Start (New-Time 17 0) -Now (New-Time 16 59 30) | Should Be 'too-late'
        $s.Count | Should Be 0
    }
    It 'refuses a stale reminder from yesterday' {
        $s = [System.Collections.ArrayList]::new()
        $start = Get-MeetingStart -Text '17:00 x' -Created (New-Time 16 45 0 10)
        Add-Meeting -Schedule $s -Start $start -Now (New-Time 16 50) | Should Be 'too-late'
    }
}

Describe 'Get-DueStep' {
    It 'sends nothing before the warning time' {
        $s = [System.Collections.ArrayList]::new()
        [void](Add-Meeting -Schedule $s -Start (New-Time 17 0) -Now (New-Time 16 46))
        @(Get-DueStep -Schedule $s -Now (New-Time 16 59 29)).Count | Should Be 0
    }
    It 'warns at T0 - 30 s and goes at T0, then forgets the meeting' {
        $s = [System.Collections.ArrayList]::new()
        [void](Add-Meeting -Schedule $s -Start (New-Time 17 0) -Now (New-Time 16 46))
        $warn = @(Get-DueStep -Schedule $s -Now (New-Time 16 59 31))
        $warn.Count | Should Be 1
        $warn[0].Step | Should Be 'warn'
        @(Get-DueStep -Schedule $s -Now (New-Time 16 59 45)).Count | Should Be 0
        $go = @(Get-DueStep -Schedule $s -Now (New-Time 17 0 1))
        $go.Count | Should Be 1
        $go[0].Step | Should Be 'go'
        $s.Count | Should Be 0
    }
    It 'skips a late warning and never sends go for that meeting' {
        $s = [System.Collections.ArrayList]::new()
        [void](Add-Meeting -Schedule $s -Start (New-Time 17 0) -Now (New-Time 16 46))
        $late = @(Get-DueStep -Schedule $s -Now (New-Time 16 59 45))
        $late[0].Step | Should Be 'skip-warn'
        $s.Count | Should Be 0
        @(Get-DueStep -Schedule $s -Now (New-Time 17 0 1)).Count | Should Be 0
    }
    It 'with GoLeadSeconds 15 warns at T0 - 30 s and goes at T0 - 15 s' {
        $s = [System.Collections.ArrayList]::new()
        Add-Meeting -Schedule $s -Start (New-Time 17 0) -Now (New-Time 16 46) | Should Be 'queued'
        @(Get-DueStep -Schedule $s -Now (New-Time 16 59 29) -GoLeadSeconds 15).Count | Should Be 0
        $warn = @(Get-DueStep -Schedule $s -Now (New-Time 16 59 31) -GoLeadSeconds 15)
        $warn[0].Step | Should Be 'warn'
        @(Get-DueStep -Schedule $s -Now (New-Time 16 59 40) -GoLeadSeconds 15).Count | Should Be 0
        $go = @(Get-DueStep -Schedule $s -Now (New-Time 16 59 46) -GoLeadSeconds 15)
        $go[0].Step | Should Be 'go'
        $go[0].Start | Should Be (New-Time 17 0)
        $s.Count | Should Be 0
    }
    It 'with GoLeadSeconds 15 skips a late go at T0 - 15 s + 11 s' {
        $s = [System.Collections.ArrayList]::new()
        [void](Add-Meeting -Schedule $s -Start (New-Time 17 0) -Now (New-Time 16 46))
        [void](Get-DueStep -Schedule $s -Now (New-Time 16 59 31) -GoLeadSeconds 15)
        $late = @(Get-DueStep -Schedule $s -Now (New-Time 16 59 56) -GoLeadSeconds 15)
        $late[0].Step | Should Be 'skip-go'
    }
    It 'skips a late go' {
        $s = [System.Collections.ArrayList]::new()
        [void](Add-Meeting -Schedule $s -Start (New-Time 17 0) -Now (New-Time 16 46))
        [void](Get-DueStep -Schedule $s -Now (New-Time 16 59 31))
        $late = @(Get-DueStep -Schedule $s -Now (New-Time 17 0 20))
        $late[0].Step | Should Be 'skip-go'
        $s.Count | Should Be 0
    }
}

Describe 'Test-Blocker' {
    It 'matches a blocker word in the title' {
        Test-Blocker -Title 'Blocker' -Words @('Blocker') | Should Be $true
    }
    It 'ignores letter case' {
        Test-Blocker -Title 'BLOCKER deep work' -Words @('blocker') | Should Be $true
    }
    It 'matches a part of the title' {
        Test-Blocker -Title 'Focus: Blocker for the report' -Words @('Blocker') | Should Be $true
    }
    It 'treats brackets in a word as plain text' {
        Test-Blocker -Title '[Blocker] study' -Words @('[Blocker]') | Should Be $true
        Test-Blocker -Title 'B study' -Words @('[Blocker]') | Should Be $false
    }
    It 'checks every word of the list' {
        Test-Blocker -Title 'Focus time' -Words @('Blocker', 'Focus') | Should Be $true
    }
    It 'lets an ordinary meeting through' {
        Test-Blocker -Title 'Weekly sync' -Words @('Blocker') | Should Be $false
    }
    It 'lets an empty title through' {
        Test-Blocker -Title '' -Words @('Blocker') | Should Be $false
        Test-Blocker -Title $null -Words @('Blocker') | Should Be $false
    }
    It 'blocks nothing without words' {
        Test-Blocker -Title 'Blocker' -Words @() | Should Be $false
        Test-Blocker -Title 'Blocker' -Words $null | Should Be $false
    }
    It 'never matches a blank word, so a stray space cannot silence every meeting' {
        Test-Blocker -Title 'Weekly sync' -Words @($null, '', ' ') | Should Be $false
    }
    It 'trims a word before matching' {
        Test-Blocker -Title '[Blocker] study' -Words @('Blocker ') | Should Be $true
    }
    It 'skips a word that is not a string' {
        Test-Blocker -Title 'Room 1 sync' -Words @(1) | Should Be $false
    }
}

Describe 'Get-BlockerWords' {
    It 'defaults to Blocker when the key is missing' {
        $config = '{"reminder_webhook_url":"http://x"}' | ConvertFrom-Json
        (@(Get-BlockerWords $config.blocker_words) -join '|') | Should Be 'Blocker'
    }
    It 'defaults to Blocker when the key is null' {
        $config = '{"blocker_words":null}' | ConvertFrom-Json
        (@(Get-BlockerWords $config.blocker_words) -join '|') | Should Be 'Blocker'
    }
    It 'turns blockers off with an empty list' {
        $config = '{"blocker_words":[]}' | ConvertFrom-Json
        @(Get-BlockerWords $config.blocker_words).Count | Should Be 0
    }
    It 'keeps non-blank words, trimmed, in order' {
        $config = '{"blocker_words":["Blocker"," ","Focus ",""]}' | ConvertFrom-Json
        (@(Get-BlockerWords $config.blocker_words) -join '|') | Should Be 'Blocker|Focus'
    }
    It 'reads a single string as one word' {
        $config = '{"blocker_words":"Blocker, Focus"}' | ConvertFrom-Json
        (@(Get-BlockerWords $config.blocker_words) -join '|') | Should Be 'Blocker, Focus'
    }
    It 'drops values that are not strings' {
        $config = '{"blocker_words":[1,["x"],{"a":"b"}]}' | ConvertFrom-Json
        @(Get-BlockerWords $config.blocker_words).Count | Should Be 0
    }
}
