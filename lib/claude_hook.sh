# shellcheck shell=bash
# claude_hook.sh — endpoint for Claude Code hooks. Reads the hook JSON payload
# from stdin and records per-session state under ~/.agentic/state/claude/.
# Wire-up lives in ~/.claude/settings.json — see README "Claude session status".
#
# Contract: never write to stdout (Claude Code injects UserPromptSubmit hook
# stdout into the model context) and always exit 0 (a broken install must
# never block or slow the Claude session).

. "$MULTIWT_LIB/claude_state.sh"

cmd_claude_hook() {
  set +e
  _claude_hook_run >/dev/null 2>&1
  exit 0
}

_claude_hook_run() {
  command -v yq >/dev/null 2>&1 || return 0
  local payload event sid cwd msg
  payload="$(cat)"
  [[ -z "$payload" ]] && return 0

  # One yq pass, one field per line; msg is truncated to its first line so it
  # can't break the line-oriented parse.
  {
    IFS= read -r event
    IFS= read -r sid
    IFS= read -r cwd
    IFS= read -r msg
  } < <(printf '%s' "$payload" | yq -p=json -r '
    (.hook_event_name // ""),
    (.session_id // ""),
    (.cwd // ""),
    ((.message // "") | split("\n") | .[0])
  ')

  sid="$(printf '%s' "${sid:-}" | tr -cd 'A-Za-z0-9._-')"
  [[ -z "$sid" ]] && return 0

  local state=""
  case "${event:-}" in
    SessionStart|Stop)
      state="waiting"; msg="" ;;
    UserPromptSubmit|PostToolUse)
      state="running"; msg="" ;;
    Notification)
      # The idle nudge is Claude waiting on you, not a blocking prompt like a
      # permission request — keep it one urgency level below "attention".
      if printf '%s' "${msg:-}" | grep -qi 'waiting for your input'; then
        state="waiting"
      else
        state="attention"
      fi
      ;;
    SessionEnd)
      claude_state_delete "$sid"; return 0 ;;
    *)
      return 0 ;;
  esac

  claude_state_write "$sid" "$state" "${cwd:-}" "${TMUX_PANE:-}" "${msg:-}"
}
