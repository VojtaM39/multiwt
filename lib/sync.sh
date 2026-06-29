# shellcheck shell=bash
# sync.sh — fetch origin, then rebase (or merge) each worktree on its upstream.

_sync_usage() {
  cat <<EOF
Usage: multiwt sync [--all]
EOF
}

cmd_sync() {
  local all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) all=1; shift ;;
      --verbose) MULTIWT_VERBOSE=1; shift ;;
      -h|--help) _sync_usage; return 0 ;;
      *) abort "unknown arg: $1" ;;
    esac
  done

  resolve_project

  local strategy
  strategy="$(cfg_get worktree.sync_strategy "rebase")"
  [[ "$strategy" == "rebase" || "$strategy" == "merge" ]] \
    || abort "invalid worktree.sync_strategy: $strategy (use rebase|merge)"

  info "fetching origin..."
  git -C "$MULTIWT_ROOT_PATH" fetch --all --prune

  local -a targets=()
  if [[ "$all" -eq 1 ]]; then
    local p
    while IFS= read -r p; do
      targets+=("$p")
    done < <(worktree_paths)
  else
    # Just the current worktree (PWD's worktree).
    local cur
    cur="$(git rev-parse --show-toplevel 2>/dev/null)"
    [[ -n "$cur" ]] || abort "not inside a git worktree"
    targets+=("$cur")
  fi

  local synced=0 skipped=0 conflicted=0 wt branch upstream base
  for wt in "${targets[@]}"; do
    branch="$(worktree_branch "$wt")"
    [[ -z "$branch" ]] && branch="(detached)"

    if is_main_worktree "$wt"; then
      vlog "skip main worktree: $wt"
      skipped=$((skipped + 1))
      continue
    fi

    if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
      warn "skip dirty worktree: $branch ($wt)"
      skipped=$((skipped + 1))
      continue
    fi

    upstream="$(worktree_upstream "$wt")"
    base="${upstream:-$(cfg_get worktree.base_ref "origin/main")}"

    if ! git -C "$wt" rev-parse --verify "$base" >/dev/null 2>&1; then
      warn "skip $branch: base ref '$base' not found"
      skipped=$((skipped + 1))
      continue
    fi

    info "syncing $branch onto $base ($strategy)..."
    set +e
    if [[ "$strategy" == "rebase" ]]; then
      git -C "$wt" rebase --autostash "$base"
    else
      git -C "$wt" merge --no-edit "$base"
    fi
    local rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
      warn "conflict in $branch — aborting and continuing"
      if [[ "$strategy" == "rebase" ]]; then
        git -C "$wt" rebase --abort 2>/dev/null || true
      else
        git -C "$wt" merge --abort 2>/dev/null || true
      fi
      conflicted=$((conflicted + 1))
    else
      synced=$((synced + 1))
    fi
  done

  printf '%ssynced %d, skipped %d, conflicted %d%s\n' "$C_BLD" "$synced" "$skipped" "$conflicted" "$C_RST"
  [[ "$conflicted" -eq 0 ]]
}
