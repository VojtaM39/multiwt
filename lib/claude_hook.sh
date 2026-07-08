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
  local payload event sid cwd msg tool
  payload="$(cat)"
  [[ -z "$payload" ]] && return 0

  # One yq pass, one field per line; msg is truncated to its first line so it
  # can't break the line-oriented parse.
  {
    IFS= read -r event
    IFS= read -r sid
    IFS= read -r cwd
    IFS= read -r tool
    IFS= read -r msg
  } < <(printf '%s' "$payload" | yq -p=json -r '
    (.hook_event_name // ""),
    (.session_id // ""),
    (.cwd // ""),
    (.tool_name // ""),
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
    PreToolUse)
      # Blocking dialogs that never produce a permission Notification
      # (especially under --dangerously-skip-permissions): a question or a
      # plan review means Claude is stuck on you right now.
      case "${tool:-}" in
        AskUserQuestion) state="attention"; msg="Claude is asking a question" ;;
        ExitPlanMode)    state="attention"; msg="Plan ready for review" ;;
        *) return 0 ;;
      esac
      ;;
    Notification)
      if printf '%s' "${msg:-}" | grep -qi 'waiting for your input'; then
        # The idle nudge carries no new information and can re-fire while a
        # session just sits there — it must never refresh freshness (that
        # made seen sessions randomly turn "new" again), never downgrade a
        # blocked session, and never touch an already-waiting one. It only:
        local cur
        cur="$(_claude_state_field "$(claude_state_dir)/$sid" state)"
        case "$cur" in
          attention|waiting)
            return 0 ;;
          running)
            # Correct a stale "running" (e.g. interrupted turn) but keep the
            # old ts/seen so it doesn't jump back to "unseen".
            claude_state_write_keep_clock "$sid" "waiting" "${cwd:-}" "${TMUX_PANE:-}" "${msg:-}"
            return 0 ;;
          *)
            # No state yet: session sitting at a prompt we never saw start.
            state="waiting" ;;
        esac
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
