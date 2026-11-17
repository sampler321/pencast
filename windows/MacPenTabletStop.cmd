@echo off
rem Stop using the Surface as the Mac's pen tablet: ends PenCast and the Moonlight stream; pen and touch stay with Windows.
taskkill /im PenCast.exe /f >nul 2>&1
taskkill /im Moonlight.exe /f >nul 2>&1
