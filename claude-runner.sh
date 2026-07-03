#!/usr/bin/env bash
# claude-runner.sh  (v1.0.0)
# -----------------------------------------------------------------------------
# Run Claude CLI prompts on a schedule, automatically waiting for usage-limit
# resets. Three modes:
#   reset     - run the prompt(s) now; if you are currently rate-limited, wait
#               for the next reset, then run.
#   time      - wait until a specific clock time, then run the prompt(s).
#   sequence  - run several prompts in order; if a limit is hit partway through,
#               wait for the reset, then carry on with the next prompt.
#
# Zero dependencies beyond: bash, coreutils (date/sleep), grep, awk, and the
# `claude` CLI. Idle time is spent sleeping, so background CPU use is ~nil.
# -----------------------------------------------------------------------------

set -uo pipefail

VERSION="1.6.0"
SELF="$(basename "$0")"

# ---------- settings (overridden by a job file or CLI flags) ----------
MODE=""                     # reset | time | sequence
RUN_AT=""                   # for mode=time: "YYYY-MM-DD HH:MM" (local time)
CONTINUE="false"            # true = use `claude -c` to continue the MOST RECENT chat
SESSION_ID=""               # default conversation for steps that don't set their own
WORKDIR=""                  # default directory for steps that don't set their own
SKIP_PERMISSIONS="false"    # true = add --dangerously-skip-permissions
SKIP_PERMISSIONS_HOURS="6"  # after this many hours, auto-revert to safe mode
JOB_FILE=""
DRY_RUN="false"             # true = print what would run, but don't call claude

# Steps run in order. Each step is a prompt plus (optionally) its own
# conversation/dir, so a sequence can span several different conversations.
declare -a STEP_PROMPTS=()   # the prompt text for each step
declare -a STEP_SESSIONS=()  # per-step session_id ("" = use job-level SESSION_ID)
declare -a STEP_CWDS=()      # per-step cwd        ("" = use job-level WORKDIR)

# Scratch vars used while parsing a [step] block in a job file.
_CUR_SESSION=""; _CUR_CWD=""; _CUR_PROMPT=""; _HAVE_STEP="false"

SESSION_START=$(date +%s)
SKIP_EXPIRED_WARNED="false"

# ---------- little helpers ----------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { echo "[ERROR] $*" >&2; }

# Append a step (prompt, per-step session, per-step cwd).
add_step() { STEP_PROMPTS+=("$1"); STEP_SESSIONS+=("$2"); STEP_CWDS+=("$3"); }

# Flush a [step] block being parsed into the step arrays.
flush_step() {
  if [[ "$_HAVE_STEP" == "true" ]]; then
    if [[ -n "$_CUR_PROMPT" ]]; then
      add_step "$_CUR_PROMPT" "$_CUR_SESSION" "$_CUR_CWD"
    else
      err "a [step] block has no 'prompt:' line (ignored)"
    fi
  fi
  _CUR_SESSION=""; _CUR_CWD=""; _CUR_PROMPT=""; _HAVE_STEP="false"
}
truthy() { case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in true|yes|1|on) return 0;; *) return 1;; esac; }

# ---------- find the claude CLI even if it isn't on PATH ----------
# Handles the common case: Claude Code is installed but the shell that launched
# this script doesn't have its install dir on PATH. Covers both the native
# installer (~/.local/bin/claude.exe) and npm-global installs.
CLAUDE_BIN=""
resolve_claude() {
  # 1. On this shell's PATH?
  if command -v claude >/dev/null 2>&1; then
    CLAUDE_BIN="claude"
    return 0
  fi
  # 2. Anywhere on the Windows PATH? (Git Bash's PATH can differ from Windows'.)
  #    where.exe queries the real Windows PATH and only returns existing files.
  if command -v where.exe >/dev/null 2>&1; then
    local wpath
    wpath="$(where.exe claude 2>/dev/null | tr -d '\r' | head -1)"
    if [[ -n "$wpath" && "$wpath" != *WindowsApps* ]]; then
      CLAUDE_BIN="${wpath//\\//}"   # backslashes -> forward slashes for bash
      return 0
    fi
  fi
  # 3. Known install locations, even if not on any PATH.
  # $USERPROFILE is a Windows path (C:\Users\x); convert backslashes so bash
  # file tests can read it, in case $HOME differs from the Windows profile.
  local userprofile_unix="${USERPROFILE//\\//}"
  local candidates=(
    "$HOME/.local/bin/claude.exe"           # native installer (Windows)
    "$HOME/.local/bin/claude"               # native installer (macOS/Linux)
    "$userprofile_unix/.local/bin/claude.exe"
    "$APPDATA/npm/claude.cmd"               # npm -g (Windows)
    "$APPDATA/npm/claude"
    "$LOCALAPPDATA/Programs/claude/claude.exe"
    "$HOME/.claude/local/claude"
    "$HOME/.npm-global/bin/claude"
    "/c/Program Files/nodejs/claude.cmd"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -n "$c" && -f "$c" ]]; then
      CLAUDE_BIN="$c"
      return 0
    fi
  done
  return 1
}

# ---------- locate the folder Claude Code stores conversations in ----------
projects_dir() {
  local base="$HOME/.claude/projects"
  [[ -d "$base" ]] && { echo "$base"; return 0; }
  local up="${USERPROFILE//\\//}/.claude/projects"
  [[ -d "$up" ]] && { echo "$up"; return 0; }
  return 1
}

# ---------- --list: show recent conversations with ready-to-paste config ----------
# Reads each <session-id>.jsonl: session id = filename, cwd + first message come
# from inside the file, recency = file mtime. Optional filter matches cwd/preview.
list_conversations() {
  local filter="${1:-}" base
  base="$(projects_dir)" || { err "no conversations found under ~/.claude/projects"; return 1; }

  local -a files
  mapfile -t files < <(find "$base" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  if [[ ${#files[@]} -eq 0 ]]; then err "no conversation files found under $base"; return 1; fi

  echo "Recent Claude conversations (most recent first):"
  [[ -n "$filter" ]] && echo "(filtered by: \"$filter\")"

  local n=0 f sid cwd ts preview hay
  for f in "${files[@]}"; do
    sid="$(basename "$f" .jsonl)"
    cwd="$(grep -m1 -o '"cwd":"[^"]*"' "$f" | sed 's/^"cwd":"//; s/"$//; s/\\\\/\\/g')"
    preview="$(grep -m1 -oE '"content":"[^"]{0,120}' "$f" | sed 's/^"content":"//')"
    [[ -z "$preview" ]] && preview="$(grep -m1 -oE '"text":"[^"]{0,120}' "$f" | sed 's/^"text":"//')"
    preview="$(printf '%s' "$preview" | sed 's/\\n/ /g; s/\\t/ /g; s/\\"/"/g' | tr '\r\n\t' '   ')"

    if [[ -n "$filter" ]]; then
      hay="$(printf '%s %s' "$cwd" "$preview" | tr '[:upper:]' '[:lower:]')"
      [[ "$hay" == *"$(printf '%s' "$filter" | tr '[:upper:]' '[:lower:]')"* ]] || continue
    fi

    ts="$(date -d "@$(stat -c %Y "$f" 2>/dev/null)" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    n=$((n+1))
    (( n > 30 )) && { echo; echo "... (showing first 30; use '--list <word>' to filter)"; break; }
    printf '\n[%d] %s\n' "$n" "${ts:-?}"
    printf '    preview:    %.100s\n' "${preview:-<no text>}"
    printf '    session_id: %s\n' "$sid"
    printf '    cwd:        %s\n' "${cwd:-<unknown>}"
  done

  if (( n == 0 )); then echo; echo "No conversations matched."; return 0; fi
  echo
  echo "To use one: copy its session_id and cwd into a job file's 'session_id:' and 'cwd:' lines."
}

usage() {
  cat <<EOF
$SELF v$VERSION - schedule Claude CLI prompts around usage limits.

USAGE:
  $SELF --job path/to/job.conf         # run a saved job (recommended)
  $SELF --mode sequence --prompt "..." # quick one-off (repeat --prompt to queue)

OPTIONS:
  --job FILE                Load settings + prompts from a config file.
  --mode MODE               reset | time | sequence
  --at "YYYY-MM-DD HH:MM"   Target time for --mode time (local time).
  --prompt TEXT             A prompt to run. Repeat to queue several.
  --continue                Continue the MOST RECENT Claude conversation (claude -c).
  --session-id ID           Resume a SPECIFIC conversation (claude --resume ID).
                             Find the ID: it's the .jsonl filename under
                             %USERPROFILE%\.claude\projects\<encoded-path>\
  --cwd PATH                Directory to run claude in (a conversation belongs
                             to the project directory it was started in).
  --skip-permissions        Add --dangerously-skip-permissions to this run.
  --skip-hours N            Revert to safe mode after N hours (default 6).
  --dry-run                 Show what would happen without calling claude.
  --check                   Report whether bash/date/claude are found, then exit.
  --skip on [HOURS]         Manual master switch (this device): run jobs WITHOUT
  --skip off                permission prompts. 'on' stays until 'off'; 'on 6'
  --skip status             auto-reverts after 6h. 'status' shows current state.
  --list [WORD]             List recent conversations (session_id + cwd to copy
                             into a job file). Optional WORD filters by text/path.
  -h, --help                This help.
  -v, --version             Version.

Config file — one conversation (reset/time, or a same-conversation sequence):
  mode: reset
  session_id: 9cd41aa0-69f4-...      # from '--list'; the conversation to continue
  cwd: C:\Users\you\some-project      # that conversation's project folder
  prompts:
    First prompt on its own line
    Second prompt on its own line

Config file — a sequence spanning DIFFERENT conversations, in order:
  mode: sequence
  [step]
  session_id: AAAA-...
  cwd: C:\Users\you\project-a
  prompt: Do the thing in conversation A.
  [step]
  session_id: BBBB-...
  cwd: C:\Users\you\project-b
  prompt: Now do the follow-up in conversation B.

  Each [step] runs after the previous one finishes; a usage limit hit during
  any step waits for the reset, then resends that step before moving on.
  A [step] without its own session_id/cwd falls back to the job-level ones.
  Get session_id + cwd values from '--list'.

WARNING: --skip-permissions / skip_permissions:true lets prompts run tools with
no confirmation. Use it only in a trusted directory, and rely on skip_hours as a
safety net.
EOF
}

# ---------- load a job config file ----------
# Recognises three kinds of content:
#   top-level keys      (mode, run_at, session_id, cwd, ...)
#   a "prompts:" list   (each line = one step, using the job-level session/cwd)
#   one or more [step]  blocks (each has its own prompt + optional session_id/cwd)
load_job() {
  local f="$1" section="top" line key val
  [[ -f "$f" ]] || { err "job file not found: $f"; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                       # tolerate Windows CRLF line endings

    # Inside a "prompts:" list, each non-blank line is a step.
    if [[ "$section" == "prompts" ]]; then
      if [[ "$line" =~ ^[[:space:]]*\[step\][[:space:]]*$ ]]; then section="step"; _HAVE_STEP="true"; continue; fi
      [[ -z "${line//[[:space:]]/}" ]] && continue
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace only
      add_step "$line" "" ""
      continue
    fi

    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # Section markers.
    if [[ "$line" =~ ^[[:space:]]*\[step\][[:space:]]*$ ]]; then flush_step; section="step"; _HAVE_STEP="true"; continue; fi
    if [[ "$line" =~ ^[[:space:]]*prompts:[[:space:]]*$ ]]; then flush_step; section="prompts"; continue; fi

    key="${line%%:*}"; val="${line#*:}"
    key="$(echo "$key" | tr -d '[:space:]')"
    val="$(echo "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

    # Keys inside a [step] block set that step's fields.
    if [[ "$section" == "step" ]]; then
      case "$key" in
        session_id) _CUR_SESSION="$val" ;;
        cwd)        _CUR_CWD="$val" ;;
        prompt)     _CUR_PROMPT="$val" ;;
        *) err "unknown [step] key '$key' (ignored)";;
      esac
      continue
    fi

    # Top-level keys.
    case "$key" in
      mode)                    MODE="$val" ;;
      run_at)                  RUN_AT="$val" ;;
      continue)                CONTINUE="$val" ;;
      session_id)              SESSION_ID="$val" ;;
      cwd)                     WORKDIR="$val" ;;
      skip_permissions)        SKIP_PERMISSIONS="$val" ;;
      skip_permissions_hours)  SKIP_PERMISSIONS_HOURS="$val" ;;
      *) err "unknown config key '$key' (ignored)";;
    esac
  done < "$f"
  flush_step
}

# ---------- manual master switch (per device) ----------
# A small file records whether skip-permissions is turned ON for this machine.
# Kept in the user's home dir (NOT the repo), so each device controls its own
# switch and it never syncs an "off the brakes" state through git.
SKIP_STATE_DIR="$HOME/.claude-runner"
SKIP_STATE_FILE="$SKIP_STATE_DIR/skip.state"

# Is the manual master switch currently ON (and not expired)?
global_skip_active() {
  [[ -f "$SKIP_STATE_FILE" ]] || return 1
  local line until
  line="$(cat "$SKIP_STATE_FILE" 2>/dev/null)"
  [[ "$line" == on* ]] || return 1
  until="${line#on }"; until="${until//[!0-9]/}"; [[ -z "$until" ]] && until=0
  [[ "$until" == "0" ]] && return 0          # 0 = on until turned off
  (( $(date +%s) < until )) && return 0      # timed window still open
  return 1                                    # expired
}

# Turn the switch on/off or report it. Sends nothing.
skip_switch() {
  local action="$1" hours="${2:-}" until line
  mkdir -p "$SKIP_STATE_DIR" 2>/dev/null
  case "$action" in
    on)
      until=0
      if [[ "$hours" =~ ^[0-9]+$ ]] && (( hours > 0 )); then until=$(( $(date +%s) + hours*3600 )); fi
      echo "on $until" > "$SKIP_STATE_FILE"
      if (( until == 0 )); then
        echo "Skip-permissions: ON (until you turn it off) on THIS device."
      else
        echo "Skip-permissions: ON until $(date -d "@$until" '+%Y-%m-%d %H:%M') on THIS device."
      fi
      echo "⚠️  Jobs now run tools WITHOUT confirmation. Turn off with:  --skip off"
      ;;
    off)
      echo "off" > "$SKIP_STATE_FILE"
      echo "Skip-permissions: OFF (safe mode) on THIS device."
      ;;
    status)
      if global_skip_active; then
        line="$(cat "$SKIP_STATE_FILE")"; until="${line#on }"
        if [[ "$until" == "0" ]]; then echo "Skip-permissions: ON (until turned off) on THIS device."
        else echo "Skip-permissions: ON until $(date -d "@$until" '+%Y-%m-%d %H:%M') on THIS device."; fi
      else
        echo "Skip-permissions: OFF (safe mode) on THIS device."
      fi
      ;;
    *) err "usage: --skip on [HOURS] | off | status"; return 1 ;;
  esac
}

# ---------- decide if the skip flag applies right now ----------
effective_skip() {
  # The manual master switch (this device) wins if it's ON.
  if global_skip_active; then return 0; fi
  # Otherwise fall back to a job's own skip_permissions + its time cap.
  truthy "$SKIP_PERMISSIONS" || return 1
  local now cap
  now=$(date +%s)
  cap=$(( SESSION_START + SKIP_PERMISSIONS_HOURS * 3600 ))
  if (( now >= cap )); then
    if [[ "$SKIP_EXPIRED_WARNED" == "false" ]]; then
      log "Skip-permissions window (${SKIP_PERMISSIONS_HOURS}h) has expired -> reverting to SAFE mode."
      SKIP_EXPIRED_WARNED="true"
    fi
    return 1
  fi
  return 0
}

# ---------- parse a usage-limit message; echo the reset epoch, or nothing ----------
# Handles both the old "…reached|<epoch>" format and the newer "resets 3am (TZ)" text.
parse_limit_message() {
  local out="$1" ts
  if echo "$out" | grep -q "Claude AI usage limit reached|"; then
    ts="$(echo "$out" | awk -F'|' '{print $2}' | tr -dc '0-9')"
    [[ -n "$ts" ]] && { echo "$ts"; return 0; }
  fi
  if echo "$out" | grep -qE "(limit reached|hit your limit).*resets"; then
    local rt tz ap hh mm h24 now today
    rt="$(echo "$out" | grep -oiE "resets [0-9]{1,2}(:[0-9]{2})?[ap]m" | head -1 | awk '{print $2}')"
    [[ -z "$rt" ]] && return 1
    tz="$(echo "$out" | grep -oiE "resets [0-9:apm]+ \([^)]*\)" | grep -oE '\([^)]*\)' | tr -d '()' | head -1)"
    ap="$(echo "$rt" | grep -oiE '[ap]m')"
    if [[ "$rt" == *:* ]]; then
      hh="${rt%%:*}"; mm="$(echo "$rt" | sed 's/[ap]m//I' | cut -d: -f2)"
    else
      hh="$(echo "$rt" | sed 's/[ap]m//I')"; mm="0"
    fi
    h24="$hh"
    if [[ "$(echo "$ap" | tr 'A-Z' 'a-z')" == "am" ]]; then
      [[ "$hh" == "12" ]] && h24="0"
    else
      [[ "$hh" == "12" ]] || h24="$((hh + 12))"
    fi
    now=$(date +%s)
    if [[ -n "$tz" ]]; then today="$(TZ="$tz" date -d "today $h24:$mm:00" +%s 2>/dev/null)"; else today="$(date -d "today $h24:$mm:00" +%s 2>/dev/null)"; fi
    [[ -z "$today" ]] && return 1
    if (( now > today )); then
      if [[ -n "$tz" ]]; then ts="$(TZ="$tz" date -d "tomorrow $h24:$mm:00" +%s)"; else ts="$(date -d "tomorrow $h24:$mm:00" +%s)"; fi
    else
      ts="$today"
    fi
    echo "$ts"; return 0
  fi
  return 1
}

# ---------- low-CPU wait until an epoch (prints a status line ~once a minute) ----------
wait_until() {
  local target="$1" label="${2:-Waiting}" now remaining
  local when; when="$(date -d "@$target" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$target" '+%Y-%m-%d %H:%M' 2>/dev/null)"
  log "$label until $when ..."
  while :; do
    now=$(date +%s)
    remaining=$(( target - now ))
    (( remaining <= 0 )) && break
    printf '\r  [%s] %s  %02d:%02d:%02d remaining   ' "$(date '+%H:%M:%S')" "$label" \
      $((remaining/3600)) $(((remaining%3600)/60)) $((remaining%60))
    if (( remaining > 60 )); then sleep 60; else sleep "$remaining"; fi
  done
  printf '\r%*s\r' 60 ''   # clear the status line
}

# ---------- run one prompt via the claude CLI ----------
# args: prompt, session (may be ""), workdir (may be "")
run_claude() {
  local prompt="$1" session="$2" workdir="$3"
  local -a cmd=("$CLAUDE_BIN")
  if [[ -n "$session" ]]; then
    cmd+=(--resume "$session")        # resume one SPECIFIC conversation
  elif truthy "$CONTINUE"; then
    cmd+=(-c)                         # resume the MOST RECENT conversation only
  fi
  effective_skip && cmd+=(--dangerously-skip-permissions)
  cmd+=(-p "$prompt")
  if truthy "$DRY_RUN"; then
    echo "[DRY-RUN] would run (cwd=${workdir:-.}): ${cmd[*]}"
    return 0
  fi
  if [[ -n "$workdir" ]]; then
    ( cd "$workdir" && "${cmd[@]}" ) 2>&1
  else
    "${cmd[@]}" 2>&1
  fi
}

# ---------- run one prompt, retrying after a reset if a limit is hit ----------
# args: prompt, session, workdir
run_with_limit_handling() {
  local prompt="$1" session="$2" workdir="$3" out ts
  while :; do
    log "Sending prompt: ${prompt:0:70}$([[ ${#prompt} -gt 70 ]] && echo '…')"
    out="$(run_claude "$prompt" "$session" "$workdir")"
    printf '%s\n' "$out"
    ts="$(parse_limit_message "$out")"
    if [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > $(date +%s) )); then
      log "Usage limit detected."
      wait_until "$ts" "Waiting for reset"
      continue   # resend the same prompt now that the limit has lifted
    fi
    break
  done
}

run_sequence() {
  local total=${#STEP_PROMPTS[@]} i sess cwd
  for (( i=0; i<total; i++ )); do
    sess="${STEP_SESSIONS[$i]}"; [[ -z "$sess" ]] && sess="$SESSION_ID"
    cwd="${STEP_CWDS[$i]}";      [[ -z "$cwd"  ]] && cwd="$WORKDIR"
    log "--- Step $((i+1)) of $total ---"
    if [[ -n "$sess" ]]; then
      log "    -> conversation $sess${cwd:+ (in $cwd)}"
    elif truthy "$CONTINUE"; then
      log "    -> most-recent conversation${cwd:+ (in $cwd)}"
    else
      log "    -> new conversation${cwd:+ (in $cwd)}"
    fi
    run_with_limit_handling "${STEP_PROMPTS[$i]}" "$sess" "$cwd"
  done
  log "All $total step(s) complete."
}

# ---------- CLI parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --job)               JOB_FILE="$2"; shift 2 ;;
    --mode)              MODE="$2"; shift 2 ;;
    --at)                RUN_AT="$2"; shift 2 ;;
    --prompt)            add_step "$2" "" ""; shift 2 ;;
    --continue)          CONTINUE="true"; shift ;;
    --session-id)        SESSION_ID="$2"; shift 2 ;;
    --cwd)               WORKDIR="$2"; shift 2 ;;
    --skip-permissions)  SKIP_PERMISSIONS="true"; shift ;;
    --skip-hours)        SKIP_PERMISSIONS_HOURS="$2"; shift 2 ;;
    --dry-run)           DRY_RUN="true"; shift ;;
    --check)             CHECK_MODE="true"; shift ;;
    --skip)
      SKIP_SWITCH="true"
      case "${2:-}" in
        on|off|status) SKIP_ACTION="$2"; shift 2 ;;
        *)             SKIP_ACTION="status"; shift ;;
      esac
      if [[ "$SKIP_ACTION" == "on" && "${1:-}" =~ ^[0-9]+$ ]]; then SKIP_ACTION_HOURS="$1"; shift; fi
      ;;
    --list)
      LIST_MODE="true"
      if [[ -n "${2:-}" && "$2" != --* ]]; then LIST_FILTER="$2"; shift 2; else shift; fi
      ;;
    -h|--help)           usage; exit 0 ;;
    -v|--version)        echo "$SELF v$VERSION"; exit 0 ;;
    *) err "unknown argument: $1"; echo; usage; exit 1 ;;
  esac
done

# ---------- --skip: flip the manual master switch, send nothing ----------
if [[ "${SKIP_SWITCH:-false}" == "true" ]]; then
  skip_switch "${SKIP_ACTION:-status}" "${SKIP_ACTION_HOURS:-}"
  exit $?
fi

# ---------- --list: show conversations to copy session_id/cwd from ----------
if [[ "${LIST_MODE:-false}" == "true" ]]; then
  list_conversations "${LIST_FILTER:-}"
  exit $?
fi

# ---------- --check: report environment, send nothing ----------
if [[ "${CHECK_MODE:-false}" == "true" ]]; then
  echo "claude-runner v$VERSION environment check"
  echo "  bash            : $(bash --version 2>/dev/null | head -1)"
  echo -n "  date (GNU)      : "
  if date -d "today" +%s >/dev/null 2>&1; then echo "OK"; else echo "MISSING (waits/limit-parsing need GNU date)"; fi
  echo -n "  claude CLI      : "
  if resolve_claude; then
    echo "FOUND -> $CLAUDE_BIN"
  else
    echo "NOT FOUND (checked PATH + common install dirs)"
    echo "                    Run 'claude --version' in a normal terminal; if that works,"
    echo "                    tell me the path so I can add it to the search list."
  fi
  exit 0
fi

[[ -n "$JOB_FILE" ]] && load_job "$JOB_FILE"

# ---------- validate ----------
[[ -z "$MODE" ]] && { err "no mode set (use --mode or 'mode:' in the job file)"; exit 1; }
if [[ ${#STEP_PROMPTS[@]} -eq 0 ]]; then err "no prompts provided (add a 'prompts:' list or [step] blocks)"; exit 1; fi
if resolve_claude; then
  :
elif truthy "$DRY_RUN"; then
  CLAUDE_BIN="claude"   # dry-run doesn't need a real binary, just a label
else
  err "could not find the 'claude' CLI (checked PATH and common install locations)."
  err "Run 'claude --version' in a normal terminal to confirm how it's installed,"
  err "then tell me that path and I'll add it to the search list."
  exit 1
fi

# ---------- banner ----------
# Do any steps carry their own per-step conversation target?
per_step_targets="false"
for _s in "${STEP_SESSIONS[@]}"; do [[ -n "$_s" ]] && per_step_targets="true"; done
if [[ "$per_step_targets" == "true" ]]; then
  target_desc="per-step conversations"
elif [[ -n "$SESSION_ID" ]]; then
  target_desc="conversation $SESSION_ID"
elif truthy "$CONTINUE"; then
  target_desc="most-recent conversation"
else
  target_desc="new conversation"
fi
log "claude-runner v$VERSION | mode=$MODE | steps=${#STEP_PROMPTS[@]} | $target_desc"
if global_skip_active; then
  log "⚠️  SKIP-PERMISSIONS master switch is ON (this device) — tools run without confirmation. Turn off: --skip off"
elif truthy "$SKIP_PERMISSIONS"; then
  log "⚠️  SKIP-PERMISSIONS is ON for this job for up to ${SKIP_PERMISSIONS_HOURS}h (tools run without confirmation)."
else
  log "Permissions are ON (safe mode)."
fi
truthy "$DRY_RUN" && log "DRY-RUN: no real claude calls will be made."

# ---------- dispatch ----------
case "$MODE" in
  reset|sequence)
    run_sequence
    ;;
  time)
    [[ -z "$RUN_AT" ]] && { err "mode=time needs run_at / --at \"YYYY-MM-DD HH:MM\""; exit 1; }
    target="$(date -d "$RUN_AT" +%s 2>/dev/null)"
    [[ -z "$target" ]] && { err "could not understand run_at: '$RUN_AT'"; exit 1; }
    if (( target <= $(date +%s) )); then
      log "run_at is in the past — running immediately."
    else
      wait_until "$target" "Scheduled start"
    fi
    run_sequence
    ;;
  *)
    err "unknown mode: '$MODE' (use reset | time | sequence)"; exit 1 ;;
esac
