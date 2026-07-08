# shellcheck shell=bash
# rm.sh — remove worktree + tmux session.

. "$MULTIWT_LIB/claude_state.sh"

_rm_usage() {
  cat <<EOF
Usage: multiwt rm <name|path> [--purge] [--force]
EOF
}

cmd_rm() {
  local target="" purge=0 force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) purge=1; shift ;;
      --force) force=1; shift ;;
      --verbose) MULTIWT_VERBOSE=1; shift ;;
      -h|--help) _rm_usage; return 0 ;;
      -*) abort "unknown flag: $1" ;;
      *) [[ -z "$target" ]] && target="$1" || abort "unexpected arg: $1"; shift ;;
    esac
  done
  [[ -n "$target" ]] || { _rm_usage; return 1; }

  resolve_project
  tmux_probe

  local wt_path branch_slug
  if [[ -d "$target" ]]; then
    wt_path="$(cd "$target" && pwd -P)"
    # Try to recover branch name; fall back to basename of the path.
    branch_slug="$(worktree_branch "$wt_path" || true)"
    [[ -z "$branch_slug" ]] && branch_slug="$(basename "$wt_path")"
    branch_slug="$(sanitize "$branch_slug")"
  else
    validate_branch_name "$target"
    wt_path="$(worktree_path_for "$target")"
    branch_slug="$(sanitize "$target")"
  fi

  # Kill tmux session (using the same slug rule as `up`).
  local session
  session="$(tmux_session_name "$branch_slug")"
  if [[ "$MULTIWT_TMUX_AVAILABLE" -eq 1 ]] && tmux_has_session "$session"; then
    info "killing tmux session: $session"
    tmux_kill_session "$session"
  fi

  # Remove the worktree.
  if [[ -d "$wt_path" ]] || [[ "$(worktree_registered "$wt_path")" == "yes" ]]; then
    local args=(worktree remove "$wt_path")
    [[ "$force" -eq 1 ]] && args=(worktree remove --force "$wt_path")
    info "removing worktree: $wt_path"
    if ! git -C "$MULTIWT_ROOT_PATH" "${args[@]}"; then
      err "git worktree remove failed. Worktree may be dirty; retry with --force."
      return 1
    fi
  else
    warn "worktree path not found: $wt_path (continuing to prune/purge)"
  fi

  git -C "$MULTIWT_ROOT_PATH" worktree prune

  # Drop Claude session state recorded for this worktree.
  claude_state_forget_path "$wt_path"

  if [[ "$purge" -eq 1 ]]; then
    local runs_dir
    runs_dir="$(agentic_runs_dir)/$MULTIWT_PROJECT_NAME/$branch_slug"
    if [[ -d "$runs_dir" ]]; then
      info "purging runs dir: $runs_dir"
      rm -rf "$runs_dir"
    fi
  fi

  ok "✓ removed: $wt_path"
}
