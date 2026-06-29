# shellcheck shell=bash
# config.sh — repo resolution + deep merge with global defaults.
#
# Public API:
#   resolve_project       Sets globals:
#     MULTIWT_ROOT_PATH       canonical main-repo working-tree path
#     MULTIWT_PROJECT_NAME    config `name:` (or derived fallback)
#     MULTIWT_CONFIG_FILE     resolved per-repo yaml (or empty if none)
#     MULTIWT_MERGED_CONFIG   merged yaml (defaults + per-repo) as a tempfile path
#   cfg_get <key> [default]   yq getter against MULTIWT_MERGED_CONFIG.
#   cfg_get_list <key>        Print list items, one per line.

require_yq() {
  require_cmd yq "Install via 'brew install yq' (mikefarah/yq, Go version)."
  # Sanity: ensure it's the Go yq (mikefarah), not the python one.
  if ! yq --version 2>/dev/null | grep -qi mikefarah; then
    abort "yq must be the Go version from mikefarah/yq. Found: $(yq --version 2>&1 | head -n1)"
  fi
}

# Resolve canonical repo root from any worktree.
# Sets: MULTIWT_ROOT_PATH
detect_root_path() {
  local common_dir top
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
  if [[ -z "$common_dir" ]]; then
    abort "not inside a git repository"
  fi
  # Bare repos: git-common-dir is the repo itself (ends in .git typically) and
  # has no working tree.
  if [[ "$(git rev-parse --is-bare-repository 2>/dev/null)" == "true" ]]; then
    abort "bare repos not supported"
  fi
  # If we're already in the main worktree, git-common-dir is relative; resolve
  # it against PWD.
  if [[ "$common_dir" != /* ]]; then
    common_dir="$(cd "$common_dir" && pwd)"
  fi
  top="$(dirname "$common_dir")"
  MULTIWT_ROOT_PATH="$(cd "$top" && pwd -P)"
}

# Find a per-repo config file whose `path:` equals MULTIWT_ROOT_PATH.
# Sets: MULTIWT_CONFIG_FILE (may be empty).
find_repo_config() {
  MULTIWT_CONFIG_FILE=""
  local dir; dir="$(agentic_repos_dir)"
  if [[ -d "$dir" ]]; then
    local f cfg_path
    shopt -s nullglob
    for f in "$dir"/*.yml "$dir"/*.yaml; do
      cfg_path="$(yq -r '.path // ""' "$f" 2>/dev/null || echo "")"
      if [[ -n "$cfg_path" ]]; then
        cfg_path="${cfg_path/#\~/$HOME}"
        # realpath -m so missing dirs don't abort the scan
        local resolved
        resolved="$(cd "$cfg_path" 2>/dev/null && pwd -P || echo "$cfg_path")"
        if [[ "$resolved" == "$MULTIWT_ROOT_PATH" ]]; then
          MULTIWT_CONFIG_FILE="$f"
          shopt -u nullglob
          return 0
        fi
      fi
    done
    shopt -u nullglob
  fi
  # In-repo fallback.
  if [[ -f "$MULTIWT_ROOT_PATH/.agentic.yml" ]]; then
    MULTIWT_CONFIG_FILE="$MULTIWT_ROOT_PATH/.agentic.yml"
  fi
}

# Deep-merge ~/.agentic/config.yml's `defaults:` block (as the base) with the
# per-repo file (as the override). Lists are replaced, not concatenated.
# Sets: MULTIWT_MERGED_CONFIG (tempfile path).
build_merged_config() {
  local globals defaults_yaml repo_yaml merged tmpdir
  tmpdir="$(mktemp -d -t multiwt.XXXXXX)"
  # Track for cleanup on exit.
  if [[ -z "${MULTIWT_TMPDIRS:-}" ]]; then
    MULTIWT_TMPDIRS="$tmpdir"
    trap '_multiwt_cleanup_tmp' EXIT
  else
    MULTIWT_TMPDIRS="$MULTIWT_TMPDIRS:$tmpdir"
  fi
  defaults_yaml="$tmpdir/defaults.yml"
  repo_yaml="$tmpdir/repo.yml"
  merged="$tmpdir/merged.yml"

  globals="$(agentic_root)/config.yml"
  if [[ -f "$globals" ]]; then
    yq '.defaults // {}' "$globals" > "$defaults_yaml"
  else
    printf '{}\n' > "$defaults_yaml"
  fi

  if [[ -n "$MULTIWT_CONFIG_FILE" ]]; then
    cp "$MULTIWT_CONFIG_FILE" "$repo_yaml"
  else
    printf '{}\n' > "$repo_yaml"
  fi

  # yq deep merge: defaults * repo. The `*=` style with no flags would
  # concatenate lists; `*n` replaces nulls; we want "repo wins, lists
  # replaced" → use eval with explicit merge expression.
  yq eval-all '
    select(fileIndex == 0) * select(fileIndex == 1)
  ' "$defaults_yaml" "$repo_yaml" > "$merged"

  MULTIWT_MERGED_CONFIG="$merged"
}

_multiwt_cleanup_tmp() {
  [[ -n "${MULTIWT_TMPDIRS:-}" ]] || return 0
  local d
  IFS=: read -r -a _dirs <<< "$MULTIWT_TMPDIRS"
  for d in "${_dirs[@]}"; do
    [[ -d "$d" ]] && rm -rf "$d"
  done
}

# Read a key from the merged config. Returns "" if missing.
# Usage: cfg_get worktree.parent_dir [default]
cfg_get() {
  local key="$1" def="${2:-}"
  local out
  out="$(yq -r ".${key}" "$MULTIWT_MERGED_CONFIG" 2>/dev/null || echo "")"
  if [[ -z "$out" || "$out" == "null" ]]; then
    printf '%s' "$def"
  else
    printf '%s' "$out"
  fi
}

# Read a list, one item per line. Empty if missing/null.
cfg_get_list() {
  local key="$1"
  yq -r ".${key}[]?" "$MULTIWT_MERGED_CONFIG" 2>/dev/null || true
}

# Top-level resolver. Aborts with a clear pointer if no config is found.
resolve_project() {
  require_yq
  detect_root_path
  find_repo_config

  if [[ -z "$MULTIWT_CONFIG_FILE" ]]; then
    err "No agentic config for this repo at: $MULTIWT_ROOT_PATH"
    abort "Run: multiwt register"
  fi

  build_merged_config

  MULTIWT_PROJECT_NAME="$(yq -r '.name // ""' "$MULTIWT_CONFIG_FILE")"
  if [[ -z "$MULTIWT_PROJECT_NAME" || "$MULTIWT_PROJECT_NAME" == "null" ]]; then
    MULTIWT_PROJECT_NAME="$(basename "$MULTIWT_ROOT_PATH")"
  fi
}
