# shellcheck shell=bash
# status.sh — dashboard view with last-commit info and tmux pane count.

cmd_status() {
  resolve_project
  tmux_probe

  # Colors for stdout: common.sh gates C_* on stderr being a tty; the table
  # goes to stdout, so re-gate here.
  local o_bld="$C_BLD" o_yel="$C_YEL" o_rst="$C_RST"
  if [[ ! -t 1 ]]; then o_bld=""; o_yel=""; o_rst=""; fi

  local fmt="%-40s  %-20s  %-7s  %6s  %6s  %5s  %s"
  printf "%s${fmt}%s\n" "$o_bld" "BRANCH" "WORKTREE" "DIRTY" "AHEAD" "BEHIND" "PANES" "LAST COMMIT" "$o_rst"

  local p branch upstream base ahead behind dirty panes last short_p
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
      dirty="${o_yel}*${o_rst}"
    else
      dirty=" "
    fi

    panes=0
    if [[ "$MULTIWT_TMUX_AVAILABLE" -eq 1 ]]; then
      local sess; sess="$(tmux_session_name "$branch")"
      panes="$(tmux_pane_count "$sess")"
    fi

    last="$(git -C "$p" log -1 --pretty='%h %s' 2>/dev/null || echo "")"
    short_p="${p#"$HOME"}"; [[ "$short_p" != "$p" ]] && short_p="~$short_p"
    # Truncate path for table layout.
    if [[ ${#short_p} -gt 40 ]]; then short_p="...${short_p: -37}"; fi

    printf "${fmt}\n" "$branch" "$short_p" "$dirty" "$ahead" "$behind" "$panes" "$last"
  done < <(worktree_paths)
}
