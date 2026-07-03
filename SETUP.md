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

---

## Updating to the latest version

From inside the folder:
```powershell
git pull
```
That's it — pulls the newest script and examples.

---

## Quick reference

| Command | What it does |
|---|---|
| `.\run.cmd --check` | Confirm bash/date/claude are found |
| `.\run.cmd --list [word]` | List conversations to copy session_id/cwd from |
| `.\run.cmd --job jobs\X.conf --dry-run` | Preview a job (sends nothing) |
| `.\run.cmd --job jobs\X.conf` | Run a job for real |
| `.\run.cmd --help` | All options |
| `git pull` | Update to the latest version |

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
