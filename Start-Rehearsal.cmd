@echo off
setlocal
cd /d "%~dp0"
echo TD SYNNEX - Cloud Enablement Services - Hyper-V rehearsal
echo Runs scripted stages and pauses for instructor evidence. Cloud changes require approval.
powershell.exe -NoProfile -File "%~dp0scripts\Start-LabRehearsal.ps1" -Mode Run -Interactive
set "CES_REHEARSAL_EXIT=%ERRORLEVEL%"
echo.
echo Rehearsal exited with code %CES_REHEARSAL_EXIT%: 0=complete with instructor evidence, 1=failure, 2=paused.
echo Open rehearsal-evidence\current\report.html for recorded results.
pause
exit /b %CES_REHEARSAL_EXIT%
