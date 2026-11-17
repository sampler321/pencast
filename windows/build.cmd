@echo off
rem Builds PenCast.exe with the C# compiler that ships with Windows (.NET Framework 4).
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /out:"%~dp0PenCast.exe" /r:System.Windows.Forms.dll "%~dp0PenCast.cs"
