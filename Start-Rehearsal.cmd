@echo off
setlocal EnableExtensions DisableDelayedExpansion
pushd "%~dp0"
if errorlevel 1 goto folder_missing
if not exist "scripts\Start-LabRehearsal.ps1" goto script_missing
echo TD SYNNEX - Cloud Enablement Services - Hyper-V rehearsal
echo Runs scripted stages and pauses for instructor evidence. Cloud changes require approval.
powershell.exe -NoProfile -File ".\scripts\Start-LabRehearsal.ps1" -Mode Run -Interactive
set "CES_REHEARSAL_EXIT=%ERRORLEVEL%"
echo.
echo Rehearsal exited with code %CES_REHEARSAL_EXIT%: 0=complete with instructor evidence, 1=failure, 2=paused.
if exist "rehearsal-evidence\current\report.html" echo Open "%CD%\rehearsal-evidence\current\report.html" for recorded results.
pause
popd
exit /b %CES_REHEARSAL_EXIT%

:script_missing
echo Workshop script missing: "%CD%\scripts\Start-LabRehearsal.ps1"
echo Extract or clone the complete workshop. Keep Start-Rehearsal.cmd beside the scripts, tests and docs folders.
echo Do not run this launcher from inside a ZIP or copy it out by itself.
pause
popd
exit /b 1

:folder_missing
echo Cannot open the workshop folder: "%~dp0"
echo Extract the complete workshop to an accessible folder on this workstation.
pause
exit /b 1
