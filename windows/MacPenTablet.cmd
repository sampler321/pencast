@echo off
rem Surface (or any Windows pen tablet) as a pressure tablet for the Mac. Set MAC to your Mac: its .local name, LAN IP
rem and/or Tailscale IP, separated by "+" (the first that resolves is used). Start "Pen Tablet Host" on the Mac first.
set MAC=your-mac.local
set MOONLIGHT_HOST=Mac
taskkill /im PenCast.exe /f >nul 2>&1
start "" "%~dp0PenCast.exe" %MAC%
start "" "C:\Program Files\Moonlight Game Streaming\Moonlight.exe" stream %MOONLIGHT_HOST% Desktop
