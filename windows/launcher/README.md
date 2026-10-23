# Desk apps from main

The desk panel (`windows/desk-tray/`) and the meeting reminder (`windows/meeting-reminder.ps1`) run on the PC
from **main** of this repository. Every merged pull request that changes `windows/` is the next release: it
shows as an amber dot on the tray icon and on the panel's gear; a click asks once (No is the default), Yes
installs it. Nothing is tagged, signed or copied by hand.

```
 pull request merged on Forgejo ──mirror──> GitHub main ──git fetch (HTTPS)──> PC: %LOCALAPPDATA%\DeskApps\repo
 tray dot ─ Yes ─> Update-DeskApps.ps1 -Mode Prepare ─> releases\v<N> ─> state.json: pending
 panel exits 3 ─> Start-DeskApp.ps1 (the scheduled task) starts the new release; trial 60 s, else back
```

## Release names

A release is a commit on main, named `v<N>`: N is the number of commits on main's first-parent line that
changed `windows/` (`git rev-list --count --first-parent <commit> -- windows/`). It grows by one with every
merge that touches the PC apps; a merge that only changes Home Assistant or ESPHome files keeps the number and
lights no dot. The panel shows the name next to the gear.

## What it trusts

Main on the GitHub mirror, fetched over HTTPS without credentials. Main changes only through pull requests the
owner merges on Forgejo (branch protection), and GitHub gets it only from the Forgejo mirror. There is no
signature of its own: whoever can write to main on GitHub can run code on the PC. That is accepted for a personal
app with one user.
The release folder is created from the commit id seen at the check; at Yes the commit must still count as the
same `v<N>`.

## What a release may need: `windows/pc-manifest.json`

```json
{ "requires": { "launcher": 2, "pwsh": "7.4", "deps": "webview2-1.0.4258.31+dseg-0.46",
                "listen": "http://+:8765/desk/", "ha_api": 1,
                "config_keys": { "desk-tray": ["panel_webhook_url", "panel_stop_webhook_url", "push_token"],
                                 "meeting-reminder": ["reminder_webhook_url"] } } }
```

Before anything is written, every requirement is checked on the PC; one not met refuses the update and says
the manual step (for example: Exit the panel, then run `Install-DeskTrayDeps.ps1 -Root <DeskTray>` from the
new release). An unknown key is refused too, so an older updater never skips a requirement it does not know.
`ha_api` is the `"api"` that Home Assistant pushes (`homeassistant/rest_command/desk_panel_push.yaml`): the
Home Assistant part is deployed before the PC release that needs it.

## The starter

The scheduled tasks `desk-tray` and `meeting-reminder` run `Start-DeskApp.ps1 -App <name>`, which runs the app
from `releases\<current>\` with `-DataDir` (config.json, logs and libraries stay in `%LOCALAPPDATA%\DeskTray\`
and `%LOCALAPPDATA%\meeting-reminder\`) and decides what happens when it ends:

| The app ends | The starter |
|---|---|
| exit 3 (the panel after Yes) | applies the pending release and starts it; the first 60 s are its trial |
| exit 0 (Exit in the tray menu) | ends too, and the task with it |
| anything else within the trial | goes back to the previous release; the failed one is not offered again (the next merge is) |
| anything else after the trial | starts the same release again after 60 s, at most 3 times an hour, then stops |

The meeting reminder keeps its meetings in memory, so the starter restarts it for an update only while
`queue.json` says no meeting waits. One starter per app: a second one ends at once.
Logs: `%LOCALAPPDATA%\DeskApps\launcher.log` (starter) and `update.log` (checks and preparations).

## Install — once, by hand

1. Git for Windows (2.34 or newer): `winget install --id Git.Git`
2. Make sure the Home Assistant part pushes `"api": 1` (deploy `homeassistant/rest_command/desk_panel_push.yaml`).
3. From your own clone of the repository:

   ```powershell
   git pull
   pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\launcher\Install-DeskApps.ps1
   ```

   The first time it stops both apps, installs the panel libraries (`lib\deps.json`), installs the release,
   moves the old hand-copied scripts into `pre-launcher\`, points both scheduled tasks at the starter and starts
   them. It ends with the last lines of `launcher.log`: both apps `started v…`.
   Run again (a release is installed), it only refreshes the starter files and the tasks; a newer release then
   comes through the dot.

The starter itself, `DeskApps.psm1` and `Update-DeskApps.ps1` are updated only by hand (run
`Install-DeskApps.ps1` again); a release that needs a newer starter says so (`launcher`).

## Releasing

Merge the pull request. The PC sees it at the next check: a minute after the panel starts, then every 6 hours.
To see it at once: Exit in the tray menu, then `Start-ScheduledTask desk-tray`.

## Try the way back

Create `%LOCALAPPDATA%\DeskApps\simulate-crash` containing `desk-tray`, then install an update: its first
start counts as a crash, the starter goes back and `launcher.log` says so. The file is deleted when used.
The release that "failed" is not offered again; the next merge that changes `windows/` is.
