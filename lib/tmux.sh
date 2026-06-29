# shellcheck shell=bash
# tmux.sh — tmux session helpers. All commands gracefully degrade if tmux is
# unavailable (controlled by the caller).

tmux_available() {
  command -v tmux >/dev/null 2>&1
}

# Sets MULTIWT_TMUX_AVAILABLE=1|0 once per command invocation.
tmux_probe() {
  if tmux_available && tmux list-sessions >/dev/null 2>&1; then
    MULTIWT_TMUX_AVAILABLE=1
  elif tmux_available; then
    # tmux exists but no server running. We can still create sessions.
    MULTIWT_TMUX_AVAILABLE=1
  else
    MULTIWT_TMUX_AVAILABLE=0
  fi
}

tmux_session_name() {
  local branch="$1"
  local prefix
  prefix="$(cfg_get worktree.tmux_session_prefix "")"
  # tmux disallows ':' and '.' in session names; normalize for safety.
  printf '%s%s' "$prefix" "$(sanitize "$branch")" | tr ':.' '__'
}

tmux_has_session() {
  local sess="$1"
  tmux has-session -t "=$sess" 2>/dev/null
}

# Count panes across all windows of a session. 0 if no session.
tmux_pane_count() {
  local sess="$1"
  if ! tmux_has_session "$sess"; then echo 0; return; fi
  tmux list-panes -s -t "=$sess" 2>/dev/null | wc -l | tr -d ' '
}

# Create a detached session in <dir> if it doesn't exist.
tmux_create_session() {
  local sess="$1" dir="$2"
  if tmux_has_session "$sess"; then return 0; fi
  tmux new-session -d -s "$sess" -c "$dir"
}

# Attach (if outside tmux) or switch-client (if inside).
tmux_attach_or_switch() {
  local sess="$1"
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "=$sess"
  else
    tmux attach -t "=$sess"
  fi
}

tmux_kill_session() {
  local sess="$1"
  if tmux_has_session "$sess"; then
    tmux kill-session -t "=$sess"
  fi
}
