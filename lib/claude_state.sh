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
    tmp="$f.tmp.$$"
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
