# shellcheck shell=bash
# up.sh — create-or-attach a worktree + tmux session.

_up_usage() {
  cat <<EOF
Usage: multiwt up <name> [--from <ref>] [--no-attach] [--no-install]
EOF
}

cmd_up() {
  local branch="" from="" attach=1 install=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="${2:?--from needs a ref}"; shift 2 ;;
      --no-attach) attach=0; shift ;;
      --no-install) install=0; shift ;;
      --verbose) MULTIWT_VERBOSE=1; shift ;;
      -h|--help) _up_usage; return 0 ;;
      -*) abort "unknown flag: $1" ;;
      *) [[ -z "$branch" ]] && branch="$1" || abort "unexpected arg: $1"; shift ;;
    esac
  done
  [[ -n "$branch" ]] || { _up_usage; return 1; }

  validate_branch_name "$branch"
  resolve_project
  tmux_probe

  local wt_path session
  wt_path="$(worktree_path_for "$branch")"
  session="$(tmux_session_name "$branch")"

  # If the worktree is registered with git, treat as "already exists" and skip
  # setup entirely.
  if [[ "$(worktree_registered "$wt_path")" == "yes" ]]; then
    ok "worktree exists: $wt_path"
    _up_attach_or_create_session "$session" "$wt_path" "$attach"
    return 0
  fi

  # Refuse to clobber a non-worktree directory at the target path.
  if [[ -e "$wt_path" ]]; then
    abort "path exists but is not a git worktree: $wt_path (refusing to clobber)"
  fi

  ensure_branch "$branch" "$from"

  info "creating worktree at: $wt_path"
  git -C "$MULTIWT_ROOT_PATH" worktree add "$wt_path" "$branch"

  _up_copy_env_files "$wt_path"

  if [[ "$install" -eq 1 ]]; then
    _up_run_setup "$wt_path" "$branch"
  else
    vlog "--no-install: skipping setup commands"
  fi

  _up_attach_or_create_session "$session" "$wt_path" "$attach"

  ok "✓ worktree: $wt_path"
  ok "✓ branch:   $branch"
  if [[ "$MULTIWT_TMUX_AVAILABLE" -eq 1 ]]; then
    ok "✓ tmux:     $session"
  fi
}

_up_copy_env_files() {
  local wt_path="$1"
  local rel src dst
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    src="$MULTIWT_ROOT_PATH/$rel"
    dst="$wt_path/$rel"
    if [[ ! -e "$src" ]]; then
      vlog "copy_env: missing source, skipping: $rel"
      continue
    fi
    mkdir -p "$(dirname "$dst")"
    if [[ -d "$src" ]]; then
      # Recursive copy, first-write wins: BSD cp -n skips existing files and
      # still exits 0, so pre-existing dest content is never refreshed.
      cp -Rn "$src/." "$dst/" 2>/dev/null || true
    else
      cp -n "$src" "$dst" 2>/dev/null || true
    fi
    vlog "copy_env: $rel"
  done < <(cfg_get_list worktree.copy_env)
}

_up_run_setup() {
  local wt_path="$1" branch="$2"
  local logs_dir
  logs_dir="$(runs_dir_for "$MULTIWT_PROJECT_NAME" "$(sanitize "$branch")")"
  local idx=0 cmd logfile rc
  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    idx=$((idx + 1))
    logfile="$logs_dir/setup-${idx}.log"
    info "setup [$idx]: $cmd"
    set +e
    ( cd "$wt_path" && bash -c "$cmd" ) 2>&1 | tee "$logfile"
    rc="${PIPESTATUS[0]}"
    set -e
    if [[ "$rc" -ne 0 ]]; then
      warn "setup command failed (exit $rc), continuing: $cmd"
      warn "  log: $logfile"
    fi
  done < <(cfg_get_list worktree.setup)
}

_up_attach_or_create_session() {
  local session="$1" dir="$2" attach="$3"
  if [[ "$MULTIWT_TMUX_AVAILABLE" -ne 1 ]]; then
    if [[ "${MULTIWT_TMUX_DISABLED:-0}" -eq 1 ]]; then
      vlog "tmux disabled by config (worktree.tmux_enabled: false); skipping session"
    else
      warn "tmux not available; skipping session creation"
    fi
    return 0
  fi
  tmux_create_session "$session" "$dir"
  if [[ "$attach" -eq 1 ]]; then
    tmux_attach_or_switch "$session"
  fi
}
