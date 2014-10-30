@echo off

set LUA_CMDLINE=win32\lua\lua.exe -e "io.stdout:setvbuf 'no'"

%LUA_CMDLINE% %1

