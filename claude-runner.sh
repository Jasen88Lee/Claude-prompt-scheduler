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

VERSION="1.1.0"
SELF="$(basename "$0")"

# ---------- settings (overridden by a job file or CLI flags) ----------
MODE=""                     # reset | time | sequence
RUN_AT=""                   # for mode=time: "YYYY-MM-DD HH:MM" (local time)
CONTINUE="false"            # true = use `claude -c` to continue the MOST RECENT chat
SESSION_ID=""               # if set, resume this exact conversation (claude --resume ID)
WORKDIR=""                  # directory to run claude in (conversations are per-project)
SKIP_PERMISSIONS="false"    # true = add --dangerously-skip-permissions
SKIP_PERMISSIONS_HOURS="6"  # after this many hours, auto-revert to safe mode
JOB_FILE=""
DRY_RUN="false"             # true = print what would run, but don't call claude
declare -a PROMPTS=()

SESSION_START=$(date +%s)
SKIP_EXPIRED_WARNED="false"

# ---------- little helpers ----------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
err()  { echo "[ERROR] $*" >&2; }
truthy() { case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in true|yes|1|on) return 0;; *) return 1;; esac; }

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
  -h, --help                This help.
  -v, --version             Version.

Config-file keys mirror the flags:
  mode: sequence
  run_at: 2026-07-03 09:00
  continue: false
  session_id: 9cd41aa0-69f4-45c2-991c-7ac11dd19b33
  cwd: C:\Users\Jasen Lee\some-project
  skip_permissions: false
  skip_permissions_hours: 6
  prompts:
    First prompt on its own line
    Second prompt on its own line

Targeting an EXISTING conversation (recommended for your use case):
  session_id takes priority over continue. Set cwd to the project folder that
  conversation belongs to (conversations are scoped per-directory), and
  session_id to that conversation's ID. If session_id is blank, continue:true
  falls back to "most recent conversation in cwd" — not a specific one.

WARNING: --skip-permissions / skip_permissions:true lets prompts run tools with
no confirmation. Use it only in a trusted directory, and rely on skip_hours as a
safety net.
EOF
}

# ---------- load a job config file ----------
load_job() {
  local f="$1" in_prompts="false" line key val
  [[ -f "$f" ]] || { err "job file not found: $f"; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                       # tolerate Windows CRLF line endings
    if [[ "$in_prompts" == "true" ]]; then
      [[ -z "${line//[[:space:]]/}" ]] && continue
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace only
      PROMPTS+=("$line")
      continue
    fi
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" =~ ^[[:space:]]*prompts:[[:space:]]*$ ]]; then in_prompts="true"; continue; fi
    key="${line%%:*}"; val="${line#*:}"
    key="$(echo "$key" | tr -d '[:space:]')"
    val="$(echo "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
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
}

# ---------- decide if the skip flag applies right now (respects the time cap) ----------
effective_skip() {
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
run_claude() {
  local prompt="$1"
  local -a cmd=(claude)
  if [[ -n "$SESSION_ID" ]]; then
    cmd+=(--resume "$SESSION_ID")     # resume one SPECIFIC conversation
  elif truthy "$CONTINUE"; then
    cmd+=(-c)                         # resume the MOST RECENT conversation only
  fi
  effective_skip && cmd+=(--dangerously-skip-permissions)
  cmd+=(-p "$prompt")
  if truthy "$DRY_RUN"; then
    echo "[DRY-RUN] would run (cwd=${WORKDIR:-.}): ${cmd[*]}"
    return 0
  fi
  if [[ -n "$WORKDIR" ]]; then
    ( cd "$WORKDIR" && "${cmd[@]}" ) 2>&1
  else
    "${cmd[@]}" 2>&1
  fi
}

# ---------- run one prompt, retrying after a reset if a limit is hit ----------
run_with_limit_handling() {
  local prompt="$1" out ts
  while :; do
    log "Sending prompt: ${prompt:0:70}$([[ ${#prompt} -gt 70 ]] && echo '…')"
    out="$(run_claude "$prompt")"
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
  local i=0
  for p in "${PROMPTS[@]}"; do
    i=$((i+1))
    log "--- Prompt $i of ${#PROMPTS[@]} ---"
    run_with_limit_handling "$p"
  done
  log "All ${#PROMPTS[@]} prompt(s) complete."
}

# ---------- CLI parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --job)               JOB_FILE="$2"; shift 2 ;;
    --mode)              MODE="$2"; shift 2 ;;
    --at)                RUN_AT="$2"; shift 2 ;;
    --prompt)            PROMPTS+=("$2"); shift 2 ;;
    --continue)          CONTINUE="true"; shift ;;
    --session-id)        SESSION_ID="$2"; shift 2 ;;
    --cwd)               WORKDIR="$2"; shift 2 ;;
    --skip-permissions)  SKIP_PERMISSIONS="true"; shift ;;
    --skip-hours)        SKIP_PERMISSIONS_HOURS="$2"; shift 2 ;;
    --dry-run)           DRY_RUN="true"; shift ;;
    -h|--help)           usage; exit 0 ;;
    -v|--version)        echo "$SELF v$VERSION"; exit 0 ;;
    *) err "unknown argument: $1"; echo; usage; exit 1 ;;
  esac
done

[[ -n "$JOB_FILE" ]] && load_job "$JOB_FILE"

# ---------- validate ----------
[[ -z "$MODE" ]] && { err "no mode set (use --mode or 'mode:' in the job file)"; exit 1; }
if [[ ${#PROMPTS[@]} -eq 0 ]]; then err "no prompts provided"; exit 1; fi
if ! command -v claude >/dev/null 2>&1 && ! truthy "$DRY_RUN"; then
  err "the 'claude' CLI was not found on PATH."; exit 1
fi

# ---------- banner ----------
if [[ -n "$SESSION_ID" ]]; then
  target_desc="resuming session $SESSION_ID"
elif truthy "$CONTINUE"; then
  target_desc="continuing most-recent conversation"
else
  target_desc="new conversation"
fi
[[ -n "$WORKDIR" ]] && target_desc="$target_desc in $WORKDIR"
log "claude-runner v$VERSION | mode=$MODE | prompts=${#PROMPTS[@]} | $target_desc"
if truthy "$SKIP_PERMISSIONS"; then
  log "⚠️  SKIP-PERMISSIONS is ON for up to ${SKIP_PERMISSIONS_HOURS}h (tools run without confirmation)."
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
