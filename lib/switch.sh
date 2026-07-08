# shellcheck shell=bash
# switch.sh — global project/worktree switcher (fzf) with Claude Code session
# status. Unlike other commands this is cwd-independent: it scans every repo
# registered under ~/.agentic/repos/.
#
# fzf rows are tab-separated; hidden fields carry the action target:
#   1 mode      "w" = worktree row, "s" = claude-session row
#   2 wt_path   absolute worktree path
#   3 session   tmux session name ("-" when tmux is disabled for the repo)
#   4 pane      pane to jump to ("-" if none)
#   5 urgency   attention|waiting|running|-  (of that pane)
#   6 display   the only visible/matched field (ANSI colored)

. "$MULTIWT_LIB/claude_state.sh"

# Colors are always on here: rows/preview are consumed by fzf --ansi, whose
# stdin/stdout are pipes, so the tty-gated C_* vars from common.sh are empty.
S_YEL=$'\033[33m'; S_GRN=$'\033[32m'; S_CYN=$'\033[36m'
S_DIM=$'\033[2m';  S_BLD=$'\033[1m';  S_RST=$'\033[0m'

_switch_usage() {
  cat <<EOF
Usage: multiwt switch [--all]

Opens on worktrees with a live Claude session; --all starts with every
worktree instead. ctrl-w toggles between the two either way.

Internal flags (used by the fzf UI itself):
  --list <worktrees|sessions|active>   Print rows
  --toggle <state-file>                Flip active/all and print the new rows
  --relist <state-file>                Re-print current view (+ kill outcome)
  --kill <wt> <sess> <state-file>      Remove worktree + session if safe
  --preview <wt_path> <sess>           Render the preview panel
EOF
}

cmd_switch() {
  require_yq
  case "${1:-}" in
    --list)    shift; _switch_list "${1:-worktrees}" ;;
    --toggle)  shift; _switch_toggle "${1:?state file required}" ;;
    --relist)  shift; _switch_relist "${1:?state file required}" ;;
    --kill)    shift; _switch_kill "${1:?wt path}" "${2:?session}" "${3:?state file}" ;;
    --preview) shift; _switch_preview "$@" ;;
    --all)     _switch_ui worktrees ;;
    --active)  _switch_ui active ;;
    -h|--help) _switch_usage ;;
    "")        _switch_ui active ;;
    *)         abort "unknown arg: $1" ;;
  esac
}

# ctrl-w handler: flip the view recorded in the state file, print the new
# rows. (fzf 0.40 has no `transform`, so the current view lives in a file and
# the view indicator is the sticky header row, not the prompt.)
_switch_toggle() {
  local sf="$1" cur next
  cur="$(cat "$sf" 2>/dev/null || echo active)"
  if [[ "$cur" == "active" ]]; then next="worktrees"; else next="active"; fi
  printf '%s' "$next" > "$sf"
  _switch_list "$next"
}

# ctrl-x reload handler: re-list the current view, surfacing the outcome of
# the preceding --kill (left in "$sf.notice") in the header row.
_switch_relist() {
  local sf="$1" kind note=""
  kind="$(cat "$sf" 2>/dev/null || echo active)"
  if [[ -f "$sf.notice" ]]; then
    note="$(cat "$sf.notice")"
    rm -f "$sf.notice"
  fi
  _switch_list "$kind" "$note"
}

# ctrl-x action: remove worktree + tmux session, but only when it's safe —
# never the main worktree, never dirty (no --force here on purpose), never
# with a live claude session inside. Outcome goes to "$sf.notice" because
# execute-silent has no other channel back to the UI.
_switch_kill() {
  local wt="$1" sess="$2" sf="$3"
  local notice="$sf.notice"

  if [[ ! -d "$wt" ]]; then
    printf 'not removed — missing: %s' "$wt" > "$notice"; return 0
  fi
  local common main
  common="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -z "$common" ]]; then
    printf 'not removed — not a git worktree: %s' "$(basename "$wt")" > "$notice"; return 0
  fi
  [[ "$common" != /* ]] && common="$(cd "$wt" && cd "$common" && pwd -P)"
  main="$(dirname "$common")"
  if [[ "$(cd "$wt" && pwd -P)" == "$(cd "$main" && pwd -P)" ]]; then
    printf 'not removed — main worktree' > "$notice"; return 0
  fi

  local sid state cwd pane ts seen msg
  while IFS=$'\t' read -r sid state cwd pane ts seen msg; do
    if [[ "$cwd" == "$wt" || "$cwd" == "$wt"/* ]]; then
      printf 'not removed — claude session still running in %s' "$(basename "$wt")" > "$notice"
      return 0
    fi
  done < <(claude_state_live_sessions)

  if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
    printf 'not removed — dirty: %s' "$(basename "$wt")" > "$notice"; return 0
  fi

  local err_out
  if ! err_out="$(git -C "$main" worktree remove "$wt" 2>&1)"; then
    printf 'not removed — git: %s' "$(printf '%s' "$err_out" | head -n1)" > "$notice"
    return 0
  fi
  git -C "$main" worktree prune 2>/dev/null || true
  if [[ "$sess" != "-" ]] && tmux_available; then
    tmux_kill_session "$sess"
  fi
  claude_state_forget_path "$wt"
  printf 'removed: %s' "$(basename "$wt")" > "$notice"
}

_switch_ui() {
  local kind="$1"
  require_cmd fzf "Install via 'brew install fzf'."
  tmux_available || abort "tmux not available"

  local self_q sf sf_q
  printf -v self_q '%q' "$MULTIWT_BIN"
  sf="$(mktemp "${TMPDIR:-/tmp}/multiwt-switch.XXXXXX")"
  printf '%s' "$kind" > "$sf"
  printf -v sf_q '%q' "$sf"

  local out rc=0
  out="$(_switch_list "$kind" | fzf \
    --ansi --delimiter=$'\t' --with-nth=6 \
    --layout=reverse --info=inline \
    --header-lines=1 \
    --prompt='> ' \
    --preview="$self_q switch --preview {2} {3}" \
    --preview-window='right,45%,border-left' \
    --bind="ctrl-w:reload($self_q switch --toggle $sf_q)" \
    --bind="ctrl-s:reload($self_q switch --list sessions)" \
    --bind="ctrl-x:execute-silent($self_q switch --kill {2} {3} $sf_q)+reload($self_q switch --relist $sf_q)" \
  )" || rc=$?
  rm -f "$sf"
  [[ "$rc" -ne 0 || -z "$out" ]] && return 0

  local m wt sess pane urgency disp
  IFS=$'\t' read -r m wt sess pane urgency disp <<< "$out"
  _switch_go "$m" "$wt" "$sess" "$pane" "$urgency"
}

# Emit rows for every worktree of every registered repo. The first line is a
# view-indicator header consumed by fzf --header-lines=1, never selectable;
# an optional note (kill outcome) replaces the usual key hints there.
_switch_list() {
  local kind="$1" note="${2:-}"

  local label
  case "$kind" in
    active)   label="active" ;;
    sessions) label="claude sessions" ;;
    *)        label="all worktrees" ;;
  esac
  if [[ -n "$note" ]]; then
    printf '%s[%s]%s  %s%s%s\n' "$S_DIM" "$label" "$S_RST" "$S_YEL" "$note" "$S_RST"
  else
    printf '%s[%s]  ctrl-w: toggle · ctrl-s: sessions · ctrl-x: rm clean wt · enter: switch%s\n' \
      "$S_DIM" "$label" "$S_RST"
  fi

  # Load live claude sessions once; rows aggregate from this.
  local sessions=()
  local line
  while IFS= read -r line; do
    sessions+=("$line")
  done < <(claude_state_live_sessions)

  local repos_dir
  repos_dir="$(agentic_repos_dir)"
  shopt -s nullglob
  local cfgs=("$repos_dir"/*.yml "$repos_dir"/*.yaml)
  shopt -u nullglob
  if [[ ${#cfgs[@]} -eq 0 ]]; then
    warn "no repos registered under $repos_dir — run 'multiwt register' in each repo"
    return 0
  fi

  local f rpath rname renabled wt branch pline
  for f in "${cfgs[@]}"; do
    # Reuse the standard config merge, keyed off this file instead of cwd.
    MULTIWT_CONFIG_FILE="$f"
    build_merged_config
    rpath="$(cfg_get path)"; rpath="${rpath/#\~/$HOME}"
    [[ -d "$rpath" ]] || continue
    rname="$(cfg_get name "$(basename "$rpath")")"
    renabled="$(cfg_get worktree.tmux_enabled "true")"

    wt=""; branch=""
    while IFS= read -r pline; do
      case "$pline" in
        "worktree "*)          wt="${pline#worktree }" ;;
        "branch refs/heads/"*) branch="${pline#branch refs/heads/}" ;;
        "")
          if [[ -n "$wt" ]]; then
            [[ -z "$branch" ]] && branch="(detached)"
            _switch_emit_wt "$kind" "$rname" "$wt" "$branch" "$renabled"
          fi
          wt=""; branch=""
          ;;
      esac
    done < <(git -C "$rpath" worktree list --porcelain 2>/dev/null; echo)
  done
}

# Emit the row(s) for one worktree. Reads `sessions` from the caller's scope.
_switch_emit_wt() {
  local kind="$1" project="$2" wt="$3" branch="$4" tmux_enabled="$5"

  local sess="-"
  if [[ "$tmux_enabled" != "false" ]]; then
    sess="$(tmux_session_name "$branch")"
  fi

  local n_att=0 n_wait=0 n_run=0
  local best_pane="-" best_state="-" best_rank=0 best_ts=0
  local line sid state cwd pane ts seen msg rank
  if [[ ${#sessions[@]} -gt 0 ]]; then
    for line in "${sessions[@]}"; do
      IFS=$'\t' read -r sid state cwd pane ts seen msg <<< "$line"
      [[ "$cwd" == "$wt" || "$cwd" == "$wt"/* ]] || continue
      case "$state" in
        attention) n_att=$((n_att + 1)) ;;
        waiting)   n_wait=$((n_wait + 1)) ;;
        running)   n_run=$((n_run + 1)) ;;
      esac
      rank="$(claude_state_rank "$state")"
      if (( rank > best_rank )) || { (( rank == best_rank )) && (( ts > best_ts )); }; then
        best_rank="$rank"; best_ts="$ts"; best_pane="$pane"; best_state="$state"
      fi
      if [[ "$kind" == "sessions" ]]; then
        _switch_emit_session_row "$project" "$branch" "$wt" "$sess" "$state" "$pane" "$ts"
      fi
    done
  fi

  # Worktree row: always in the worktrees view; in the sessions view only as a
  # placeholder for worktrees with no claude session; in the active view only
  # for worktrees with a live tmux session (or a claude session outside tmux).
  local total=$((n_att + n_wait + n_run))
  if [[ "$kind" == "sessions" && "$total" -gt 0 ]]; then
    return 0
  fi

  local has_tmux=0
  if [[ "$sess" != "-" ]] && tmux_available && tmux_has_session "$sess"; then
    has_tmux=1
  fi
  if [[ "$kind" == "active" && "$has_tmux" -eq 0 && "$total" -eq 0 ]]; then
    return 0
  fi

  local agg=""
  if (( n_att  > 0 )); then agg+="${S_YEL}⚠${n_att}${S_RST} "; fi
  if (( n_wait > 0 )); then agg+="${S_CYN}◐${n_wait}${S_RST} "; fi
  if (( n_run  > 0 )); then agg+="${S_GRN}●${n_run}${S_RST} "; fi
  if [[ -z "$agg" ]]; then agg="${S_DIM}○${S_RST}"; fi

  local tmux_note=""
  if [[ "$sess" == "-" ]]; then
    tmux_note=" ${S_DIM}(tmux off)${S_RST}"
  elif [[ "$has_tmux" -eq 0 ]]; then
    tmux_note=" ${S_DIM}(no tmux)${S_RST}"
  fi

  local disp
  printf -v disp '%s%-12.12s%s ▸ %-28.28s %s%s' \
    "$S_BLD" "$project" "$S_RST" "$branch" "$agg" "$tmux_note"
  printf 'w\t%s\t%s\t%s\t%s\t%s\n' "$wt" "$sess" "$best_pane" "$best_state" "$disp"
}

_switch_emit_session_row() {
  local project="$1" branch="$2" wt="$3" sess="$4" state="$5" pane="$6" ts="$7"
  local now age disp
  now="$(date +%s)"
  age="$(_switch_fmt_age $((now - ts)))"
  printf -v disp '%s%-12.12s%s ▸ %-28.28s %s %-11s %s%-5s %4s%s' \
    "$S_BLD" "$project" "$S_RST" "$branch" \
    "$(_switch_state_icon "$state")" "$(_switch_state_label "$state")" \
    "$S_DIM" "$pane" "$age" "$S_RST"
  printf 's\t%s\t%s\t%s\t%s\t%s\n' "$wt" "$sess" "$pane" "$state" "$disp"
}

# Act on the selected row. Layout is never touched: we only create the session
# if missing, change focus (select-window / select-pane), and switch clients.
_switch_go() {
  local m="$1" wt="$2" sess="$3" pane="$4" urgency="$5"

  if [[ "$sess" == "-" ]]; then
    # tmux disabled for this repo — print the path so it's at least usable as
    # `cd "$(multiwt switch)"`.
    printf '%s\n' "$wt"
    return 0
  fi

  if ! tmux_has_session "$sess"; then
    tmux new-session -d -s "$sess" -c "$wt"
  fi

  local jump=0
  if [[ "$pane" != "-" && -n "$pane" ]]; then
    if [[ "$m" == "s" ]]; then
      jump=1
    elif [[ "$urgency" == "attention" || "$urgency" == "waiting" ]]; then
      jump=1
    fi
  fi

  local target="$sess"
  if [[ "$jump" -eq 1 ]]; then
    # The pane may have been moved to another session since the state file was
    # written; follow the pane, since it's the claude session we want.
    local pane_sess
    if pane_sess="$(tmux_focus_pane "$pane")"; then
      target="$pane_sess"
    fi
  fi

  tmux_attach_or_switch "$target"
}

_switch_preview() {
  local wt="${1:-}" sess="${2:--}"
  [[ -d "$wt" ]] || { printf 'missing: %s\n' "$wt"; return 0; }

  local branch
  branch="$(git -C "$wt" symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')"
  printf '%s%s%s\n' "$S_BLD" "$branch" "$S_RST"
  printf '%s%s%s\n\n' "$S_DIM" "$wt" "$S_RST"

  local dirty="clean"
  if [[ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]]; then
    dirty="${S_YEL}dirty${S_RST}"
  fi
  local upstream counts ahead="-" behind="-"
  upstream="$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")"
  if [[ -n "$upstream" ]]; then
    counts="$(git -C "$wt" rev-list --left-right --count "HEAD...$upstream" 2>/dev/null || echo "0	0")"
    ahead="${counts%%	*}"
    behind="${counts##*	}"
  fi
  printf 'git:    %s · ↑%s ↓%s\n' "$dirty" "$ahead" "$behind"
  printf 'last:   %s\n' "$(git -C "$wt" log -1 --pretty='%h %s (%cr)' 2>/dev/null || echo '-')"
  if [[ "$sess" != "-" ]]; then
    local sess_note="not created"
    tmux_available && tmux_has_session "$sess" && sess_note="live"
    printf 'tmux:   %s %s(%s)%s\n' "$sess" "$S_DIM" "$sess_note" "$S_RST"
  fi

  printf '\n%sclaude sessions%s\n' "$S_BLD" "$S_RST"
  local n=0 now sid state cwd pane ts seen msg
  now="$(date +%s)"
  while IFS=$'\t' read -r sid state cwd pane ts seen msg; do
    [[ "$cwd" == "$wt" || "$cwd" == "$wt"/* ]] || continue
    n=$((n + 1))
    printf '  %s %-11s %s%-5s %4s%s  %s\n' \
      "$(_switch_state_icon "$state")" "$(_switch_state_label "$state")" \
      "$S_DIM" "$pane" "$(_switch_fmt_age $((now - ts)))" "$S_RST" "$msg"
  done < <(claude_state_live_sessions)
  if [[ "$n" -eq 0 ]]; then
    printf '  %s(none)%s\n' "$S_DIM" "$S_RST"
  fi
}

_switch_state_icon() {
  case "$1" in
    attention) printf '%s⚠%s' "$S_YEL" "$S_RST" ;;
    waiting)   printf '%s◐%s' "$S_CYN" "$S_RST" ;;
    running)   printf '%s●%s' "$S_GRN" "$S_RST" ;;
    *)         printf '%s○%s' "$S_DIM" "$S_RST" ;;
  esac
}

_switch_state_label() {
  case "$1" in
    attention) printf 'needs input' ;;
    waiting)   printf 'waiting' ;;
    running)   printf 'running' ;;
    *)         printf '-' ;;
  esac
}

_switch_fmt_age() {
  local s="$1"
  if (( s < 0 )); then s=0; fi
  if (( s < 60 )); then
    printf '%ds' "$s"
  elif (( s < 3600 )); then
    printf '%dm' $((s / 60))
  elif (( s < 86400 )); then
    printf '%dh' $((s / 3600))
  else
    printf '%dd' $((s / 86400))
  fi
}
