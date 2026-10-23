# Desk apps from signed releases

The desk panel (`windows/desk-tray/`) and the meeting reminder (`windows/meeting-reminder.ps1`) run on the PC
from **signed releases** of this repository. A new release shows as an amber dot on the tray icon and on the
panel's gear; a click asks once (No is the default), Yes installs it. Nothing is copied by hand any more.

```
 owner's clone ──git tag -s pc-vX.Y.Z──> Forgejo ──mirror──> GitHub ──git fetch (HTTPS)──> PC: %LOCALAPPDATA%\DeskApps\repo
                                                                                              │ git verify-tag (allowed_signers)
 tray dot ─ Yes ─> Update-DeskApps.ps1 -Mode Prepare ─> releases\pc-vX.Y.Z ─> state.json: pending
 panel exits 3 ─> Start-DeskApp.ps1 (the scheduled task) starts the new release; trial 60 s, else back
```

## Why it can be trusted

- **The owner's SSH signature is the anchor**, not GitHub. A release is a tag `pc-vX.Y.Z` signed with the
  owner's key; the PC accepts only tags that `git verify-tag` checks against `allowed_signers`, a file
  installed by hand that the updater never writes. From the signed tag, git's own hashes lead to every byte of
  every file (git with `fetch.fsckObjects`), so a changed file, a changed tree or an unsigned tag is refused.
- The check is pinned: the tag object and commit id seen at the check must be the same when the owner says
  Yes, hours later; the release folder is created from the commit id, not the tag name.
- The tag's own name, the ref name and `windows/pc-manifest.json` `version` must agree.
- Git runs without prompts or credential helpers, from `C:\Program Files\Git` by absolute path, with the
  `ssh-keygen` that ships with Git for Windows.

## What a release may need: `windows/pc-manifest.json`

```json
{ "version": "pc-v1.0.0",
  "requires": { "launcher": 1, "pwsh": "7.4", "deps": "webview2-1.0.4258.31+dseg-0.46",
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
| anything else within the trial | goes back to the previous release; the failed one is never offered again |
| anything else after the trial | starts the same release again after 60 s, at most 3 times an hour, then stops |

The meeting reminder keeps its meetings in memory, so the starter restarts it for an update only while
`queue.json` says no meeting waits. One starter per app: a second one ends at once.
Logs: `%LOCALAPPDATA%\DeskApps\launcher.log` (starter) and `update.log` (checks and preparations).

## Install — once, by hand

1. Git for Windows (2.34 or newer): `winget install --id Git.Git`
2. Make sure the Home Assistant part pushes `"api": 1` (deploy `homeassistant/rest_command/desk_panel_push.yaml`).
3. The owner signs the first release (below), so there is something to install.
4. From your own clone of the repository (where you reviewed this file; it decides which key the PC trusts):

   ```powershell
   pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\launcher\Install-DeskApps.ps1 -PublicKey "$HOME\.ssh\id_ed25519.pub"
   ```

   It stops both apps, installs the panel libraries (`lib\deps.json`), installs the release, moves the old
   hand-copied scripts into `pre-launcher\`, points both scheduled tasks at the starter and starts them. It
   ends with the last lines of `launcher.log`: both apps `started pc-v…`.

The starter itself, `DeskApps.psm1`, `Update-DeskApps.ps1` and `allowed_signers` are updated only by hand
(run `Install-DeskApps.ps1` again); a release that needs a newer starter says so (`launcher`).

## Releasing (owner)

Once, in your clone (the key you gave `Install-DeskApps.ps1 -PublicKey`):

```bash
git config gpg.format ssh
git config user.signingkey ~/.ssh/id_ed25519.pub
```

For each release, after the pull request that raises `windows/pc-manifest.json` `version` is merged
(`origin` = Forgejo):

```bash
git fetch origin
git show origin/main:windows/pc-manifest.json   # "version" must be pc-vX.Y.Z
git tag -s pc-vX.Y.Z origin/main -m pc-vX.Y.Z
git push origin pc-vX.Y.Z
```

If `git fetch` fails, stop: `origin/main` is then the old commit, the PC skips the tag (`skipped pc-vX.Y.Z` in
`update.log`) and the tag has to be deleted (`git tag -d`, `git push origin :refs/tags/pc-vX.Y.Z`) and signed again.

The mirror carries the tag to GitHub; the PC sees it at the next check (a minute after the panel starts,
then every 6 hours). Never move or re-use a published tag name for other content; publish a new version instead.

## Try the way back

Create `%LOCALAPPDATA%\DeskApps\simulate-crash` containing `desk-tray`, then install an update: its first
start counts as a crash, the starter goes back and `launcher.log` says so. The file is deleted when used.
