# shellcheck shell=bash
# ls.sh — annotated worktree list.

cmd_ls() {
  resolve_project
  tmux_probe

  local fmt="%-50s  %-22s  %-5s  %5s  %6s  %4s\n"
  printf "$fmt" "PATH" "BRANCH" "DIRTY" "AHEAD" "BEHIND" "TMUX"

  local p branch upstream base ahead behind dirty tmux_has
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    branch="$(worktree_branch "$p")"
    [[ -z "$branch" ]] && branch="(detached)"

    upstream="$(worktree_upstream "$p")"
    if [[ -z "$upstream" ]]; then
      base="$(cfg_get worktree.base_ref "origin/main")"
    else
      base="$upstream"
    fi

    ahead="0"; behind="0"
    if git -C "$p" rev-parse --verify "$base" >/dev/null 2>&1; then
      local counts
      counts="$(git -C "$p" rev-list --left-right --count "HEAD...$base" 2>/dev/null || echo "0	0")"
      ahead="${counts%%	*}"
      behind="${counts##*	}"
    fi

    if [[ -n "$(git -C "$p" status --porcelain 2>/dev/null)" ]]; then
      dirty="*"
    else
      dirty=""
    fi

    tmux_has="no"
    if [[ "$MULTIWT_TMUX_AVAILABLE" -eq 1 ]]; then
      local sess; sess="$(tmux_session_name "$branch")"
      tmux_has_session "$sess" && tmux_has="yes"
    fi

    printf "$fmt" "$p" "$branch" "$dirty" "$ahead" "$behind" "$tmux_has"
  done < <(worktree_paths)
}
