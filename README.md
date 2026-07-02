# claude-runner

Schedule Claude CLI prompts around usage limits. Three ways to run a prompt:

1. **reset** — run now; if you're rate-limited, wait for the next reset, then run.
2. **time** — wait until a specific clock time, then run.
3. **sequence** — run several prompts in order; if a limit is hit partway, wait
   for the reset and carry on with the next prompt.

It's a single Bash script with no dependencies beyond `date`, `grep`, `awk`,
and the `claude` CLI. While waiting it just sleeps, so background CPU use is ~nil.

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
| `continue` | `true` = keep the same conversation across prompts |
| `skip_permissions` | `true` = run tools with no "allow?" prompts (unattended) |
| `skip_permissions_hours` | after this many hours, auto-revert to safe mode |
| `prompts:` | put each prompt on its own line **below** this word |

Example:

```
mode: sequence
continue: true
skip_permissions: true
skip_permissions_hours: 6
prompts:
  Add unit tests for the parser and run them.
  Update the README to match.
```

## About `skip_permissions`

- **Default is `false`** and nothing global is ever changed — your normal
  interactive Claude sessions keep asking permission as usual.
- Setting `skip_permissions: true` only adds `--dangerously-skip-permissions`
  to the commands in *that one batch*, so it can run unattended.
- `skip_permissions_hours` is a safety net: once the batch has been running
  that long, the tool stops skipping and reverts to safe mode automatically.
- Only turn it on in a directory you trust — skipped prompts can run tools
  (edit files, run commands) without asking.
