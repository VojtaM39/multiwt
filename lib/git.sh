# shellcheck shell=bash
# git.sh — git/worktree helpers. All paths use absolute form.

git_local_branch_exists() {
  git -C "$MULTIWT_ROOT_PATH" show-ref --verify --quiet "refs/heads/$1"
}

git_remote_branch_exists() {
  git -C "$MULTIWT_ROOT_PATH" ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1
}

# Compute the worktree path for a branch using the resolved config.
# Echoes an absolute path; creates the parent dir if necessary.
worktree_path_for() {
  local branch="$1"
  local parent
  parent="$(cfg_get worktree.parent_dir "../worktrees")"
  local abs
  if [[ "$parent" = /* ]]; then
    abs="$parent"
  else
    abs="$MULTIWT_ROOT_PATH/$parent"
  fi
  mkdir -p "$abs"
  local slug; slug="$(sanitize "$branch")"
  printf '%s/%s' "$(cd "$abs" && pwd -P)" "$slug"
}

# Echoes "yes" if any git worktree's absolute path equals the given path.
worktree_registered() {
  local target="$1"
  git -C "$MULTIWT_ROOT_PATH" worktree list --porcelain \
    | awk '/^worktree /{print substr($0,10)}' \
    | while IFS= read -r p; do
        [[ -d "$p" ]] || continue
        local rp; rp="$(cd "$p" && pwd -P)"
        if [[ "$rp" == "$target" ]]; then echo yes; break; fi
      done
}

# Iterate every worktree path of the current project, one absolute path per
# line. Includes the main worktree.
worktree_paths() {
  git -C "$MULTIWT_ROOT_PATH" worktree list --porcelain \
    | awk '/^worktree /{print substr($0,10)}'
}

# Branch name for a worktree path (best-effort; empty for detached).
worktree_branch() {
  local p="$1"
  git -C "$p" symbolic-ref --short HEAD 2>/dev/null || echo ""
}

# Upstream for a worktree path; empty if none.
worktree_upstream() {
  local p="$1"
  git -C "$p" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo ""
}

# Determine if a worktree path is the main repo working tree.
is_main_worktree() {
  local p="$1"
  [[ "$(cd "$p" && pwd -P)" == "$MULTIWT_ROOT_PATH" ]]
}

# Create the branch if needed using the standard fallback chain.
# Args: <branch> <base_ref_override-or-empty>
ensure_branch() {
  local name="$1" base_override="${2:-}"
  if git_local_branch_exists "$name"; then
    # Reusing an old branch means old code — make its age visible.
    info "using existing local branch: $name ($(git -C "$MULTIWT_ROOT_PATH" log -1 --format='%h, %cr' "$name"))"
    return 0
  fi
  if git_remote_branch_exists "$name"; then
    info "fetching origin/$name as tracking branch"
    git -C "$MULTIWT_ROOT_PATH" fetch origin "$name:$name"
    return 0
  fi
  local base
  base="${base_override:-$(cfg_get worktree.base_ref "origin/main")}"
  info "creating branch '$name' from '$base'"
  git -C "$MULTIWT_ROOT_PATH" branch --no-track "$name" "$base"
}
