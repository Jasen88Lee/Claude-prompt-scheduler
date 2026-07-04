# Setup on a new device (Windows)

Follow these steps in order on any new machine. Takes about 10 minutes.
When you're done, `.\run.cmd --check` should show everything `FOUND`/`OK`.

---

## What you need (two programs)

This tool is a Bash script that drives the Claude CLI, so the machine needs:

1. **Git for Windows** — provides `git` (to download the code) and **Git Bash**
   (to run the script).
2. **Claude Code CLI** — the `claude` command the tool sends your prompts to.

Steps 1 and 2 below install them. If a machine already has them, skip that step.

---

## Step 1 — Install Git for Windows

1. Download from **https://git-scm.com/download/win**
2. Run the installer and click **Next** through all the defaults (the defaults
   include Git Bash, which is what this tool needs).
3. Done. You don't need to open anything yet.

To check it worked, open **PowerShell** and run:
```powershell
git --version
```
You should see a version number.

---

## Step 2 — Install the Claude Code CLI

In **PowerShell**, run:
```powershell
irm https://claude.ai/install.ps1 | iex
```
This installs `claude` to `C:\Users\<you>\.local\bin\claude.exe`.

> You may see a note that this folder "is not in your PATH." **You can ignore
> that** — this tool finds `claude` automatically even when it's not on PATH.
> (Adding it to PATH is optional; it only affects typing plain `claude`
> yourself in a terminal.)

To confirm the install location, run:
```powershell
claude --version
```
If PowerShell says `claude` isn't recognized but the installer said it succeeded,
that's just the PATH note above — the tool will still find it. Move on.

---

## Step 3 — Download this tool

Pick a folder to keep it in (your home folder is fine). In **PowerShell**:
```powershell
cd $HOME
git clone https://github.com/Jasen88Lee/Claude-prompt-scheduler.git
cd Claude-prompt-scheduler
```

That creates a `Claude-prompt-scheduler` folder with everything in it.

---

## Step 4 — Verify the machine is ready

Still in that folder, run:
```powershell
.\run.cmd --check
```

You want to see all three lines healthy, e.g.:
```
  bash            : GNU bash, version 5.2.x ...
  date (GNU)      : OK
  claude CLI      : FOUND -> /c/Users/you/.local/bin/claude.exe
```

- If **bash** errors ("bash is not recognized") → Git for Windows isn't
  installed. Redo Step 1.
- If **claude CLI : NOT FOUND** → the Claude CLI isn't installed. Redo Step 2.
  (If it's installed somewhere unusual, run `claude --version` in a terminal
  where it works and note the path — that path can be added to the tool.)

---

## Step 5 — Create a job (what prompt to run, and when)

Jobs live in the `jobs\` folder as small text files. The easiest way is to
copy an example and edit it.

**Find the conversation you want to send a prompt into** (optional — only if
you want to continue an existing chat rather than start a new one):
```powershell
.\run.cmd --list
```
This lists your recent conversations with a preview, a `session_id`, and a
`cwd`. Note the `session_id` and `cwd` of the one you want. Add a word to
filter, e.g. `.\run.cmd --list schedule`.

**Make your job file:**
1. Open the `jobs` folder in File Explorer:
   ```powershell
   explorer jobs
   ```
2. Copy an example (e.g. `example-reset.conf`), paste, and rename the copy to
   something like `my-job.conf` (keep the `.conf` ending).
3. Right-click it → **Open with → Notepad**.
4. Edit the settings and the prompt. A "run as soon as the limit resets, into
   a specific existing conversation" job looks like:
   ```
   mode: reset
   session_id: PASTE-FROM-LIST
   cwd: PASTE-FROM-LIST
   skip_permissions: false
   skip_permissions_hours: 6
   prompts:
     Continue where we left off.
   ```
   - Leave `session_id`/`cwd` out entirely to start a **new** conversation.
   - Set `skip_permissions: true` only for unattended batches you trust.
5. Save (`Ctrl + S`).

> **Notepad tip:** always start from a copied `.conf` file. If you make a file
> from scratch, Notepad may secretly save it as `my-job.conf.txt` and the tool
> won't find it.

---

## Step 6 — Preview, then run

Always preview first — this calls nothing, just shows what *would* happen:
```powershell
.\run.cmd --job jobs\my-job.conf --dry-run
```
Check the printed `session_id`, `cwd`, and prompt are correct. In particular,
make sure `cwd` is a **real folder**, not a leftover placeholder like
`C:\Users\...\path\to\that\project`.

When it looks right, run it for real (drop `--dry-run`):
```powershell
.\run.cmd --job jobs\my-job.conf
```
Leave the PowerShell window open. The tool sends the prompt; if you're
rate-limited it waits quietly for the reset, then sends automatically.

**Important:** a job started this way runs in your terminal, so it only survives
while you stay **logged in**. If you log out of Windows, it is killed and won't
fire. To run while logged out, use Task Scheduler (next section).

---

## Run a job while logged out (Task Scheduler)

`setup-task.ps1` registers a Windows scheduled task that runs a job **whether
you are logged on or not**, and can **wake the machine from sleep** to do it.
(It still cannot run when the machine is fully powered OFF — sleep is fine,
shutdown is not.)

Open PowerShell **as Administrator** (right-click → Run as administrator —
creating a "run whether logged on or not" task needs it), then:

```powershell
cd C:\Users\jasen\Claude-prompt-scheduler

# Run one job once, today at 16:00 (or tomorrow if 16:00 already passed):
.\setup-task.ps1 -Job jobs\continue-gaming-prompt.conf -Time 16:00

# ...or every day at 09:00:
.\setup-task.ps1 -Job jobs\morning.conf -Time 09:00 -Daily

# Remove the scheduled task:
.\setup-task.ps1 -Remove
```

What it sets up for you: runs whether logged on or not (no password stored),
wakes from sleep, runs on battery, and appends all output to `last-run.log` in
the project folder so you can see what happened. Check that log after a run.

If a logged-out run fails to reach the network, open Task Scheduler, edit the
task, choose **Run whether user is logged on or not**, and enter your password
(that mode has full network access).

Works the same on any device you clone the repo to — just use that machine's
paths and run `setup-task.ps1` there too.

---

## Updating to the latest version

From inside the folder:
```powershell
git pull
```
That's it — pulls the newest script and examples.

---

## Quick reference — all commands

Run everything as `.\run.cmd <options>` from inside the project folder.

**Running jobs**

| Command | What it does |
|---|---|
| `.\run.cmd --job jobs\X.conf` | Run a saved job for real |
| `.\run.cmd --job jobs\X.conf --dry-run` | Preview a job — prints what would run, sends nothing |
| `.\run.cmd --mode reset --session-id ID --cwd PATH --prompt "..."` | Quick one-off without a job file |
| `.\run.cmd --mode sequence --prompt "a" --prompt "b"` | Queue several prompts in one run |

**Interactive chat with no permission prompts**

| Command | What it does |
|---|---|
| `.\run.cmd chat` | Open an interactive Claude session that never asks permission |
| `.\run.cmd chat --session-id ID --cwd PATH` | Same, but resume a specific conversation |
| `.\run.cmd chat --continue` | Same, but continue your most recent conversation |

**Finding & checking things**

| Command | What it does |
|---|---|
| `.\run.cmd --check` | Confirm bash / date / claude are all found |
| `.\run.cmd --list` | List recent conversations (session_id + cwd to copy into a job) |
| `.\run.cmd --list WORD` | Same, but only conversations whose text/path contains WORD |
| `.\run.cmd --copy N` | Copy conversation N's `session_id` + `cwd` to the clipboard (then paste into a job file) |
| `.\run.cmd --copy N WORD` | Same, numbering within the WORD-filtered list |
| `.\run.cmd --help` | Show every option |
| `.\run.cmd --version` | Show the version |

**Permission master switch (per device)**

| Command | What it does |
|---|---|
| `.\run.cmd --skip on` | Run jobs WITHOUT permission prompts, until you turn it off |
| `.\run.cmd --skip on 6` | Same, but auto-reverts to safe mode after 6 hours |
| `.\run.cmd --skip status` | Show whether the switch is on or off |
| `.\run.cmd --skip off` | Back to safe mode (jobs ask permission) |

**Updating**

| Command | What it does |
|---|---|
| `git pull` | Update to the latest version (run inside the project folder) |

**Extra flags you can add to any run**

| Flag | What it does |
|---|---|
| `--continue` | Continue the MOST RECENT conversation (instead of `--session-id`) |
| `--skip-permissions` | Skip prompts for this single run (per-job; master switch is easier) |
| `--skip-hours N` | With `--skip-permissions`, revert to safe mode after N hours |

## Quick reference — job file keys

Inside a `.conf` job file (see `jobs\` for examples):

| Key | What it does |
|---|---|
| `mode:` | `reset` (run when limit resets), `time` (run at a clock time), or `sequence` |
| `run_at:` | For `mode: time` — `YYYY-MM-DD HH:MM` in your local time |
| `session_id:` | The conversation to continue (get it from `--list`) |
| `cwd:` | That conversation's project folder (get it from `--list`) |
| `continue:` | `true` = continue the most-recent conversation instead of a specific one |
| `skip_permissions:` | `true` = this job skips permission prompts |
| `skip_permissions_hours:` | Auto-revert this job to safe mode after N hours |
| `prompts:` | One prompt per line below this word (all to the same conversation) |
| `[step]` | Start a step with its own `session_id:` / `cwd:` / `prompt:` — lets a sequence span DIFFERENT conversations |

---

## Common problems

- **`'bash' is not recognized`** — Git for Windows isn't installed (Step 1),
  or you're calling the script wrong; always use `.\run.cmd ...`.
- **`claude CLI : NOT FOUND`** — install Claude (Step 2). If it's already
  installed, run `claude --version` where it works and note the path.
- **A real run fails on the folder / wrong conversation** — your `cwd` is still
  a placeholder. Run `.\run.cmd --list` and paste the real `cwd` into the job.
- **Nothing happens for a long time** — that's normal for `mode: time` or when
  waiting for a reset; it's sleeping until the target. Leave the window open.
