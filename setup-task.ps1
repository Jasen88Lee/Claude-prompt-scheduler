<#
.SYNOPSIS
  Register a Windows scheduled task that runs a claude-runner job — even when
  you are logged out — and can wake the machine from sleep to do it.

.DESCRIPTION
  Creates a Task Scheduler task that runs:  run.cmd --job <Job>
  at the time you choose. The task uses the S4U logon type, so it runs whether
  you are logged on or not WITHOUT storing your password. Output is appended to
  last-run.log in this folder so you can see what happened.

  NOTE: it still cannot run when the machine is fully powered OFF. Sleep is fine
  (WakeToRun is enabled); shutdown is not.

.EXAMPLE
  # One-time, today at 16:00 (or tomorrow if 16:00 already passed):
  .\setup-task.ps1 -Job jobs\continue-gaming-prompt.conf -Time 16:00

.EXAMPLE
  # Every day at 09:00:
  .\setup-task.ps1 -Job jobs\morning.conf -Time 09:00 -Daily

.EXAMPLE
  # Remove the task:
  .\setup-task.ps1 -Remove
#>

param(
  [string]$Job,
  [string]$Time,
  [string]$TaskName = "ClaudePromptScheduler",
  [switch]$Daily,
  [switch]$Remove
)

$ErrorActionPreference = "Stop"

# This script lives in the repo root; run.cmd is next to it.
$Root = $PSScriptRoot
$RunCmd = Join-Path $Root "run.cmd"
$LogFile = Join-Path $Root "last-run.log"

if ($Remove) {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'."
  } else {
    Write-Host "No scheduled task named '$TaskName' to remove."
  }
  return
}

if (-not $Job -or -not $Time) {
  Write-Host "Usage: .\setup-task.ps1 -Job jobs\your-job.conf -Time HH:MM [-Daily]"
  Write-Host "       .\setup-task.ps1 -Remove"
  return
}

if (-not (Test-Path $RunCmd)) { throw "run.cmd not found next to this script ($RunCmd)." }

# Resolve the job path (accept relative-to-repo or absolute) and verify it exists.
$JobPath = if ([System.IO.Path]::IsPathRooted($Job)) { $Job } else { Join-Path $Root $Job }
if (-not (Test-Path $JobPath)) { throw "Job file not found: $JobPath" }

# Parse H:MM / HH:MM and build the trigger time (today, or tomorrow if already past).
try { $parsed = [DateTime]::ParseExact($Time, @("HH:mm","H:mm"), $null, [System.Globalization.DateTimeStyles]::None) }
catch { throw "Time must be 24-hour H:MM, e.g. 16:00 or 9:30. Got '$Time'." }
$when = (Get-Date).Date.AddHours($parsed.Hour).AddMinutes($parsed.Minute)
if (-not $Daily -and $when -lt (Get-Date)) { $when = $when.AddDays(1) }

# The task runs cmd.exe, which calls run.cmd and appends output to the log.
# cmd /c strips the OUTER quote pair, then runs the inner command whose paths
# are each quoted (so paths with spaces like "C:\Users\Jasen Lee\..." work).
$innerCommand = '"{0}" --job "{1}" >> "{2}" 2>&1' -f $RunCmd, $JobPath, $LogFile
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$innerCommand`"" -WorkingDirectory $Root

if ($Daily) {
  $trigger = New-ScheduledTaskTrigger -Daily -At $when
} else {
  $trigger = New-ScheduledTaskTrigger -Once -At $when
}

# Run whether logged on or not (S4U = no stored password), wake to run, run on battery.
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType S4U -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Scheduled task '$TaskName' registered."
Write-Host ("  Runs      : {0}{1}" -f $when, $(if ($Daily) { " (every day)" } else { " (once)" }))
Write-Host "  Job       : $JobPath"
Write-Host "  Log       : $LogFile"
Write-Host "  Logged out: yes (S4U) | Wakes from sleep: yes | Powered off: no"
Write-Host ""
Write-Host "Tip: if a logged-out run fails to reach the network, re-create it in Task"
Write-Host "     Scheduler with 'Run whether user is logged on or not' + your password."
Write-Host "Remove it later with:  .\setup-task.ps1 -Remove"
