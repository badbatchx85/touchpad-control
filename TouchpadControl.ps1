<#
.SYNOPSIS
  Touchpad Control - separate settings for an external touchpad and the built-in one on Windows.

.DESCRIPTION
  Windows keeps a single set of Precision Touchpad settings that applies to every touchpad. If you use
  an external touchpad (Apple Magic Trackpad, ProtoArc T1, ...) next to your laptop's own pad, you
  usually want different tap sensitivity, cursor speed or tap-and-drag on each.

  Touchpad Control keeps two profiles, "external" and "builtin", and switches them live through
  SystemParametersInfo(SPI_SETTOUCHPADPARAMETERS) whenever the external touchpad connects or
  disconnects. A notification-area icon (blue = external active, grey = built-in active) lets you
  pick the external device and edit either profile, even the one that is not active.

  Changes made in Settings > Bluetooth & devices > Touchpad are saved into the active profile.

  Settings live in %APPDATA%\TouchpadControl.

.EXAMPLE
  .\TouchpadControl.ps1 install           # register a logon task that runs the tray app, start it now
  .\TouchpadControl.ps1 tray              # run the tray app in this session only
  .\TouchpadControl.ps1 status            # connection state, live settings and both profiles
  .\TouchpadControl.ps1 apply builtin     # apply a profile now
  .\TouchpadControl.ps1 save external     # store the live settings into a profile
  .\TouchpadControl.ps1 uninstall         # remove the logon task and restore the original settings
#>
param(
    [Parameter(Position = 0)][ValidateSet('tray', 'status', 'apply', 'save', 'install', 'uninstall')]
    [string]$Command = 'tray',
    [Parameter(Position = 1)][ValidateSet('external', 'builtin')]
    [string]$Name
)

$ErrorActionPreference = 'Stop'
$DataDir      = Join-Path $env:APPDATA 'TouchpadControl'
$ProfilesPath = Join-Path $DataDir 'profiles.json'
$DevicePath   = Join-Path $DataDir 'device.json'
$BackupPath   = Join-Path $DataDir 'original-settings.json'
$LogPath      = Join-Path $DataDir 'touchpad-control.log'
$TaskName     = 'Touchpad Control'
$PollSeconds  = 3
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

Add-Type @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct TOUCHPAD_PARAMETERS {
    public uint versionNumber;
    public uint maxSupportedContacts;
    public uint legacyTouchpadFeatures;
    public uint flags1;            // read-only status bits
    public uint flags2;            // user setting bits
    public uint sensitivityLevel;  // 0 most sensitive .. 3 low sensitivity
    public uint cursorSpeed;       // 1..20
    public uint feedbackIntensity;
    public uint clickForceSensitivity;
    public uint rightClickZoneWidth;
    public uint rightClickZoneHeight;
}

[StructLayout(LayoutKind.Sequential)]
public struct DEVPROPKEY { public Guid fmtid; public uint pid; }

public static class TouchpadNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(uint action, uint uiParam, ref TOUCHPAD_PARAMETERS p, uint winIni);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Locate_DevNodeW(out uint devInst, string deviceId, uint flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_DevNode_PropertyW(uint devInst, ref DEVPROPKEY key, out uint type, byte[] buffer, ref uint size, uint flags);

    // Bluetooth devices keep a device node while disconnected, so ask DEVPKEY_Device_IsConnected
    // {83DA6326-97A6-4088-9453-A1923F573B29},15. Devices without that property (USB) count as
    // connected while their device node is present.
    public static bool IsConnected(string deviceId) {
        uint devInst;
        if (CM_Locate_DevNodeW(out devInst, deviceId, 1 /* CM_LOCATE_DEVNODE_PHANTOM */) != 0) return false;
        var key = new DEVPROPKEY { fmtid = new Guid("83DA6326-97A6-4088-9453-A1923F573B29"), pid = 15 };
        uint type; uint size = 1; var buf = new byte[1];
        if (CM_Get_DevNode_PropertyW(devInst, ref key, out type, buf, ref size, 0) == 0) return buf[0] != 0;
        return CM_Locate_DevNodeW(out devInst, deviceId, 0 /* CM_LOCATE_DEVNODE_NORMAL */) == 0;
    }
}
'@

$SPI_GET = 0xAE; $SPI_SET = 0xAF
$SPIF_UPDATEINIFILE_SENDCHANGE = 3
# Bit positions inside flags2
$Bits = [ordered]@{
    allowActiveWhenMousePresent = 0; tapEnabled = 2; tapAndDragEnabled = 3; twoFingerTapEnabled = 4
    rightClickZoneEnabled = 5; mouseAccelSettingHonored = 6; panEnabled = 7; zoomEnabled = 8
    scrollDirectionReversed = 9
}

function Write-Log($msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
}

function Get-RawParams {
    $p = New-Object TOUCHPAD_PARAMETERS
    $p.versionNumber = 1
    if (-not [TouchpadNative]::SystemParametersInfo($SPI_GET, [Runtime.InteropServices.Marshal]::SizeOf($p), [ref]$p, 0)) {
        throw "SPI_GETTOUCHPADPARAMETERS failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())). Is there a Precision Touchpad?"
    }
    $p
}

function ConvertTo-Settings($p) {
    $s = [ordered]@{ cursorSpeed = [int]$p.cursorSpeed; sensitivityLevel = [int]$p.sensitivityLevel }
    foreach ($k in $Bits.Keys) { $s[$k] = [bool]($p.flags2 -band (1 -shl $Bits[$k])) }
    [pscustomobject]$s
}

function Get-LiveSettings { ConvertTo-Settings (Get-RawParams) }

function Set-LiveSettings($s) {
    $p = Get-RawParams
    $p.cursorSpeed      = [uint32][Math]::Min(20, [Math]::Max(1, [int]$s.cursorSpeed))
    $p.sensitivityLevel = [uint32][Math]::Min(3, [Math]::Max(0, [int]$s.sensitivityLevel))
    foreach ($k in $Bits.Keys) {
        if ($null -eq $s.$k) { continue }
        $mask = [uint32](1 -shl $Bits[$k])
        if ($s.$k) { $p.flags2 = $p.flags2 -bor $mask } else { $p.flags2 = $p.flags2 -band (-bnot $mask) }
    }
    if (-not [TouchpadNative]::SystemParametersInfo($SPI_SET, [Runtime.InteropServices.Marshal]::SizeOf($p), [ref]$p, $SPIF_UPDATEINIFILE_SENDCHANGE)) {
        throw "SPI_SETTOUCHPADPARAMETERS failed (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
}

# First run: back up the current settings and start both profiles from them.
function Initialize-Data {
    if (-not (Test-Path $BackupPath)) { Get-LiveSettings | ConvertTo-Json | Set-Content $BackupPath -Encoding UTF8 }
    if (-not (Test-Path $ProfilesPath)) {
        $live = Get-LiveSettings
        Save-Profiles ([pscustomobject]@{ external = $live; builtin = $live.PSObject.Copy() })
    }
}

function Get-Profiles {
    Initialize-Data
    Get-Content $ProfilesPath -Raw | ConvertFrom-Json
}

function Save-Profiles($profiles) { $profiles | ConvertTo-Json -Depth 4 | Set-Content -Path $ProfilesPath -Encoding UTF8 }

function Save-LiveInto($name) {
    $profiles = Get-Profiles
    $profiles.$name = Get-LiveSettings
    Save-Profiles $profiles
}

function Use-Profile($name) { Set-LiveSettings (Get-Profiles).$name }

function Set-ProfileValue($name, $key, $value) {
    $profiles = Get-Profiles
    $profiles.$name.$key = $value
    Save-Profiles $profiles
    if ($name -eq $script:current) { Set-LiveSettings $profiles.$name }
}

function Get-Device {
    if (Test-Path $DevicePath) { Get-Content $DevicePath -Raw | ConvertFrom-Json }
}

function Set-Device($id, $friendlyName) {
    [pscustomobject]@{ id = $id; name = $friendlyName } | ConvertTo-Json | Set-Content $DevicePath -Encoding UTF8
    Write-Log "External touchpad set to '$friendlyName' ($id)."
}

function Test-ExternalConnected {
    $d = Get-Device
    $d -and [TouchpadNative]::IsConnected($d.id)
}

# Paired Bluetooth devices: the usual way an external touchpad is attached
function Get-PairedDevices {
    Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '^(BTHLE|BTHENUM)\\DEV_' -and $_.FriendlyName } |
        Sort-Object FriendlyName
}

# Apply the right profile when the external touchpad comes or goes. Returns $true on a switch.
function Sync-Device {
    $target = if (Test-ExternalConnected) { 'external' } else { 'builtin' }
    if ($target -eq $script:current) { return $false }
    if ($script:current) { Save-LiveInto $script:current }   # remember tweaks made while that profile was active
    Use-Profile $target
    Write-Log "Applied '$target' profile."
    $script:current = $target
    $true
}

# Same order and wording as Settings > Touchpad > Taps
$SensitivityNames = 'Most sensitive', 'High sensitivity', 'Medium sensitivity', 'Low sensitivity'
$ToggleNames = [ordered]@{
    tapEnabled = 'Tap to click'; tapAndDragEnabled = 'Tap twice and drag'
    twoFingerTapEnabled = 'Two-finger tap to right-click'; rightClickZoneEnabled = 'Press lower-right corner to right-click'
    scrollDirectionReversed = 'Reverse scroll direction'; zoomEnabled = 'Pinch to zoom'
    allowActiveWhenMousePresent = 'Leave on when a mouse is connected'
}

function Get-ProfileLabel($name) {
    if ($name -eq 'builtin') { return 'Built-in touchpad' }
    $d = Get-Device
    if ($d) { $d.name } else { 'External touchpad' }
}

function New-TrayIcon($active) {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $r = 8; $x = 2; $y = 5; $w = 28; $h = 22
    $path.AddArc($x, $y, $r, $r, 180, 90); $path.AddArc($x + $w - $r, $y, $r, $r, 270, 90)
    $path.AddArc($x + $w - $r, $y + $h - $r, $r, $r, 0, 90); $path.AddArc($x, $y + $h - $r, $r, $r, 90, 90)
    $path.CloseFigure()
    $fill = if ($active -eq 'external') { [Drawing.Color]::FromArgb(0, 120, 212) } else { [Drawing.Color]::FromArgb(128, 128, 128) }
    $g.FillPath((New-Object Drawing.SolidBrush $fill), $path)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), 2
    $g.DrawLine($pen, 2, 19, 30, 19)    # button strip
    $g.DrawLine($pen, 16, 19, 16, 27)
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Update-Tray {
    $script:tray.Icon = New-TrayIcon $script:current
    $text = "Touchpad Control: $(Get-ProfileLabel $script:current) profile"
    $script:tray.Text = $text.Substring(0, [Math]::Min(63, $text.Length))   # NotifyIcon.Text limit
}

function New-MenuItem($text, $checked, $tag) {
    $item = New-Object Windows.Forms.ToolStripMenuItem $text
    $item.Checked = [bool]$checked
    if ($tag) { $item.Tag = $tag; $item.add_Click($script:onPick) }
    $item
}

function Add-DeviceMenu($menu) {
    $d = Get-Device
    $pick = New-MenuItem $(if ($d) { 'Change external touchpad' } else { 'Choose external touchpad...' })
    [void]$pick.DropDownItems.Add((New-MenuItem 'Loading...'))   # placeholder so the arrow shows
    $pick.add_DropDownOpening({
        $this.DropDownItems.Clear()
        $d = Get-Device
        $devices = @(Get-PairedDevices)
        if (-not $devices) { $none = New-MenuItem 'No paired Bluetooth devices'; $none.Enabled = $false; [void]$this.DropDownItems.Add($none) }
        foreach ($dev in $devices) {
            [void]$this.DropDownItems.Add((New-MenuItem $dev.FriendlyName ($d -and $d.id -eq $dev.InstanceId) @{ Device = $dev.InstanceId; DeviceName = $dev.FriendlyName }))
        }
    })
    [void]$menu.Items.Add($pick)
}

function Build-Menu($menu) {
    # Pick up changes made in Windows Settings before showing the active profile's values
    if ($script:current) { Save-LiveInto $script:current }
    $profiles = Get-Profiles
    $menu.Items.Clear()
    $header = New-MenuItem "Active: $(Get-ProfileLabel $script:current)"
    $header.Enabled = $false
    [void]$menu.Items.Add($header)
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    foreach ($name in 'external', 'builtin') {
        $p = $profiles.$name
        $label = (Get-ProfileLabel $name) + $(if ($name -eq $script:current) { '  (active)' } else { '' })
        $sub = New-MenuItem $label
        $sens = New-MenuItem 'Tap sensitivity'
        for ($i = 0; $i -lt $SensitivityNames.Count; $i++) {
            [void]$sens.DropDownItems.Add((New-MenuItem $SensitivityNames[$i] ($p.sensitivityLevel -eq $i) @{ Profile = $name; Key = 'sensitivityLevel'; Value = $i }))
        }
        $speed = New-MenuItem "Cursor speed ($($p.cursorSpeed))"
        foreach ($i in 1..20) {
            [void]$speed.DropDownItems.Add((New-MenuItem "$i" ($p.cursorSpeed -eq $i) @{ Profile = $name; Key = 'cursorSpeed'; Value = $i }))
        }
        [void]$sub.DropDownItems.Add($sens)
        [void]$sub.DropDownItems.Add($speed)
        [void]$sub.DropDownItems.Add((New-Object Windows.Forms.ToolStripSeparator))
        foreach ($key in $ToggleNames.Keys) {
            [void]$sub.DropDownItems.Add((New-MenuItem $ToggleNames[$key] $p.$key @{ Profile = $name; Key = $key; Value = -not $p.$key }))
        }
        [void]$menu.Items.Add($sub)
    }
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    Add-DeviceMenu $menu
    $open = New-MenuItem 'Open Windows touchpad settings'
    $open.add_Click({ Start-Process 'ms-settings:devices-touchpad' })
    [void]$menu.Items.Add($open)
    $exit = New-MenuItem 'Exit'
    $exit.add_Click({ $script:tray.Visible = $false; [Windows.Forms.Application]::Exit() })
    [void]$menu.Items.Add($exit)
}

switch ($Command) {
    'status' {
        $d = Get-Device
        if ($d) { "External touchpad: $($d.name) - connected: $(Test-ExternalConnected)" } else { 'External touchpad: not chosen yet' }
        "`nLive settings:"; Get-LiveSettings | Format-List | Out-String
        'Profiles:'; Get-Profiles | ConvertTo-Json -Depth 4
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        "`nLogon task: $(if ($task) { $task.State } else { 'not installed' })"
    }
    'apply' {
        if (-not $Name) { throw 'Usage: apply external|builtin' }
        Use-Profile $Name; "Applied '$Name'."
    }
    'save' {
        if (-not $Name) { throw 'Usage: save external|builtin' }
        Save-LiveInto $Name; "Saved live settings into '$Name'."
    }
    'install' {
        Initialize-Data
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # conhost --headless keeps a console window from flashing up at logon
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
            -Argument "--headless `"$ps`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" tray"
        $trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
            -Description 'Touchpad Control: separate settings for an external touchpad and the built-in one.' -Force | Out-Null
        Start-ScheduledTask -TaskName $TaskName
        "Installed. Look for the touchpad icon in the notification area and right-click it to choose your external touchpad."
        "Original settings backed up to $BackupPath."
    }
    'uninstall' {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -like "*$PSCommandPath*tray*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        if (Test-Path $BackupPath) { Set-LiveSettings (Get-Content $BackupPath -Raw | ConvertFrom-Json); 'Original settings restored.' }
        "Logon task removed. Your profiles are still in $DataDir; delete that folder to remove them."
    }
    'tray' {
        $created = $false
        $mutex = New-Object Threading.Mutex($true, 'Local\TouchpadControlTray', [ref]$created)
        if (-not $created) { 'Touchpad Control is already running.'; return }
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        [Windows.Forms.Application]::EnableVisualStyles()
        Write-Log 'Tray started.'
        Initialize-Data
        $script:current = $null
        $script:onPick = {
            param($sender, $e)
            $t = $sender.Tag
            try {
                if ($t.Device) {
                    Set-Device $t.Device $t.DeviceName
                    [void](Sync-Device)
                    Update-Tray
                } else { Set-ProfileValue $t.Profile $t.Key $t.Value }
            } catch { Write-Log "Error: $_" }
        }
        $script:tray = New-Object Windows.Forms.NotifyIcon
        $menu = New-Object Windows.Forms.ContextMenuStrip
        $menu.add_Opening({ try { Build-Menu $this } catch { Write-Log "Error: $_" } })
        $script:tray.ContextMenuStrip = $menu
        $script:tray.add_DoubleClick({ Start-Process 'ms-settings:devices-touchpad' })
        try { [void](Sync-Device) } catch { Write-Log "Error: $_" }
        Update-Tray
        $script:tray.Visible = $true
        if (-not (Get-Device)) {
            $script:tray.ShowBalloonTip(5000, 'Touchpad Control', 'Right-click the touchpad icon to choose your external touchpad.', 'Info')
        }
        $timer = New-Object Windows.Forms.Timer
        $timer.Interval = $PollSeconds * 1000
        $timer.add_Tick({ try { if (Sync-Device) { Update-Tray } } catch { Write-Log "Error: $_" } })
        $timer.Start()
        [Windows.Forms.Application]::Run()
        $timer.Stop(); $script:tray.Dispose(); $mutex.ReleaseMutex()
        Write-Log 'Tray exited.'
    }
}
