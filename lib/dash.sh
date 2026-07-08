# shellcheck shell=bash
# dash.sh — always-on dashboard: projects → worktrees → claude sessions,
# continuously refreshed. Meant to live full-screen on a spare monitor.
#
# Everything re-scans every tick — no manual rescan, no stale views. Only
# active worktrees are shown: a live tmux session, or a claude session
# running outside tmux. Sessions needing input are painted red.
# Frames are drawn with home-cursor + erase-to-EOL, not clear-screen, so
# there is no flicker. bash 3.2-safe: no assoc arrays.

. "$MULTIWT_LIB/claude_state.sh"

_dash_usage() {
  cat <<EOF
Usage: multiwt dash [--interval <sec>] [--once]

  --interval <sec>   Refresh cadence (default 2)
  --once             Print a single frame to stdout and exit

Keys: q quit
EOF
}

cmd_dash() {
  local interval=2 once=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --interval) interval="${2:?--interval needs seconds}"; shift 2 ;;
      --once)     once=1; shift ;;
      -h|--help)  _dash_usage; return 0 ;;
      *)          abort "unknown arg: $1" ;;
    esac
  done
  require_yq

  if [[ "$once" -eq 1 ]]; then
    _dash_render
    return 0
  fi

  printf '\e[?1049h\e[?25l\e[?7l'   # alt screen, hide cursor, no autowrap
  trap 'printf "\e[?7h\e[?25h\e[?1049l"' EXIT
  trap 'exit 0' INT TERM

  local frame key
  while :; do
    frame="$(_dash_render)"
    # Home + redraw; every rendered line ends with erase-to-EOL, and erase-to-
    # end-of-screen clears leftovers from taller previous frames.
    printf '\e[H%s\n\e[0J' "$frame"

    key=""
    read -rsn1 -t "$interval" key || true
    case "$key" in
      q|Q) break ;;
    esac
  done
}

# Render one frame. Every line ends with erase-to-EOL so redraw-in-place
# leaves no residue.
_dash_render() {
  local eol=$'\033[K'
  local now
  now="$(date +%s)"

  printf '%smultiwt%s %s· %s · q quit%s%s\n%s\n' \
    "$S_BLD" "$S_RST" "$S_DIM" "$(date +%H:%M:%S)" "$S_RST" "$eol" "$eol"

  local repos_dir f
  repos_dir="$(agentic_repos_dir)"
  shopt -s nullglob
  local cfgs=("$repos_dir"/*.yml "$repos_dir"/*.yaml)
  shopt -u nullglob
  if [[ ${#cfgs[@]} -eq 0 ]]; then
    printf '%sno repos registered — run: multiwt register%s%s\n' "$S_DIM" "$S_RST" "$eol"
    return 0
  fi

  # Live sessions once per frame.
  local sessions=() line
  while IFS= read -r line; do
    sessions+=("$line")
  done < <(claude_state_live_sessions)

  local rpath rname renabled wt branch pline any=0
  for f in "${cfgs[@]}"; do
    MULTIWT_CONFIG_FILE="$f"
    build_merged_config
    rpath="$(cfg_get path)"; rpath="${rpath/#\~/$HOME}"
    [[ -d "$rpath" ]] || continue
    rname="$(cfg_get name "$(basename "$rpath")")"
    renabled="$(cfg_get worktree.tmux_enabled "true")"

    local printed_proj=0
    wt=""; branch=""
    while IFS= read -r pline; do
      case "$pline" in
        "worktree "*)          wt="${pline#worktree }" ;;
        "branch refs/heads/"*) branch="${pline#branch refs/heads/}" ;;
        "")
          if [[ -n "$wt" ]]; then
            [[ -z "$branch" ]] && branch="(detached)"
            if _dash_emit_wt "$rname" "$wt" "$branch" "$renabled" "$printed_proj"; then
              printed_proj=1
              any=1
            fi
          fi
          wt=""; branch=""
          ;;
      esac
    done < <(git -C "$rpath" worktree list --porcelain 2>/dev/null; echo)
  done

  if [[ "$any" -eq 0 ]]; then
    printf '%snothing active — no tmux sessions, no claude sessions%s%s\n' \
      "$S_DIM" "$S_RST" "$eol"
  fi
}

# Print the lines for one worktree if it's active (live tmux session, or a
# claude session even without tmux); return 1 to signal "skipped". Prints the
# project header before its first visible worktree ($5 says if already done).
# Reads `sessions` from the caller's scope.
_dash_emit_wt() {
  local proj="$1" wt="$2" branch="$3" tmux_enabled="$4" printed_proj="$5"
  local eol=$'\033[K'
  local now
  now="$(date +%s)"

  local sess="-" has_tmux=0
  if [[ "$tmux_enabled" != "false" ]]; then
    sess="$(tmux_session_name "$branch")"
    if tmux_available && tmux_has_session "$sess"; then
      has_tmux=1
    fi
  fi

  local line sid state cwd pane ts seen msg
  local n_att=0 n_wait=0 n_run=0
  if [[ ${#sessions[@]} -gt 0 ]]; then
    for line in "${sessions[@]}"; do
      IFS=$'\t' read -r sid state cwd pane ts seen msg <<< "$line"
      [[ "$cwd" == "$wt" || "$cwd" == "$wt"/* ]] || continue
      case "$state" in
        attention) n_att=$((n_att + 1)) ;;
        waiting)   n_wait=$((n_wait + 1)) ;;
        running)   n_run=$((n_run + 1)) ;;
      esac
    done
  fi
  local total=$((n_att + n_wait + n_run))

  # Active filter: hide worktrees with neither a tmux session nor claude.
  if [[ "$has_tmux" -eq 0 && "$total" -eq 0 ]]; then
    return 1
  fi

  if [[ "$printed_proj" -eq 0 ]]; then
    printf '%s%s%s%s\n' "$S_BLD" "$proj" "$S_RST" "$eol"
  fi

  local agg=""
  if (( n_att  > 0 )); then agg+="${S_RED}⚠${n_att}${S_RST} "; fi
  if (( n_wait > 0 )); then agg+="${S_CYN}◐${n_wait}${S_RST} "; fi
  if (( n_run  > 0 )); then agg+="${S_GRN}●${n_run}${S_RST} "; fi
  if [[ -z "$agg" ]]; then agg="${S_DIM}○${S_RST} "; fi

  local dirty_note=""
  if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
    dirty_note="${S_YEL}*${S_RST}"
  fi

  printf '  ▸ %-30.30s%s %s%s\n' "$branch" "$dirty_note" "$agg" "$eol"

  # Session detail lines; whole line red when it needs input.
  local lc
  if [[ ${#sessions[@]} -gt 0 ]]; then
    for line in "${sessions[@]}"; do
      IFS=$'\t' read -r sid state cwd pane ts seen msg <<< "$line"
      [[ "$cwd" == "$wt" || "$cwd" == "$wt"/* ]] || continue
      lc=""
      [[ "$state" == "attention" ]] && lc="$S_RED"
      printf '      %s %s%-11s %-5s %4s  %.60s%s%s\n' \
        "$(claude_state_icon "$state")" "${lc:-$S_DIM}" \
        "$(claude_state_label "$state")" "$pane" \
        "$(claude_fmt_age $((now - ts)))" "$msg" "$S_RST" "$eol"
    done
  fi
  return 0
}
