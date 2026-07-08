# shellcheck shell=bash
# claude_state.sh — Claude Code session state files, written by
# `multiwt claude-hook` and read by `multiwt switch`.
#
# One file per Claude session at ~/.agentic/state/claude/<session_id>:
#   state=running|waiting|attention
#   cwd=/abs/path      launch dir of the session
#   pane=%12           tmux pane id; empty if launched outside tmux
#   ts=<epoch>         last hook event
#   msg=<text>         last notification message, single line
#   seen=<epoch>       last `multiwt next` visit; a session is only a jump
#                      candidate while ts > seen. Hook writes drop the field
#                      (new activity = unseen again).

claude_state_dir() { printf '%s/state/claude' "$(agentic_root)"; }

# Files older than this are garbage regardless of liveness checks — covers
# sessions started outside tmux, where we have no pane to verify against.
CLAUDE_STATE_MAX_AGE=$((7 * 24 * 3600))

claude_state_write() {
  local session_id="$1" state="$2" cwd="$3" pane="$4" msg="$5"
  local dir; dir="$(claude_state_dir)"
  mkdir -p "$dir"
  local f="$dir/$session_id" tmp="$dir/.$session_id.tmp.$$"
  {
    printf 'state=%s\n' "$state"
    printf 'cwd=%s\n' "$cwd"
    printf 'pane=%s\n' "$pane"
    printf 'ts=%s\n' "$(date +%s)"
    printf 'msg=%s\n' "$msg"
  } > "$tmp"
  mv "$tmp" "$f"
}

claude_state_delete() {
  rm -f "$(claude_state_dir)/$1"
}

# Like claude_state_write, but keeps the existing ts and seen stamps — for
# events that correct the state without representing new activity (the idle
# nudge). Freshness (ts vs seen) must not change.
claude_state_write_keep_clock() {
  local session_id="$1" state="$2" cwd="$3" pane="$4" msg="$5"
  local f old_ts old_seen
  f="$(claude_state_dir)/$session_id"
  old_ts="$(_claude_state_field "$f" ts)"
  old_seen="$(_claude_state_field "$f" seen)"
  claude_state_write "$session_id" "$state" "$cwd" "$pane" "$msg"
  local tmp="$f.tmp.$$"
  {
    grep -v '^ts=\|^seen=' "$f"
    printf 'ts=%s\n' "${old_ts:-$(date +%s)}"
    [[ -n "$old_seen" ]] && printf 'seen=%s\n' "$old_seen"
  } > "$tmp" && mv "$tmp" "$f"
}

# Delete state files whose cwd is (under) the given path. Used by `multiwt rm`.
claude_state_forget_path() {
  local root="$1" dir f cwd
  dir="$(claude_state_dir)"
  [[ -d "$dir" ]] || return 0
  shopt -s nullglob
  for f in "$dir"/*; do
    cwd="$(_claude_state_field "$f" cwd)"
    if [[ "$cwd" == "$root" || "$cwd" == "$root"/* ]]; then
      rm -f "$f"
    fi
  done
  shopt -u nullglob
}

_claude_state_field() {
  sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -n1
}

# Stamp seen=<now> on every state file recorded for the given pane.
claude_state_mark_seen() {
  local pane="$1" dir f now tmp
  [[ -z "$pane" || "$pane" == "-" ]] && return 0
  dir="$(claude_state_dir)"
  [[ -d "$dir" ]] || return 0
  now="$(date +%s)"
  shopt -s nullglob
  for f in "$dir"/*; do
    [[ "$(_claude_state_field "$f" pane)" == "$pane" ]] || continue
    # Dot-prefixed so a concurrent live_sessions scan never globs the tmp.
    tmp="$dir/.$(basename "$f").tmp.$$"
    { grep -v '^seen=' "$f"; printf 'seen=%s\n' "$now"; } > "$tmp" && mv "$tmp" "$f"
  done
  shopt -u nullglob
}

# Heuristic: does the process tree under <pid> contain a claude process?
# The pane holds a shell whose child (or grandchild, via wrappers) is claude.
_proc_tree_has_claude() {
  local pid="$1" depth="${2:-0}" kid
  [[ "$depth" -ge 3 ]] && return 1
  for kid in $(pgrep -P "$pid" 2>/dev/null); do
    if ps -o command= -p "$kid" 2>/dev/null | grep -q 'claude'; then
      return 0
    fi
    if _proc_tree_has_claude "$kid" $((depth + 1)); then
      return 0
    fi
  done
  return 1
}

# Print live sessions, one per line, tab-separated:
#   <session_id> <state> <cwd> <pane|-> <ts> <seen> <msg>
# Fields before <msg> are never empty ("-"/0 placeholders) so tab-parsing with
# `read` can't collapse them. GCs files for dead sessions as a side effect:
# a recorded pane that no longer exists, or exists without a claude process
# under it, means the session died without a SessionEnd hook (crash, kill).
claude_state_live_sessions() {
  local dir f sid state cwd pane ts seen msg now pane_pid
  dir="$(claude_state_dir)"
  [[ -d "$dir" ]] || return 0
  now="$(date +%s)"
  shopt -s nullglob
  for f in "$dir"/*; do
    sid="$(basename "$f")"
    state="$(_claude_state_field "$f" state)"
    cwd="$(_claude_state_field "$f" cwd)"
    pane="$(_claude_state_field "$f" pane)"
    ts="$(_claude_state_field "$f" ts)"
    seen="$(_claude_state_field "$f" seen)"
    msg="$(_claude_state_field "$f" msg)"
    if [[ -z "$state" || -z "$cwd" ]]; then
      rm -f "$f"; continue
    fi
    if [[ -n "$ts" ]] && (( now - ts > CLAUDE_STATE_MAX_AGE )); then
      rm -f "$f"; continue
    fi
    if [[ -n "$pane" ]] && tmux_available; then
      pane_pid="$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null || true)"
      if [[ -z "$pane_pid" ]] || ! _proc_tree_has_claude "$pane_pid"; then
        rm -f "$f"; continue
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$sid" "$state" "$cwd" "${pane:--}" "${ts:-0}" "${seen:-0}" "$msg"
  done
  shopt -u nullglob
}

# Urgency order for aggregation: attention > waiting > running.
claude_state_rank() {
  case "$1" in
    attention) echo 3 ;;
    waiting)   echo 2 ;;
    running)   echo 1 ;;
    *)         echo 0 ;;
  esac
}

# --- shared TUI helpers (fzf switcher + dashboard) -------------------------
# Colors are intentionally not tty-gated: consumers render them off-tty
# (fzf --ansi reads rows from a pipe; the dashboard builds frames in $(...)).
S_RED=$'\033[31m'; S_YEL=$'\033[33m'; S_GRN=$'\033[32m'; S_CYN=$'\033[36m'
S_DIM=$'\033[2m';  S_BLD=$'\033[1m';  S_RST=$'\033[0m'

claude_state_icon() {
  case "$1" in
    attention) printf '%s⚠%s' "$S_RED" "$S_RST" ;;
    waiting)   printf '%s◐%s' "$S_CYN" "$S_RST" ;;
    running)   printf '%s●%s' "$S_GRN" "$S_RST" ;;
    *)         printf '%s○%s' "$S_DIM" "$S_RST" ;;
  esac
}

claude_state_label() {
  case "$1" in
    attention) printf 'needs input' ;;
    waiting)   printf 'waiting' ;;
    running)   printf 'running' ;;
    *)         printf '-' ;;
  esac
}

claude_fmt_age() {
  local s="$1"
  if (( s < 0 )); then s=0; fi
  if (( s < 60 )); then
    printf '%ds' "$s"
  elif (( s < 3600 )); then
    printf '%dm' $((s / 60))
  elif (( s < 86400 )); then
    printf '%dh' $((s / 3600))
  else
    printf '%dd' $((s / 86400))
  fi
}
