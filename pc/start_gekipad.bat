@echo off
setlocal enabledelayedexpansion

rem Example launcher - adjust the paths below for your actual ONGEKI/segatools install.
rem Layout this assumes: a "GekiPad" folder (GekiBridge.exe, GekiIo.dll, gekipad.cfg, aime.txt) sitting next to
rem your segatools Package folder, or copied inside it - either is fine, nothing here is path-sensitive except
rem GekiIo.dll needing to be found by segatools.ini's [mu3io]/[aimeio] path= (see ../README.md).

pushd %~dp0

start "GekiBridge" /min "GekiBridge.exe" --window MU3

rem Start the game the same way your segatools loader normally does, e.g.:
rem   inject -d -k mu3hook.dll mu3.exe
rem Replace the line below with your actual launch command once you have it confirmed.
echo Edit start_gekipad.bat with your real segatools launch command, then remove this line.
pause

taskkill /f /im GekiBridge.exe >nul 2>&1
