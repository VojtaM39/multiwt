# shellcheck shell=bash
# register.sh — create/update a per-repo config under ~/.agentic/repos/.

_register_usage() {
  cat <<EOF
Usage:
  multiwt register [--name <slug>]   # initialize this repo
  multiwt register --refresh         # rewrite stale path: entries on this host
EOF
}

cmd_register() {
  local name="" refresh=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="${2:?--name needs a value}"; shift 2 ;;
      --refresh) refresh=1; shift ;;
      -h|--help) _register_usage; return 0 ;;
      *) abort "unknown arg: $1" ;;
    esac
  done

  require_yq

  if [[ "$refresh" -eq 1 ]]; then
    _register_refresh
    return 0
  fi

  _register_init "$name"
}

# Derive a kebab-case slug from `git remote get-url origin`.
_derive_name() {
  local url base
  url="$(git -C "$MULTIWT_ROOT_PATH" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    basename "$MULTIWT_ROOT_PATH"
    return
  fi
  base="$url"
  base="${base%.git}"          # trim .git suffix
  base="${base##*/}"           # last path segment
  base="${base##*:}"           # for scp-style git@host:org/repo
  # Lowercase + replace non-alnum with -.
  base="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
  [[ -z "$base" ]] && base="$(basename "$MULTIWT_ROOT_PATH")"
  printf '%s' "$base"
}

_register_init() {
  local name="$1"
  detect_root_path
  mkdir -p "$(agentic_repos_dir)"

  [[ -z "$name" ]] && name="$(_derive_name)"
  local target="$(agentic_repos_dir)/$name.yml"

  if [[ -f "$target" ]]; then
    local existing_path
    existing_path="$(yq -r '.path // ""' "$target")"
    existing_path="${existing_path/#\~/$HOME}"
    if [[ "$existing_path" == "$MULTIWT_ROOT_PATH" ]]; then
      ok "already registered: $target"
      _open_editor "$target"
      return 0
    else
      err "name collision: $target exists with path: $existing_path"
      abort "Re-run with --name <other>"
    fi
  fi

  # Write template atomically. Single-quote path/name so yaml-special chars
  # (':', '#', ...) can't break the document; escape embedded single quotes.
  local q_path q_name
  q_path="$(printf '%s' "$MULTIWT_ROOT_PATH" | sed "s/'/''/g")"
  q_name="$(printf '%s' "$name" | sed "s/'/''/g")"
  local tmp="${target}.tmp.$$"
  cat > "$tmp" <<EOF
path: '$q_path'
name: '$q_name'

# worktree:
#   parent_dir: ../worktrees
#   base_ref: origin/main
#   tmux_enabled: true
#   tmux_session_prefix: ""   # default: "<name>_"
#   copy_env:
#     - .env
#   setup:
#     - pnpm i
#   sync_strategy: rebase

# check:
#   base_ref: origin/main
#   stages: []

# pr:
#   owner: ""
#   repo: ""
EOF
  mv "$tmp" "$target"
  ok "wrote $target"
  _open_editor "$target"
}

_open_editor() {
  local f="$1"
  local editor="${EDITOR:-}"
  if [[ -z "$editor" ]]; then
    warn "EDITOR is not set; skipping editor. Edit manually: $f"
    return 0
  fi
  # shellcheck disable=SC2086
  $editor "$f"
}

_register_refresh() {
  local dir; dir="$(agentic_repos_dir)"
  [[ -d "$dir" ]] || abort "no repos dir at: $dir"

  local f cur new resolved
  shopt -s nullglob
  for f in "$dir"/*.yml "$dir"/*.yaml; do
    cur="$(yq -r '.path // ""' "$f")"
    if [[ -z "$cur" || "$cur" == "null" ]]; then
      warn "$(basename "$f"): no path: key, skipping"
      continue
    fi
    resolved="${cur/#\~/$HOME}"
    if [[ -d "$resolved" ]]; then
      info "ok: $(basename "$f") → $cur"
      continue
    fi
    warn "missing: $(basename "$f") → $cur"
    printf 'new path (or empty to skip): ' >&2
    if ! IFS= read -r new </dev/tty; then
      warn "no tty; skipping"
      continue
    fi
    [[ -z "$new" ]] && { info "skipped"; continue; }
    new="${new/#\~/$HOME}"
    if [[ ! -d "$new" ]]; then
      warn "not a directory; skipping"
      continue
    fi
    new="$(cd "$new" && pwd -P)"
    local tmp="${f}.tmp.$$"
    yq ".path = \"$new\"" "$f" > "$tmp" && mv "$tmp" "$f"
    ok "updated $(basename "$f"): $new"
  done
  shopt -u nullglob
}
