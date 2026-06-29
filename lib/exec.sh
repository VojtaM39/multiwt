# shellcheck shell=bash
# exec.sh — run a command in every worktree of the current project, prefixing
# each output line with the worktree's branch name. Parallel by default.

_exec_usage() {
  cat <<EOF
Usage: multiwt exec <cmd>
EOF
}

cmd_exec() {
  if [[ $# -eq 0 ]]; then
    _exec_usage; return 1
  fi
  local cmd="$*"
  resolve_project

  local jobs
  jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

  local tmp
  tmp="$(mktemp -d -t multiwt-exec.XXXXXX)"

  # One status file per worktree (filename = sanitized path).
  worktree_paths \
    | xargs -I {} -P "$jobs" bash -c '
        wt="$1"; cmd="$2"; tmp="$3"
        slug="$(printf "%s" "$wt" | tr "/ " "__")"
        branch="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || echo "?")"
        ( cd "$wt" && bash -c "$cmd" ) 2>&1 | sed "s|^|[$branch] |"
        rc="${PIPESTATUS[0]}"
        printf "%s\n" "$rc" > "$tmp/$slug.rc"
      ' _ {} "$cmd" "$tmp"

  local failed=0 f rc
  shopt -s nullglob
  for f in "$tmp"/*.rc; do
    rc="$(cat "$f" 2>/dev/null || echo 0)"
    [[ "$rc" -ne 0 ]] && failed=$((failed + 1))
  done
  shopt -u nullglob

  rm -rf "$tmp"

  if [[ "$failed" -gt 255 ]]; then failed=255; fi
  return "$failed"
}
