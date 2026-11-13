# monitor-refresh-fix

A small PowerShell script for Windows that puts each monitor back to its **highest refresh rate** when Windows drops it to 60 Hz after a reboot or wake from sleep.

- No installs, no admin rights, no config. It picks the top rate each monitor supports at its current resolution.
- Runs on its own 1 and 3 minutes after logon, and 30 seconds after waking from sleep.
- Shows a Windows notification only when it actually fixed something.
- Every fix is logged to `%LOCALAPPDATA%\monitor-refresh-fix\log.txt` (last 500 lines kept).

## Install

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

This registers a scheduled task named **Monitor Refresh Fix** for your user. Run it again if you move the folder.

## Use by hand

```powershell
.\fix-refresh.ps1 -WhatIf   # show what it would change
.\fix-refresh.ps1           # fix it now
```

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## How it works

1. `EnumDisplayDevices` lists the displays that are part of the desktop.
2. `EnumDisplaySettings` reads each one's current mode, then all the modes it supports. The best rate is the highest one at the same resolution and colour depth (interlaced modes are skipped).
3. Each change is staged with `ChangeDisplaySettingsEx(..., CDS_UPDATEREGISTRY | CDS_NORESET)`. One final call with no device applies them all at once, so the screens blank once.
4. The task runs through `conhost.exe --headless`, so no console window flashes.

## Why does it drop to 60 Hz in the first place?

Things worth checking, if you'd rather fix the cause:

- **Fast Startup**: when it's on, Windows can restore a stale display state. (Off on the machine this was written for.)
- **Virtual display drivers**: Meta Quest Link, Parsec, Virtual Desktop, etc. add a virtual monitor that can reshuffle the display layout at boot.
- **DisplayPort link training**: a marginal cable, or a monitor in deep sleep, can briefly report a basic EDID with only 60 Hz. Try a certified DP 1.4 cable, or turn off the monitor's "DP deep sleep" option.
- **GPU driver**: a clean driver reinstall (DDU) clears corrupted per-monitor display data.
