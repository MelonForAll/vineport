@echo off
REM Wrapper that launches the real steamwebhelper with extra flags for Wine compatibility
REM This gets copied to replace steamwebhelper.exe in the Steam prefix

set "SCRIPT_DIR=%~dp0"
"%SCRIPT_DIR%steamwebhelper_real.exe" %* --no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing --use-gl=swiftshader
