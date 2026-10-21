<#
.SYNOPSIS
  Desk panel in the Windows tray: live desk height, small steps, memory presets and stop, through Home Assistant.

.DESCRIPTION
  A tray icon opens a small dark panel (panel.html in WebView2) above the taskbar. Home Assistant pushes the
  desk state to this script (HTTP POST to http://+:8765/desk/ with a shared token); the panel shows it.
  Buttons go back to Home Assistant as webhooks on the LAN, each with a sequence number ("seq"):
    tap  up/down   {"cmd":"step","n":3}  - quick taps add up (up +1, down -1) into one move of n x 3 mm
    hold up/down   {"cmd":"hold_up"}     - to the nearest memory preset in that direction (one command)
    preset 1-4     {"cmd":"preset","n":2}
    stop           POST to the separate stop webhook; it also empties the queue
  Home Assistant decides whether a move is safe (homeassistant/automations/desk_panel_cmd.yaml), computes every
  target from its own readings (this script never sends a height) and pushes back the result for each seq.
  Presses wait in a queue of one item here: a refusal that passes with time (too soon, busy, move budget) keeps
  the item queued and it is sent again, quietly, as soon as it can go; the panel shows no messages. A hold or a
  preset replaces queued taps. An item that could not go out within 20 s is dropped, and hiding the panel
  empties the queue: the desk never moves on its own while nobody looks at the panel.
  The control box ignores stop during a move it runs itself: the handset is the only reliable stop.

  No Home Assistant token on the PC, no third-party agent, no MQTT.

.NOTES
  PowerShell 7.4 or newer (pwsh.exe, Windows only; its default single-threaded apartment is what WinForms
  needs). The meeting reminder stays on Windows PowerShell 5.1 for its WinRT notification listener; this
  panel needs no WinRT. panel.html is read by WebView2, not by PowerShell.
  Folder layout (%LOCALAPPDATA%\DeskTray\, see README.md):
    desk-tray.ps1, panel.html, config.json (not in any repository), desk-tray.log
    lib\webview2\...  and lib\fonts\DSEG7Modern-Bold.woff2   (Install-DeskTrayDeps.ps1)
    web\               panel.html and the font, copied on start (the only folder the page can read)
    wv2data\           WebView2 user data
  config.json:
    { "panel_webhook_url":      "http://192.0.2.10:8123/api/webhook/DESK_PANEL_WEBHOOK_ID",
      "panel_stop_webhook_url": "http://192.0.2.10:8123/api/webhook/DESK_PANEL_STOP_WEBHOOK_ID",
      "push_token":             "<the value of desk_panel_push_token in Home Assistant secrets.yaml>" }
  The log never contains the webhook URLs, the token or pushed data; only start/stop, panel open times,
  dropped commands and errors.
#>
#Requires -Version 7.4
#Requires -PSEdition Core
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$ListenPrefix = 'http://+:8765/desk/',
    [int]$HelloSeconds = 30,
    [int]$StaleSeconds = 90
)

$logPath = Join-Path $PSScriptRoot 'desk-tray.log'
$logMaxBytes = 512KB
$knownRefusals = @('locked', 'not_ready', 'busy', 'too_soon', 'budget', 'motor', 'reverse', 'limit', 'no_preset', 'here')
# Refusals that pass with time, and how many seconds to wait before the next try. Any other result drops the
# item (locked shows as the red dot; limit, no_preset and here cannot change by waiting).
$retryAfter = @{ too_soon = 1; busy = 1; not_ready = 3; budget = 3; motor = 3; reverse = 3 }
$settleMs = 700              # quiet time after the last tap before the summed step goes out
$queueMaxAgeSeconds = 20     # an item that could not go out for this long is dropped, not done late
$maxStep = 20                # taps per command (6 cm); more stay queued for the next one
$inv = [Globalization.CultureInfo]::InvariantCulture

function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path $logPath) -and (Get-Item $logPath).Length -ge $logMaxBytes) {
            Move-Item -Force -Path $logPath -Destination "$logPath.1"
        }
        Add-Content -Path $logPath -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message)
    }
    catch {
        # Logging must never stop the script.
    }
}

function Read-DeskTrayConfig {
    # Returns the config or throws a message that never quotes the file (it holds the token).
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "$Path not found" }
    try { $c = Get-Content -Raw -Path $Path | ConvertFrom-Json }
    catch { throw "$Path is not valid JSON" }
    foreach ($k in @('panel_webhook_url', 'panel_stop_webhook_url')) {
        $u = $null
        if (-not $c.$k -or -not [Uri]::TryCreate([string]$c.$k, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -notin 'http', 'https') {
            throw "$k missing or not an http(s) URL in $Path"
        }
    }
    if (-not $c.push_token -or ([string]$c.push_token).Length -lt 32) { throw "push_token missing or shorter than 32 characters in $Path" }
    $c
}

function Test-DeskToken {
    # Constant-time comparison, so the answer time does not leak how much of the token matched.
    param([string]$Given, [string]$Expected)
    if ([string]::IsNullOrEmpty($Expected) -or $null -eq $Given) { return $false }
    $a = [Text.Encoding]::UTF8.GetBytes($Given)
    $b = [Text.Encoding]::UTF8.GetBytes($Expected)
    $diff = $a.Length -bxor $b.Length
    for ($i = 0; $i -lt $b.Length; $i++) {
        $x = if ($i -lt $a.Length) { $a[$i] } else { 0 }
        $diff = $diff -bor ($x -bxor $b[$i])
    }
    $diff -eq 0
}

function ConvertTo-DeskNumber {
    # Home Assistant sends states as text ("85.0", "unavailable"). Returns a rounded number or $null.
    param($Value)
    $d = 0.0
    if ($null -ne $Value -and [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, $inv, [ref]$d) -and
        -not [double]::IsNaN($d) -and -not [double]::IsInfinity($d)) { return [math]::Round($d, 1) }
    $null
}

function ConvertFrom-DeskPush {
    # Validates a push from Home Assistant: {"h","status","m":[4],"locked","seq","result"}. Unknown values are
    # dropped, never passed to the page as they came.
    param([string]$Json)
    try { $p = $Json | ConvertFrom-Json } catch { return $null }
    if ($null -eq $p -or $p -isnot [pscustomobject]) { return $null }
    $status = [string]$p.status
    if ($status -notin 'Idle', 'Raising', 'Lowering') { $status = '' }
    $presets = @()
    $m = @($p.m)
    for ($i = 0; $i -lt [math]::Min($m.Count, 4); $i++) {
        $h = ConvertTo-DeskNumber $m[$i]
        if ($null -ne $h -and $h -gt 0) { $presets += [pscustomobject]@{ n = $i + 1; h = $h } }
    }
    $result = [string]$p.result
    if ($result -ne 'ok' -and $result -notin $knownRefusals) { $result = '' }
    $seq = 0
    $null = [int]::TryParse([string]$p.seq, [ref]$seq)
    [pscustomobject]@{
        h       = ConvertTo-DeskNumber $p.h
        status  = $status
        presets = $presets
        locked  = ([string]$p.locked -ne 'off')
        seq     = $seq
        result  = $result
    }
}

function Add-DeskPress {
    # Adds a button press to the queue (at most one queued item). Taps add up: up +1, down -1, so five quick
    # taps become one move of 1.5 cm, sent after $settleMs of quiet. A hold or a preset replaces whatever is
    # queued: the last decision wins. Anything else leaves the queue as it was.
    param($Queue, $Message, [datetime]$Now)
    switch ([string]$Message.type) {
        'tap' {
            if ($Message.dir -notin 'up', 'down') { return $Queue }
            $d = if ($Message.dir -eq 'up') { 1 } else { -1 }
            $notBefore = $Now.AddMilliseconds($settleMs)
            if ($Queue -and $Queue.kind -eq 'step') {
                if ($Queue.notBefore -gt $notBefore) { $notBefore = $Queue.notBefore }
                return @{ kind = 'step'; n = $Queue.n + $d; since = $Queue.since; notBefore = $notBefore }
            }
            return @{ kind = 'step'; n = $d; since = $Now; notBefore = $notBefore }
        }
        'hold' {
            if ($Message.dir -in 'up', 'down') { return @{ kind = 'hold'; dir = [string]$Message.dir; since = $Now; notBefore = $Now } }
        }
        'preset' {
            $n = 0
            if ([int]::TryParse([string]$Message.n, [ref]$n) -and $n -ge 1 -and $n -le 4) { return @{ kind = 'preset'; n = $n; since = $Now; notBefore = $Now } }
        }
    }
    $Queue
}

function Get-DeskSend {
    # What goes out now for the queued item: $null (nothing yet), @{ drop = $true } (too old, or taps that
    # cancelled out) or @{ body; item = what was sent; rest = what stays queued }.
    param($Queue, [datetime]$Now)
    if ($null -eq $Queue -or $Now -lt $Queue.notBefore) { return $null }
    if (($Now - $Queue.since).TotalSeconds -gt $queueMaxAgeSeconds) { return @{ drop = $true; why = 'too old' } }
    switch ($Queue.kind) {
        'step' {
            if ($Queue.n -eq 0) { return @{ drop = $true; why = '' } }
            $n = [math]::Max(-$maxStep, [math]::Min($maxStep, $Queue.n))
            $item = $Queue.Clone(); $item.n = $n
            $rest = $null
            if ($Queue.n -ne $n) { $rest = $Queue.Clone(); $rest.n = $Queue.n - $n }
            return @{ body = @{ cmd = 'step'; n = $n }; item = $item; rest = $rest }
        }
        'hold' { return @{ body = @{ cmd = "hold_$($Queue.dir)" }; item = $Queue; rest = $null } }
        'preset' { return @{ body = @{ cmd = 'preset'; n = $Queue.n }; item = $Queue; rest = $null } }
    }
    $null
}

function Merge-DeskResult {
    # The queue after Home Assistant answered for $Sent. "ok" or a final refusal: the queue stays as it is.
    # A refusal that passes with time: $Sent goes back - added to newer taps, or replaced by a newer hold or
    # preset - and the item waits $retryAfter seconds.
    param($Queue, $Sent, [string]$Result, [datetime]$Now)
    if (-not $retryAfter.ContainsKey($Result)) { return $Queue }
    if ($null -eq $Queue) { $q = $Sent.Clone() }
    elseif ($Queue.kind -eq 'step' -and $Sent.kind -eq 'step') { $q = $Queue.Clone(); $q.n = $Queue.n + $Sent.n; $q.since = $Sent.since }
    else { $q = $Queue.Clone() }
    $wait = $Now.AddSeconds($retryAfter[$Result])
    if ($q.notBefore -lt $wait) { $q.notBefore = $wait }
    $q
}

function Stop-OlderInstance {
    # The newest copy wins, as in meeting-reminder.ps1: an upgraded script replaces the old one.
    $scriptName = Split-Path -Leaf $PSCommandPath
    $self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
    $older = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*$scriptName*" -and
                       $_.CreationDate -lt $self.CreationDate }
    foreach ($p in $older) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Log "replaced older copy PID $($p.ProcessId)"
    }
}

function Start-Main {
    $ErrorActionPreference = 'Stop'
    try { $script:Config = Read-DeskTrayConfig $ConfigPath }
    catch { Write-Log "ERROR config: $($_.Exception.Message)"; exit 1 }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { Write-Log 'ERROR not an STA thread (do not start pwsh with -MTA)'; exit 1 }
    try { Stop-OlderInstance } catch { Write-Log "ERROR older copy check: $($_.Exception.Message)" }

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    # On .NET the WinForms and drawing types are split over several assemblies, and the split changes between
    # .NET versions (.NET 10 moved part of System.Drawing into System.Private.Windows.GdiPlus). So the compiler
    # gets what WinForms and System.Drawing depend on, found at run time: assemblies PowerShell ships as
    # reference assemblies ($PSHOME\ref) by name, the Windows Desktop ones (the folder of System.Windows.Forms)
    # by path. Anything else is left out.
    $inRef = @{}
    Get-ChildItem (Join-Path $PSHOME 'ref') -Filter *.dll -ErrorAction SilentlyContinue | ForEach-Object { $inRef[$_.BaseName] = $true }
    $desktopDir = Split-Path -Parent ([System.Windows.Forms.Form].Assembly.Location)
    $refs = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $queue = New-Object System.Collections.Generic.Queue[Reflection.Assembly]
    $queue.Enqueue([System.Windows.Forms.Form].Assembly)
    $queue.Enqueue([System.Drawing.Bitmap].Assembly)
    while ($queue.Count -gt 0) {
        $a = $queue.Dequeue()
        $n = $a.GetName().Name
        if ($seen.ContainsKey($n)) { continue }
        $seen[$n] = $true
        if ($inRef.ContainsKey($n)) { $refs.Add($n) }
        elseif ($a.Location -and (Split-Path -Parent $a.Location) -eq $desktopDir) { $refs.Add($a.Location) }
        foreach ($r in $a.GetReferencedAssemblies()) {
            if (-not $seen.ContainsKey($r.Name)) { try { $queue.Enqueue([Reflection.Assembly]::Load($r)) } catch { } }
        }
    }
    try {
    Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class DeskNative {
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr hmon, int type, out uint dpiX, out uint dpiY);
    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWCP_ROUND = 2, DWMWCP_ROUNDSMALL = 3;
    public static int SetDwmInt(IntPtr hwnd, int attr, int value) { return DwmSetWindowAttribute(hwnd, attr, ref value, 4); }
    public static uint DpiAtCursor() {
        POINT p; p.X = Cursor.Position.X; p.Y = Cursor.Position.Y;
        uint x, y;
        if (GetDpiForMonitor(MonitorFromPoint(p, 2), 0, out x, out y) == 0) return x;
        return 96;
    }
    // A small desk glyph for the tray: a light top and two legs.
    public static Icon DeskIcon(int size) {
        using (Bitmap b = new Bitmap(size, size)) {
            using (Graphics g = Graphics.FromImage(b)) {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                float u = size / 16f;
                using (SolidBrush top = new SolidBrush(Color.FromArgb(154, 216, 255)))
                using (SolidBrush leg = new SolidBrush(Color.FromArgb(230, 230, 230))) {
                    g.FillRectangle(top, 1 * u, 4 * u, 14 * u, 3 * u);
                    g.FillRectangle(leg, 3 * u, 7 * u, 2 * u, 7 * u);
                    g.FillRectangle(leg, 11 * u, 7 * u, 2 * u, 7 * u);
                }
            }
            IntPtr h = b.GetHicon();
            Icon i = (Icon)Icon.FromHandle(h).Clone();
            DestroyIcon(h);
            return i;
        }
    }
}

public class FlyoutForm : Form {
    protected override CreateParams CreateParams {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x00000080; return cp; }  // WS_EX_TOOLWINDOW
    }
}

public class DarkMenuColors : ProfessionalColorTable {
    static readonly Color Bg = Color.FromArgb(43, 43, 43);
    static readonly Color Hi = Color.FromArgb(61, 61, 61);
    static readonly Color Line = Color.FromArgb(64, 64, 64);
    public override Color ToolStripDropDownBackground { get { return Bg; } }
    public override Color ImageMarginGradientBegin { get { return Bg; } }
    public override Color ImageMarginGradientMiddle { get { return Bg; } }
    public override Color ImageMarginGradientEnd { get { return Bg; } }
    public override Color MenuBorder { get { return Line; } }
    public override Color MenuItemBorder { get { return Hi; } }
    public override Color MenuItemSelected { get { return Hi; } }
    public override Color SeparatorDark { get { return Line; } }
    public override Color SeparatorLight { get { return Line; } }
}

public class DarkMenuRenderer : ToolStripProfessionalRenderer {
    public DarkMenuRenderer() : base(new DarkMenuColors()) { RoundedEdges = false; }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        e.TextColor = e.Item.Enabled ? Color.FromArgb(242, 242, 242) : Color.FromArgb(120, 120, 120);
        base.OnRenderItemText(e);
    }
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        if (!e.Item.Selected || !e.Item.Enabled) { return; }
        Rectangle r = new Rectangle(4, 1, e.Item.Width - 8, e.Item.Height - 2);
        using (GraphicsPath p = new GraphicsPath())
        using (SolidBrush b = new SolidBrush(Color.FromArgb(61, 61, 61))) {
            int d = 8;
            p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.FillPath(b, p);
        }
    }
}
'@
    }
    catch {
        $errs = @($_.Exception.Errors | Select-Object -First 3 | ForEach-Object { $_.ToString() }) -join ' | '
        $byPath = @($refs | Where-Object { $_ -match '[\\/]' } | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
        Write-Log "ERROR compiling the window helpers (.NET $([Environment]::Version), by path: $byPath): $($_.Exception.Message) $errs"
        exit 1
    }
    # Per-monitor-v2 DPI for this thread, before any window exists.
    $null = [DeskNative]::SetThreadDpiAwarenessContext([IntPtr](-4))

    # WebView2: SDK from lib\webview2 (Install-DeskTrayDeps.ps1), loader matching this process.
    $lib = Join-Path $PSScriptRoot 'lib\webview2'
    try {
        Add-Type -Path (Join-Path $lib 'Microsoft.Web.WebView2.Core.dll')
        Add-Type -Path (Join-Path $lib 'Microsoft.Web.WebView2.WinForms.dll')
        $arch = if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() -eq 'Arm64') { 'arm64' }
                elseif ([Environment]::Is64BitProcess) { 'x64' } else { $null }
        if (-not $arch) { throw 'run the 64-bit pwsh.exe' }
        [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath((Join-Path $lib "runtimes\win-$arch\native"))
        $rt = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
    }
    catch {
        Write-Log "ERROR WebView2: $($_.Exception.Message) (run Install-DeskTrayDeps.ps1; WebView2 Runtime must be installed)"
        exit 1
    }

    # The page may read only web\: panel.html and the font, nothing else from this folder (config.json!).
    $script:WebRoot = Join-Path $PSScriptRoot 'web'
    $null = New-Item -ItemType Directory -Force -Path $script:WebRoot
    Copy-Item -Force -Path (Join-Path $PSScriptRoot 'panel.html') -Destination (Join-Path $script:WebRoot 'panel.html')
    $font = Join-Path $PSScriptRoot 'lib\fonts\DSEG7Modern-Bold.woff2'
    if (Test-Path $font) { Copy-Item -Force -Path $font -Destination $script:WebRoot }
    else { Write-Log 'WARN font missing: run Install-DeskTrayDeps.ps1 (the height shows in a plain font)' }

    $script:Clock = [Diagnostics.Stopwatch]::StartNew()
    $script:Wv = $null
    $script:Ready = $false
    $script:LastHideAt = [DateTime]::MinValue
    $script:TShow = 0
    $script:Desk = $null                         # last validated push
    $script:LastPushAt = [DateTime]::MinValue
    $script:LastHelloAt = [DateTime]::MinValue
    $script:Pending = New-Object System.Collections.ArrayList
    $script:Http = New-Object System.Net.Http.HttpClient
    $script:Http.Timeout = [TimeSpan]::FromSeconds(5)
    $script:Ctx = $null
    $script:HelloFailing = $false
    $script:StaleShown = $false
    $script:Queue = $null                        # the one press waiting to go out (Add-DeskPress)
    $script:InFlight = $null                     # @{ seq; item; at } sent, no result yet
    $script:Seq = 0
    $script:LastSendFailedAt = [DateTime]::MinValue  # red light on the panel for 30 s after a failed send

    function script:Send-ToPage([hashtable]$Obj) {
        if ($script:Wv -and $script:Ready) {
            try { $script:Wv.CoreWebView2.PostWebMessageAsJson((ConvertTo-Json -InputObject $Obj -Compress -Depth 5)) }
            catch { Write-Log "ERROR page message: $($_.Exception.Message)" }
        }
    }

    function script:Send-State {
        $stale = ($null -eq $script:Desk) -or (([DateTime]::UtcNow - $script:LastPushAt).TotalSeconds -gt $StaleSeconds)
        $d = $script:Desk
        $offline = $script:HelloFailing -or (([DateTime]::UtcNow - $script:LastSendFailedAt).TotalSeconds -lt 30)
        Send-ToPage @{
            type = 'state'; stale = $stale; offline = $offline
            h = $(if ($d) { $d.h } else { $null }); status = $(if ($d) { $d.status } else { '' })
            presets = $(if ($d) { @($d.presets) } else { @() }); locked = $(if ($d) { $d.locked } else { $false })
        }
    }

    function script:Send-Webhook([string]$Kind, [hashtable]$Body) {
        # Fire and forget on the UI thread: the task is checked by the timer; the URL is never logged.
        $url = if ($Kind -eq 'stop') { $script:Config.panel_stop_webhook_url } else { $script:Config.panel_webhook_url }
        $json = ConvertTo-Json -InputObject $Body -Compress
        try {
            $content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')
            $null = $script:Pending.Add(@{ what = $(if ($Body.cmd) { $Body.cmd } else { $Kind }); seq = $Body.seq; task = $script:Http.PostAsync($url, $content) })
        }
        catch { Write-Log "ERROR send $Kind`: $($_.Exception.Message)" }
    }

    function script:Send-Queue {
        # Tells the page what is waiting, so the arrow or preset stays lit until it went out.
        $n = 0; $hold = ''; $preset = 0
        foreach ($i in @($script:Queue, $(if ($script:InFlight) { $script:InFlight.item }))) {
            if ($null -eq $i) { continue }
            switch ($i.kind) { 'step' { $n += $i.n } 'hold' { $hold = $i.dir } 'preset' { $preset = $i.n } }
        }
        Send-ToPage @{ type = 'queue'; up = ($n -gt 0 -or $hold -eq 'up'); down = ($n -lt 0 -or $hold -eq 'down'); preset = $preset }
    }

    function script:Complete-InFlight([string]$Result) {
        $sent = $script:InFlight.item
        $script:InFlight = $null
        if ($Result -ne 'ok' -and -not $retryAfter.ContainsKey($Result)) { Write-Log "command dropped: $($sent.kind) ($Result)" }
        $script:Queue = Merge-DeskResult $script:Queue $sent $Result ([DateTime]::UtcNow)
        Send-Queue
    }

    function script:Send-Hello {
        $script:LastHelloAt = [DateTime]::UtcNow
        Send-Webhook 'cmd' @{ cmd = 'hello' }
    }

    function script:Invoke-PushRequest($Ctx) {
        $req = $Ctx.Request; $resp = $Ctx.Response
        try {
            if ($req.HttpMethod -ne 'POST') { $resp.StatusCode = 405; return }
            if (-not (Test-DeskToken $req.Headers['X-Desk-Token'] $script:Config.push_token)) {
                $resp.StatusCode = 401
                Write-Log "push refused: bad or missing token from $($req.RemoteEndPoint.Address)"
                return
            }
            if ($req.ContentLength64 -gt 4096) { $resp.StatusCode = 413; return }
            $reader = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd(); $reader.Close()
            $push = ConvertFrom-DeskPush $body
            if ($null -eq $push) { $resp.StatusCode = 400; Write-Log 'push refused: not valid JSON'; return }
            $script:Desk = $push; $script:LastPushAt = [DateTime]::UtcNow
            Send-State
            if ($push.seq -gt 0 -and $push.result -and $script:InFlight -and $push.seq -eq $script:InFlight.seq) { Complete-InFlight $push.result }
            $resp.StatusCode = 204
        }
        catch { $resp.StatusCode = 500; Write-Log "ERROR push: $($_.Exception.Message)" }
        finally { try { $resp.Close() } catch { } }
    }

    function script:Stop-Desk([string]$Why) {
        Write-Log "stop ($Why)"
        Send-Webhook 'stop' @{}
    }

    # ------------------------------------------------------------------ page -> PowerShell
    $onMessage = {
        param($sender, $e)
        try {
            $m = $e.WebMessageAsJson | ConvertFrom-Json
            switch ([string]$m.type) {
                'ready' {
                    $script:Ready = $true
                    Write-Log ('panel ready {0} ms after open' -f ($script:Clock.ElapsedMilliseconds - $script:TShow))
                    Send-State
                }
                'hide' { Hide-Flyout 'hide button' }
                'stop' {
                    $script:Queue = $null; $script:InFlight = $null
                    Stop-Desk 'red button'
                    Send-Queue
                }
                default {
                    $script:Queue = Add-DeskPress $script:Queue $m ([DateTime]::UtcNow)
                    Send-Queue
                }
            }
        }
        catch { Write-Log "ERROR page handler: $($_.Exception.Message)" }
    }

    # ------------------------------------------------------------------ window + WebView2
    $script:Form = New-Object FlyoutForm
    $script:Form.FormBorderStyle = 'None'
    $script:Form.ShowInTaskbar = $false
    $script:Form.TopMost = $true
    $script:Form.StartPosition = 'Manual'
    $script:Form.AutoScaleMode = 'None'
    $script:Form.BackColor = [System.Drawing.Color]::FromArgb(32, 34, 39)

    function script:New-WebView {
        $script:Ready = $false
        $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
        $wv.Dock = 'Fill'
        $cp = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
        $cp.UserDataFolder = Join-Path $PSScriptRoot 'wv2data'
        $wv.CreationProperties = $cp
        $wv.DefaultBackgroundColor = [System.Drawing.Color]::FromArgb(255, 32, 34, 39)
        $wv.add_CoreWebView2InitializationCompleted({
            param($sender, $e)
            if (-not $e.IsSuccess) { Write-Log ("ERROR WebView2 init: " + $e.InitializationException.Message); return }
            $c = $sender.CoreWebView2
            $c.Settings.AreDefaultContextMenusEnabled = $false
            $c.Settings.AreDevToolsEnabled = $false
            $c.Settings.IsStatusBarEnabled = $false
            $c.Settings.IsZoomControlEnabled = $false
            $c.Settings.AreBrowserAcceleratorKeysEnabled = $false
            $c.add_WebMessageReceived($onMessage)
            # The page stays on its own virtual host; links and redirects elsewhere are cancelled.
            $c.add_NavigationStarting({ param($s2, $e2) if (-not $e2.Uri.StartsWith('https://desk.tray/')) { $e2.Cancel = $true; Write-Log 'navigation blocked' } })
            $c.add_NewWindowRequested({ param($s2, $e2) $e2.Handled = $true })
            $c.add_ProcessFailed({
                param($s2, $e2)
                Write-Log "ERROR WebView2 process failed: $($e2.ProcessFailedKind)"
                $script:Ready = $false
                Hide-Flyout 'page failed'
                # Rebuilt on the next open.
                try { $script:Form.Controls.Remove($script:Wv); $script:Wv.Dispose() } catch { }
                $script:Wv = $null
            })
            $c.SetVirtualHostNameToFolderMapping('desk.tray', $script:WebRoot, [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::DenyCors)
            $c.Navigate('https://desk.tray/panel.html')
        })
        $script:Form.Controls.Add($wv)
        $script:Wv = $wv
        $null = $wv.EnsureCoreWebView2Async($null)   # not awaited: completion arrives as the event above
    }

    function script:Set-FlyoutBounds {
        $scale = [DeskNative]::DpiAtCursor() / 96.0
        $w = [int](500 * $scale); $h = [int](160 * $scale); $m = [int](12 * $scale)
        $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
        $script:Form.Bounds = New-Object System.Drawing.Rectangle(($wa.Right - $w - $m), ($wa.Bottom - $h - $m), $w, $h)
    }

    $script:Form.add_HandleCreated({
        $null = [DeskNative]::SetDwmInt($script:Form.Handle, [DeskNative]::DWMWA_WINDOW_CORNER_PREFERENCE, [DeskNative]::DWMWCP_ROUND)
        $null = [DeskNative]::SetDwmInt($script:Form.Handle, [DeskNative]::DWMWA_USE_IMMERSIVE_DARK_MODE, 1)
    })

    function script:Show-Flyout([string]$Why) {
        $script:TShow = $script:Clock.ElapsedMilliseconds
        Set-FlyoutBounds
        $script:Form.Show()
        $script:Form.Activate()
        $null = [DeskNative]::SetForegroundWindow($script:Form.Handle)
        if (-not $script:Wv) { New-WebView }
        elseif ($script:Ready) { try { $script:Wv.CoreWebView2.MemoryUsageTargetLevel = 'Normal' } catch { } }
        Send-ToPage @{ type = 'shown' }
        Send-State
        Write-Log ('panel shown ({0}) in {1} ms' -f $Why, ($script:Clock.ElapsedMilliseconds - $script:TShow))
    }

    function script:Hide-Flyout([string]$Why) {
        if (-not $script:Form.Visible) { return }
        # Nothing waits while the panel is hidden: a queued move must not start when nobody is looking.
        if ($script:Queue) { $script:Queue = $null; Send-Queue }
        Send-ToPage @{ type = 'hidden' }
        $script:Form.Hide()
        $script:LastHideAt = [DateTime]::UtcNow
        if ($script:Ready) { try { $script:Wv.CoreWebView2.MemoryUsageTargetLevel = 'Low' } catch { } }
    }

    function script:Invoke-Later([int]$Ms, [scriptblock]$Action) {
        $t = New-Object System.Windows.Forms.Timer
        $t.Interval = $Ms
        $t.Tag = $Action
        $t.add_Tick({ param($s, $e) $s.Stop(); $a = $s.Tag; $s.Dispose(); & $a })
        $t.Start()
    }

    $script:Form.add_Deactivate({ Hide-Flyout 'focus lost' })

    # ------------------------------------------------------------------ tray icon + dark menu
    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    $script:Tray.Icon = [DeskNative]::DeskIcon([System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
    $script:Tray.Text = 'Desk'
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Renderer = New-Object DarkMenuRenderer
    $menu.ShowImageMargin = $false
    $menu.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $menu.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 4)
    # Open later than the click, so the closing menu does not take the focus from the new panel.
    $null = $menu.Items.Add('Open app', $null, { Invoke-Later 80 { Show-Flyout 'menu' } })
    $null = $menu.Items.Add('Cancel', $null, { $script:Queue = $null; $script:InFlight = $null; Stop-Desk 'menu Cancel'; Send-Queue })
    $null = $menu.Items.Add('Exit', $null, { [System.Windows.Forms.Application]::ExitThread() })
    foreach ($it in $menu.Items) { $it.ForeColor = [System.Drawing.Color]::FromArgb(242, 242, 242); $it.Padding = New-Object System.Windows.Forms.Padding(8, 6, 24, 6) }
    $menu.add_Opened({ param($s, $e) $null = [DeskNative]::SetDwmInt($s.Handle, [DeskNative]::DWMWA_WINDOW_CORNER_PREFERENCE, [DeskNative]::DWMWCP_ROUNDSMALL) })
    $script:Tray.ContextMenuStrip = $menu
    $script:Tray.add_MouseClick({
        param($s, $e)
        if ($e.Button -ne 'Left') { return }
        # The mouse-down on the taskbar already hid the panel (focus lost); the same click must not reopen it.
        if (([DateTime]::UtcNow - $script:LastHideAt).TotalMilliseconds -lt 300) { return }
        if ($script:Form.Visible) { Hide-Flyout 'tray click' } else { Show-Flyout 'tray click' }
    })
    $script:Tray.Visible = $true

    # ------------------------------------------------------------------ push listener (no background threads)
    # One pending GetContextAsync at a time; the timer below checks it. The older copy may still hold the port
    # for a moment after it was ended, so binding is retried.
    $script:Listener = New-Object System.Net.HttpListener
    $script:Listener.Prefixes.Add($ListenPrefix)
    for ($i = 1; $i -le 5; $i++) {
        try { $script:Listener.Start(); break }
        catch {
            if ($i -eq 5) {
                Write-Log "ERROR listener $ListenPrefix`: $($_.Exception.Message) (run Set-DeskTrayFirewall.ps1)"
                $script:Tray.ShowBalloonTip(10000, 'Desk', 'No live height: run Set-DeskTrayFirewall.ps1 once (see README).', 'Warning')
                $script:Listener = $null
            }
            else { Start-Sleep -Seconds 1 }
        }
    }

    $tick = New-Object System.Windows.Forms.Timer
    $tick.Interval = 100
    $tick.add_Tick({
        if ($script:Listener) {
            try {
                if ($null -eq $script:Ctx) { $script:Ctx = $script:Listener.GetContextAsync() }
                if ($script:Ctx.IsCompleted) {
                    $t = $script:Ctx; $script:Ctx = $null
                    if ($t.Status -eq 'RanToCompletion') { Invoke-PushRequest $t.Result }
                    else { Write-Log "ERROR listener: $($t.Exception.InnerException.Message)" }
                }
            }
            catch { Write-Log "ERROR listener: $($_.Exception.Message)"; $script:Ctx = $null }
        }
        for ($i = $script:Pending.Count - 1; $i -ge 0; $i--) {
            $p = $script:Pending[$i]
            if (-not $p.task.IsCompleted) { continue }
            $script:Pending.RemoveAt($i)
            if ($p.task.Status -ne 'RanToCompletion') {
                $script:LastSendFailedAt = [DateTime]::UtcNow
                Send-State
                if ($p.what -ne 'hello') {
                    Write-Log "ERROR $($p.what): Home Assistant not reachable"
                    # Not sent, so not done: drop it rather than move the desk late.
                    if ($p.seq -and $script:InFlight -and $script:InFlight.seq -eq $p.seq) { $script:InFlight = $null; Send-Queue }
                }
                elseif (-not $script:HelloFailing) { Write-Log 'ERROR hello: Home Assistant not reachable (logged once until it answers)' }
                if ($p.what -eq 'hello') { $script:HelloFailing = $true }
            }
            elseif (-not $p.task.Result.IsSuccessStatusCode) {
                Write-Log "ERROR $($p.what): HTTP $([int]$p.task.Result.StatusCode)"
                $script:LastSendFailedAt = [DateTime]::UtcNow
                Send-State
            }
            elseif ($p.what -eq 'hello' -and $script:HelloFailing) { $script:HelloFailing = $false; Write-Log 'hello: Home Assistant answers again' }
        }
        # The queue: one command in flight at a time. No result within 6 s means the push got lost; the command
        # is dropped, not repeated, because Home Assistant may have done it already.
        $now = [DateTime]::UtcNow
        if ($script:InFlight -and ($now - $script:InFlight.at).TotalSeconds -gt 6) {
            Write-Log "command dropped: $($script:InFlight.item.kind) (no result from Home Assistant)"
            $script:InFlight = $null; Send-Queue
        }
        if (-not $script:InFlight) {
            $s = Get-DeskSend $script:Queue $now
            if ($s -and $s.drop) {
                if ($s.why) { Write-Log "command dropped: $($script:Queue.kind) ($($s.why))" }
                $script:Queue = $null; Send-Queue
            }
            elseif ($s) {
                $script:Seq++
                $s.body.seq = $script:Seq
                $script:InFlight = @{ seq = $script:Seq; item = $s.item; at = $now }
                $script:Queue = $s.rest
                Send-Webhook 'cmd' $s.body
            }
        }
        if (($now - $script:LastHelloAt).TotalSeconds -ge $HelloSeconds) { Send-Hello }
        # Mark the height stale once, when the pushes stop.
        $stale = ($null -ne $script:Desk) -and (([DateTime]::UtcNow - $script:LastPushAt).TotalSeconds -gt $StaleSeconds)
        if ($stale -and -not $script:StaleShown) { Send-State; Write-Log 'no push for 90 s' }
        $script:StaleShown = $stale
    })
    $tick.Start()

    Write-Log "start: WebView2 Runtime $rt, listener=$([bool]$script:Listener)"
    Send-Hello
    try { [System.Windows.Forms.Application]::Run() }
    finally {
        $tick.Stop()
        if ($script:Listener) { try { $script:Listener.Stop(); $script:Listener.Close() } catch { } }
        $script:Tray.Visible = $false; $script:Tray.Dispose()
        if ($script:Wv) { $script:Wv.Dispose() }
        $script:Http.Dispose()
        Write-Log 'stop'
    }
}

# Dot-sourcing (tests) only defines the functions above; running the file starts the tray.
if ($MyInvocation.InvocationName -ne '.') { Start-Main }
