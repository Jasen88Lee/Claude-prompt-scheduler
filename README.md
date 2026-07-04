# claude-runner

Schedule Claude CLI prompts around usage limits. Three ways to run a prompt:

1. **reset** — run now; if you're rate-limited, wait for the next reset, then run.
2. **time** — wait until a specific clock time, then run.
3. **sequence** — run several prompts in order; if a limit is hit partway, wait
   for the reset and carry on with the next prompt.

It's a single Bash script with no dependencies beyond `date`, `grep`, `awk`,
and the `claude` CLI. While waiting it just sleeps, so background CPU use is ~nil.

> **Setting up a new machine?** See **[SETUP.md](SETUP.md)** for the full
> step-by-step install (Git Bash + Claude CLI + clone + verify). This README is
> the feature reference.

## Files

- `claude-runner.sh` — the tool.
- `run.cmd` — Windows wrapper so you can run it from PowerShell.
- `setup-task.ps1` — register a Task Scheduler job that runs while logged out.
- `jobs/` — example config files. Copy one, edit it, run it.

## Running it

From PowerShell, in this folder:

```powershell
# See the options
.\run.cmd --help

# Preview a job WITHOUT calling Claude (safe to try anytime)
.\run.cmd --job jobs\example-sequence.conf --dry-run

# Run a job for real
.\run.cmd --job jobs\example-time.conf
```

Or a quick one-off without a config file:

```powershell
.\run.cmd --mode sequence --prompt "first task" --prompt "second task"
```

## Config files (plain text — edit in Notepad)

A config file is just settings the script reads. Keys:

| Key | Meaning |
|-----|---------|
| `mode` | `reset`, `time`, or `sequence` |
| `run_at` | for `mode: time` only — `YYYY-MM-DD HH:MM` in your local time |
| `continue` | `true` = continue the MOST RECENT conversation (not a specific one) |
| `session_id` | resume a SPECIFIC existing conversation. Overrides `continue`. |
| `cwd` | project folder that conversation belongs to (required with `session_id`) |
| `skip_permissions` | `true` = run tools with no "allow?" prompts (unattended) |
| `skip_permissions_hours` | after this many hours, auto-revert to safe mode |
| `prompts:` | put each prompt on its own line **below** this word |
| `[step]` blocks | for sequences across DIFFERENT conversations (see below) |

Example (one conversation, one or more prompts):

```
mode: reset
session_id: 9cd41aa0-69f4-...
cwd: C:\Users\you\some-project
prompts:
  Continue where we left off.
  Then summarize what changed.
```

## Sequencing across DIFFERENT conversations

A plain `prompts:` list sends every prompt to the same conversation. To send
each step to a *different* conversation, use `[step]` blocks instead — each
step has its own `prompt` and its own `session_id`/`cwd`, and they run in order:

```
mode: sequence

[step]
session_id: AAAA-...
cwd: C:\Users\you\project-a
prompt: Continue the work in conversation A.

[step]
session_id: BBBB-...
cwd: C:\Users\you\project-b
prompt: Now do the follow-up in conversation B.
```

Each step waits for the previous one to finish. If a usage limit is hit during
any step, it waits for the reset and resends that step before moving on. A
`[step]` that omits `session_id`/`cwd` falls back to the job-level ones. Get the
values from `.\run.cmd --list`.

## Targeting a specific existing conversation

`continue: true` only resumes whatever conversation was used *most recently*
in that folder — not a conversation you pick. To target one specific chat
(the common case if you juggle several projects), use `session_id` + `cwd`
instead:

```
mode: reset
session_id: 9cd41aa0-69f4-45c2-991c-7ac11dd19b33
cwd: C:\Users\Jasen Lee\some-project
prompts:
  Continue where we left off.
```

**Finding the session_id + cwd the easy way** — let the tool list them, then
copy the one you want straight to your clipboard:

```powershell
.\run.cmd --list                 # all recent conversations, numbered
.\run.cmd --list electrical      # only ones whose text/path contains "electrical"
.\run.cmd --copy 1               # copy #1's session_id + cwd to the clipboard
```

`--list` prints a preview of the first message plus the exact `session_id` and
`cwd`. Example output:

```
[1] 2026-07-02 17:27
    preview:    You are going to be my electrical engineer for this project...
    session_id: 386878da-b29d-4b02-bac0-8c671aed1174
    cwd:        C:\Users\you\some-project
```

Then `--copy 1` puts these two lines on your clipboard, ready to paste (Ctrl+V)
over the `session_id:`/`cwd:` lines in your job file:

```
session_id: 386878da-b29d-4b02-bac0-8c671aed1174
cwd: C:\Users\you\some-project
```

Remember `cwd` is the **project folder that conversation lived in** — the folder
Claude was open in when you had that chat — not the scheduler's folder. `--copy`
reads the real value for you, so you don't have to figure it out yourself.

(Under the hood these live as `<session_id>.jsonl` files in
`%USERPROFILE%\.claude\projects\`, but `--list`/`--copy` read the real values.)

This uses `claude --resume <session_id>` under the hood. If that flag doesn't
match your installed CLI version, run `claude --help` to check the current
resume flag name.

## Turning off permission prompts

There are two ways to let jobs run without "allow?" prompts. Both add
`--dangerously-skip-permissions` under the hood, so only use them in a
directory/machine you trust.

### 1. The manual master switch (easiest)

A per-device on/off switch, so you don't edit any job files:

```powershell
.\run.cmd --skip on         # from now on, jobs run without prompts (until you turn it off)
.\run.cmd --skip on 6       # ...or only for the next 6 hours, then auto-revert
.\run.cmd --skip status     # check whether it's on or off
.\run.cmd --skip off        # back to safe mode
```

When it's ON, every job you run skips prompts and the banner reminds you.
The switch is **per device** — it lives in `~/.claude-runner/skip.state`, not
in the repo, so turning it on here does not turn it on on your other machine
(and it never syncs an "off the brakes" state through git). Run the same
command on each device you want it on.

### 2. Per-job setting

For a single batch, set it in the job file instead:

- `skip_permissions: true` adds the skip flag for *that job only*.
- `skip_permissions_hours: 6` reverts that job to safe mode after 6 hours.

The master switch (when ON) overrides per-job settings — if the switch is on,
everything skips regardless of what a job file says.

### 3. Interactive chat with no prompts

`--skip` and `skip_permissions` only affect prompts the *scheduler* sends. They
do **not** change a Claude app you're already chatting in — that's a separate
process. To chat interactively without permission prompts, launch it through the
tool:

```powershell
.\run.cmd chat                              # new conversation, no prompts
.\run.cmd chat --session-id ID --cwd PATH   # resume a specific conversation
.\run.cmd chat --continue                   # continue your most recent one
```

This opens a normal interactive Claude session started with permissions skipped.
Start chat this way (instead of the app icon) whenever you want it hands-off.

## Running while logged out

A job you start with `.\run.cmd --job ...` runs in your terminal and dies if you
log out of Windows. To run while logged out (and wake from sleep), register it
with Task Scheduler using the included helper — see **[SETUP.md](SETUP.md)**:

```powershell
.\setup-task.ps1 -Job jobs\your-job.conf -Time 16:00
```
