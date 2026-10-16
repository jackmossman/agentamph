@echo off
rem agentamph UserPromptSubmit hook, first stage. Exits at once unless the hook
rem input contains the trigger phrase, so powershell.exe starts only on a possible
rem match. "more" copies stdin to a file (findstr cannot read long lines from
rem stdin); mark-critical.ps1 then checks the prompt's first line properly.
setlocal EnableExtensions EnableDelayedExpansion
set "PHRASE=!CLAUDE_PLUGIN_OPTION_TRIGGER_PHRASE!"
if not defined PHRASE set "PHRASE=this session is critical"
set "INPUT=%TEMP%\agentamph-hook-%RANDOM%%RANDOM%.json"
more > "!INPUT!"
findstr /I /L /C:"!PHRASE!" "!INPUT!" >nul
if errorlevel 1 (
    del "!INPUT!" 2>nul
    exit /b 0
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0mark-critical.ps1" -InputPath "!INPUT!"
set "CODE=!ERRORLEVEL!"
del "!INPUT!" 2>nul
exit /b !CODE!
