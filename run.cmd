@echo off
REM Windows wrapper so you can run the bash tool from PowerShell / CMD.
REM Requires Git Bash (bash.exe on PATH). Example:
REM   run.cmd --job jobs\example-time.conf
bash "%~dp0claude-runner.sh" %*
