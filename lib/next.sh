# shellcheck shell=bash
# next.sh — jump to the next Claude session that needs you. Meant for a tmux
# keybind: bind g run-shell "multiwt next".
#
# Candidates are live sessions in an attention (permission prompt) or waiting
# (finished turn) state, ordered attention-first then longest-neglected.
# The pane you're currently on is skipped, so repeated presses cycle through
# every needy session. Layout is never touched.

. "$MULTIWT_LIB/claude_state.sh"

_next_usage() {
  cat <<EOF
Usage: multiwt next [--print]

  --print   Print the target pane id instead of jumping (for scripting)
EOF
}

# tmux pane-focus-in hook endpoint: mark any claude session in the focused
# pane as seen, however the user navigated there. Silent, always exits 0 —
# it runs on every focus change.
cmd_seen() {
  claude_state_mark_seen "${1:-}" >/dev/null 2>&1 || true
  exit 0
}

cmd_next() {
  local print=0
  case "${1:-}" in
    --print)   print=1 ;;
    -h|--help) _next_usage; return 0 ;;
    "")        ;;
    *)         abort "unknown arg: $1" ;;
  esac
  tmux_available || abort "tmux not available"

  local current
  current="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"

  # Panes on screen in an attached client right now count as seen — the user
  # is looking at them. (The pane-focus-in hook covers past visits; this is
  # the safety net for setups without it.)
  local visible=" " vp
  for vp in $(tmux list-panes -a -F \
      '#{?#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}},#{pane_id},}' \
      2>/dev/null); do
    visible+="$vp "
    [[ "$print" -eq 0 ]] && claude_state_mark_seen "$vp"
  done

  # fresh=1 rows are unvisited; fresh=0 rows still need action but were
  # already jumped to (counted so the "nothing new" message can say so).
  local fresh rank ts pane target="" pending=0
  while IFS=$'\t' read -r fresh rank ts pane; do
    [[ -z "$pane" ]] && continue
    if [[ "$fresh" == "1" && "$visible" != *" $pane "* ]]; then
      if [[ -z "$target" && "$pane" != "$current" ]]; then
        target="$pane"
      fi
    else
      pending=$((pending + 1))
    fi
  done < <(_next_candidates)

  if [[ "$print" -eq 1 ]]; then
    [[ -n "$target" ]] && printf '%s\n' "$target"
    return 0
  fi

  if [[ -z "$target" ]]; then
    local note="multiwt: no claude session needs attention"
    if [[ "$pending" -gt 0 ]]; then
      note="multiwt: nothing new ($pending pending you've already visited)"
    fi
    if [[ -n "${TMUX:-}" ]]; then
      # From a keybind, stderr output would pop up tmux's output view; a
      # status-line message is the right channel.
      tmux display-message "$note"
    else
      log "${note#multiwt: }"
    fi
    return 0
  fi

  # Retire the pane we're leaving: pressing g from it means "I've seen this".
  # It re-enters the rotation on its next hook event (new ts > seen).
  claude_state_mark_seen "$current"

  local sess
  if ! sess="$(tmux_focus_pane "$target")"; then
    abort "target pane vanished: $target"
  fi
  tmux_attach_or_switch "$sess"
}

# Print "fresh<TAB>rank<TAB>ts<TAB>pane" for every needy session, most urgent
# first, oldest event first within the same urgency.
_next_candidates() {
  local sid state cwd pane ts seen msg rank
  claude_state_live_sessions | while IFS=$'\t' read -r sid state cwd pane ts seen msg; do
    [[ "$pane" == "-" || -z "$pane" ]] && continue
    case "$state" in
      attention) rank=3 ;;
      waiting)   rank=2 ;;
      *)         continue ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$(( ts > seen ? 1 : 0 ))" "$rank" "$ts" "$pane"
  done | sort -t$'\t' -k2,2nr -k3,3n
}
