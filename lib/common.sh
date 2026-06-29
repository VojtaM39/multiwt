# shellcheck shell=bash
# common.sh — logging, sanitization, path helpers.

: "${MULTIWT_VERBOSE:=0}"

_supports_color() {
  [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]
}

if _supports_color; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
  C_CYN=$'\033[36m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_YEL=""; C_GRN=""; C_CYN=""; C_DIM=""; C_BLD=""; C_RST=""
fi

log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s%s%s\n' "$C_CYN" "$*" "$C_RST" >&2; }
ok()   { printf '%s%s%s\n' "$C_GRN" "$*" "$C_RST" >&2; }
warn() { printf '%swarn:%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%serror:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
abort(){ err "$*"; exit 1; }
vlog() { [[ "$MULTIWT_VERBOSE" -eq 1 ]] && printf '%s%s%s\n' "$C_DIM" "$*" "$C_RST" >&2 || true; }

# Translate a branch name into a filesystem/tmux-safe slug.
sanitize() {
  printf '%s' "$1" | tr '/:' '-'
}

# Reject branch names with characters we don't want to deal with.
validate_branch_name() {
  local name="$1"
  if [[ -z "$name" ]]; then
    abort "branch name is empty"
  fi
  if [[ "$name" =~ [[:space:]\#\?\~\^\*\\] ]]; then
    abort "branch name '$name' contains forbidden characters (space, #, ?, ~, ^, *, backslash)"
  fi
}

# Ensure an external command exists; abort with a hint if not.
require_cmd() {
  local cmd="$1" hint="${2:-}"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  if [[ -n "$hint" ]]; then
    abort "required command '$cmd' not found. $hint"
  else
    abort "required command '$cmd' not found"
  fi
}

# Roots under ~/.agentic/.
agentic_root() { printf '%s' "${MULTIWT_AGENTIC_ROOT:-$HOME/.agentic}"; }
agentic_repos_dir() { printf '%s/repos' "$(agentic_root)"; }
agentic_runs_dir()  { printf '%s/runs'  "$(agentic_root)"; }

# Per-branch runs dir for this project; auto-created.
runs_dir_for() {
  local project="$1" branch_slug="$2"
  local dir
  dir="$(agentic_runs_dir)/$project/$branch_slug/multiwt"
  mkdir -p "$dir"
  printf '%s' "$dir"
}
