@echo off
setlocal enabledelayedexpansion

rem Launcher, based on a real ONGEKI ReFresh 1.51.00 install's own start.bat (game=mu3.exe, hook=mu3hook.dll,
rem 3 amdaemon config files). Copy GekiBridge.exe + GekiIo.dll into your segatools "package" folder (the one with
rem mu3.exe/segatools.ini in it) and set [mu3io] and [aimeio] path=GekiIo.dll in segatools.ini before running this.
rem
rem Changed from the original start.bat: -screen-fullscreen 0 -popupwindow instead of -screen-fullscreen 1, and no
rem RotateDisplay/RotateScreen step. The game renders portrait (1080x1920) regardless; the original script kept it
rem exclusive-fullscreen and physically rotated the monitor output to compensate. Exclusive fullscreen can't be
rem screen-captured by GekiBridge's video, and the rotation step isn't needed at all in windowed mode - the window
rem is just 1080 wide x 1920 tall directly, exactly like this project's maimai setup.

pushd %~dp0

start "GekiBridge" /min "GekiBridge.exe" --window mu3 --aime-file DEVICE\aime.txt

start "AM Daemon" /min inject -d -k mu3hook.dll amdaemon.exe -f -c config_common.json config_server.json config_client.json
inject -d -k mu3hook.dll mu3 -screen-fullscreen 0 -popupwindow -screen-width 1080 -screen-height 1920
taskkill /f /im amdaemon.exe >nul 2>&1

taskkill /f /im GekiBridge.exe >nul 2>&1
