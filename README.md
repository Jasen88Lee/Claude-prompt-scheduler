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

**Finding the session_id + cwd the easy way** — let the tool list them:

```powershell
.\run.cmd --list                 # all recent conversations
.\run.cmd --list electrical      # only ones whose text/path contains "electrical"
```

Each entry prints a preview of the first message plus the exact `session_id`
and `cwd` to copy straight into your job file. Example output:

```
[1] 2026-07-02 17:27
    preview:    You are going to be my electrical engineer for this project...
    session_id: 386878da-b29d-4b02-bac0-8c671aed1174
    cwd:        C:\Users\you\some-project
```

(Under the hood these live as `<session_id>.jsonl` files in
`%USERPROFILE%\.claude\projects\`, but `--list` reads the real values for you.)

This uses `claude --resume <session_id>` under the hood. If that flag doesn't
match your installed CLI version, run `claude --help` to check the current
resume flag name.

## About `skip_permissions`

- **Default is `false`** and nothing global is ever changed — your normal
  interactive Claude sessions keep asking permission as usual.
- Setting `skip_permissions: true` only adds `--dangerously-skip-permissions`
  to the commands in *that one batch*, so it can run unattended.
- `skip_permissions_hours` is a safety net: once the batch has been running
  that long, the tool stops skipping and reverts to safe mode automatically.
- Only turn it on in a directory you trust — skipped prompts can run tools
  (edit files, run commands) without asking.
