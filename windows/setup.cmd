@echo off
rem Runs setup.ps1 with the arguments given, e.g.
rem   setup.cmd Install -AllowedRemoteAddress 192.168.1.0/24
rem Windows blocks .ps1 scripts by default (execution policy); a .cmd is not
rem subject to it, so this bypasses the policy for this one run only and leaves
rem the system setting as it is. Run Install and Remove from an elevated prompt.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
exit /b %ERRORLEVEL%
