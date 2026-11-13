<#
  fix-refresh.ps1
  Sets every active monitor to the highest refresh rate it supports at its
  current resolution. Does nothing if they're already there.

  Usage:
    .\fix-refresh.ps1           # fix any monitor that has dropped
    .\fix-refresh.ps1 -WhatIf   # only report what it would change
#>
param([switch]$WhatIf)

$ErrorActionPreference = 'Stop'

# ---------- Logging ----------
$LogDir  = Join-Path $env:LOCALAPPDATA 'monitor-refresh-fix'
$LogFile = Join-Path $LogDir 'log.txt'
$MaxLogLines = 500

function Write-Log([string]$msg) {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    $all = Get-Content $LogFile
    if ($all.Count -gt $MaxLogLines) { $all | Select-Object -Last $MaxLogLines | Set-Content $LogFile -Encoding UTF8 }
}

# ---------- Windows display API ----------
if (-not ('MRF.Native' -as [type])) {
Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace MRF {
  public static class Native {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
      public int cb;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
      public int StateFlags;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    // DEVMODEW, display variant of the union
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
      public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
      public int dmFields;
      public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
      public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
      public short dmLogPixels;
      public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
      public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string lpDevice, int iDevNum, ref DISPLAY_DEVICE dd, int dwFlags);

    // PowerShell turns $null into "" for string args, so adapters are listed from here with a real null
    public static bool EnumAdapter(int i, ref DISPLAY_DEVICE dd) { return EnumDisplayDevices(null, i, ref dd, 0); }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string lpszDeviceName, int iModeNum, ref DEVMODE dm);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE dm, IntPtr hwnd, int dwflags, IntPtr lParam);

    // Overload with a null DEVMODE: "apply everything that was staged"
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
    public static extern int ApplyStaged(IntPtr lpszDeviceName, IntPtr dm, IntPtr hwnd, int dwflags, IntPtr lParam);
  }
}
'@
}

$ENUM_CURRENT_SETTINGS         = -1
$ATTACHED_TO_DESKTOP           = 0x1
$MONITOR_ACTIVE                = 0x1
$DM_INTERLACED                 = 0x2
$DM_DISPLAYFREQUENCY           = 0x400000
$CDS_UPDATEREGISTRY            = 0x1
$CDS_NORESET                   = 0x10000000
$EDD_GET_DEVICE_INTERFACE_NAME = 0x1

function New-DevMode {
    $dm = New-Object MRF.Native+DEVMODE
    $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf($dm)
    $dm
}

# Map PnP model code (e.g. AUS2722) -> friendly name (e.g. VG27A) from EDID data
$FriendlyNames = @{}
try {
    Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop | ForEach-Object {
        $code = ($_.InstanceName -split '\\')[1]
        $name = (($_.UserFriendlyName | Where-Object { $_ }) | ForEach-Object { [char]$_ }) -join ''
        if ($code -and $name) { $FriendlyNames[$code] = $name.Trim() }
    }
} catch { }

function Get-MonitorName([string]$adapterName) {
    # An output can list several monitors (e.g. an inactive TV first); use the active one
    for ($k = 0; $true; $k++) {
        $mon = New-Object MRF.Native+DISPLAY_DEVICE
        $mon.cb = [Runtime.InteropServices.Marshal]::SizeOf($mon)
        if (-not [MRF.Native]::EnumDisplayDevices($adapterName, $k, [ref]$mon, $EDD_GET_DEVICE_INTERFACE_NAME)) { break }
        if (-not ($mon.StateFlags -band $MONITOR_ACTIVE)) { continue }
        # DeviceID looks like \\?\DISPLAY#AUS2722#5&abc...#{guid}
        $code = ($mon.DeviceID -split '#')[1]
        if ($code -and $FriendlyNames.ContainsKey($code)) { return $FriendlyNames[$code] }
    }
    return $adapterName.TrimStart('\', '.')
}

# ---------- Find what needs fixing ----------
$changes = @()
for ($i = 0; $true; $i++) {
    $dd = New-Object MRF.Native+DISPLAY_DEVICE
    $dd.cb = [Runtime.InteropServices.Marshal]::SizeOf($dd)
    if (-not [MRF.Native]::EnumAdapter($i, [ref]$dd)) { break }
    if (-not ($dd.StateFlags -band $ATTACHED_TO_DESKTOP)) { continue }

    $cur = New-DevMode
    if (-not [MRF.Native]::EnumDisplaySettings($dd.DeviceName, $ENUM_CURRENT_SETTINGS, [ref]$cur)) { continue }

    # Highest rate at the same resolution and colour depth, progressive only
    $best = $cur.dmDisplayFrequency
    $m = New-DevMode
    for ($j = 0; [MRF.Native]::EnumDisplaySettings($dd.DeviceName, $j, [ref]$m); $j++) {
        if ($m.dmPelsWidth -eq $cur.dmPelsWidth -and
            $m.dmPelsHeight -eq $cur.dmPelsHeight -and
            $m.dmBitsPerPel -eq $cur.dmBitsPerPel -and
            -not ($m.dmDisplayFlags -band $DM_INTERLACED) -and
            $m.dmDisplayFrequency -gt $best) {
            $best = $m.dmDisplayFrequency
        }
    }

    $name = Get-MonitorName $dd.DeviceName
    if ($best -gt $cur.dmDisplayFrequency) {
        $changes += [pscustomobject]@{ Device = $dd.DeviceName; Name = $name; Mode = $cur; From = $cur.dmDisplayFrequency; To = $best }
    } elseif ($WhatIf) {
        Write-Host ("OK      {0,-10} {1}x{2} @ {3} Hz" -f $name, $cur.dmPelsWidth, $cur.dmPelsHeight, $cur.dmDisplayFrequency)
    }
}

if ($changes.Count -eq 0) { if ($WhatIf) { Write-Host 'Nothing to fix.' }; exit 0 }

if ($WhatIf) {
    foreach ($c in $changes) { Write-Host ("WOULD FIX {0,-8} {1} -> {2} Hz" -f $c.Name, $c.From, $c.To) }
    exit 0
}

# ---------- Stage every change, then apply them all at once ----------
$fixed = @()
foreach ($c in $changes) {
    $dm = $c.Mode
    $dm.dmDisplayFrequency = $c.To
    $dm.dmFields = $DM_DISPLAYFREQUENCY
    $r = [MRF.Native]::ChangeDisplaySettingsEx($c.Device, [ref]$dm, [IntPtr]::Zero, ($CDS_UPDATEREGISTRY -bor $CDS_NORESET), [IntPtr]::Zero)
    if ($r -eq 0) { $fixed += $c } else { Write-Log ("ERROR   {0} {1} -> {2} Hz failed (code {3})" -f $c.Name, $c.From, $c.To, $r) }
}
if ($fixed.Count -gt 0) {
    $r = [MRF.Native]::ApplyStaged([IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero)
    if ($r -ne 0) { Write-Log "ERROR   applying staged changes failed (code $r)"; exit 1 }
}

foreach ($c in $fixed) { Write-Log ("FIXED   {0} {1} -> {2} Hz" -f $c.Name, $c.From, $c.To) }

# ---------- Toast ----------
if ($fixed.Count -gt 0) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $body = ($fixed | ForEach-Object { '{0}: {1} {2} {3} Hz' -f $_.Name, $_.From, [char]0x2192, $_.To }) -join "`n"
        $esc  = [Security.SecurityElement]::Escape($body)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>Refresh rate fixed</text><text>$esc</text></binding></visual></toast>")
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch {
        Write-Log "ERROR   toast failed: $($_.Exception.Message)"
    }
}
