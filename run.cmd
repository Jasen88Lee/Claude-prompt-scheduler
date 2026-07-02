@echo off
REM Windows wrapper so you can run the bash tool from PowerShell / CMD.
REM Finds Git Bash even if it isn't on PATH. Example:
REM   run.cmd --job jobs\example-time.conf
REM
REM NOTE: we check known Git Bash install folders BEFORE falling back to
REM whatever "bash.exe" resolves on PATH. Windows ships its own bash.exe
REM stub at %LocalAppData%\Microsoft\WindowsApps\bash.exe (a WSL launcher)
REM which often comes first on PATH and silently breaks Windows-style
REM paths like C:\Users\... if used instead of the real Git Bash.

setlocal enabledelayedexpansion

if exist "%ProgramFiles%\Git\bin\bash.exe" (
    set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
    goto :run
)
if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" (
    set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"
    goto :run
)
if exist "%LocalAppData%\Programs\Git\bin\bash.exe" (
    set "BASH_EXE=%LocalAppData%\Programs\Git\bin\bash.exe"
    goto :run
)

REM Last resort: whatever's on PATH, but reject the WSL launcher stub.
for /f "delims=" %%B in ('where bash.exe 2^>nul') do (
    echo %%B | findstr /i "WindowsApps" >nul
    if errorlevel 1 (
        set "BASH_EXE=%%B"
        goto :run
    )
)

echo [ERROR] Could not find Git Bash's bash.exe.
echo Install Git for Windows from https://git-scm.com/download/win ^(default options include Git Bash^),
echo then try again.
exit /b 1

:run
"!BASH_EXE!" "%~dp0claude-runner.sh" %*
