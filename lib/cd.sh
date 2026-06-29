# shellcheck shell=bash
# cd.sh — print the worktree path for a branch name. No side effects.

cmd_cd() {
  local name="${1:-}"
  [[ -n "$name" ]] || abort "Usage: multiwt cd <name>"
  validate_branch_name "$name"
  resolve_project
  local p; p="$(worktree_path_for "$name")"
  if [[ ! -d "$p" ]]; then
    abort "no worktree at: $p"
  fi
  printf '%s\n' "$p"
}
