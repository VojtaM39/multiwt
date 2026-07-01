#!/usr/bin/env bash
# install.sh — symlink `multiwt` onto your $PATH.
#
# Usage:
#   ./install.sh                 # install to the first writable default bin dir
#   ./install.sh --dir <dir>     # install into <dir>
#   ./install.sh --uninstall     # remove the symlink
#
# The tool runs in place from this checkout; the installed entry is a symlink
# back to bin/multiwt, so `git pull` here updates the installed version too.
set -Eeuo pipefail

# --- resolve this repo (works regardless of where it's cloned) ---------------
SRC="${BASH_SOURCE[0]}"
while [[ -h "$SRC" ]]; do
  DIR="$(cd -P "$(dirname "$SRC")" && pwd)"
  SRC="$(readlink "$SRC")"
  [[ "$SRC" != /* ]] && SRC="$DIR/$SRC"
done
REPO_ROOT="$(cd -P "$(dirname "$SRC")" && pwd)"
TARGET="$REPO_ROOT/bin/multiwt"

# --- colors ------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  RED=""; YEL=""; GRN=""; DIM=""; RST=""
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$GRN" "$*" "$RST"; }
warn() { printf '%swarn:%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# --- args --------------------------------------------------------------------
INSTALL_DIR=""
UNINSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="${2:-}"; [[ -z "$INSTALL_DIR" ]] && die "--dir needs an argument"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,10p' "$SRC"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -f "$TARGET" ]] || die "cannot find $TARGET — run install.sh from inside the multiwt checkout"

# --- pick an install dir on $PATH --------------------------------------------
in_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }

pick_dir() {
  # Prefer a dir already on $PATH and writable; else the first that exists.
  local candidates=("$HOME/.local/bin" "$HOME/bin" "/usr/local/bin")
  local d
  for d in "${candidates[@]}"; do
    if [[ -d "$d" && -w "$d" ]] && in_path "$d"; then printf '%s' "$d"; return 0; fi
  done
  for d in "${candidates[@]}"; do
    if [[ -d "$d" && -w "$d" ]]; then printf '%s' "$d"; return 0; fi
  done
  # Fall back to ~/.local/bin, creating it.
  printf '%s' "$HOME/.local/bin"
}

[[ -z "$INSTALL_DIR" ]] && INSTALL_DIR="$(pick_dir)"
LINK="$INSTALL_DIR/multiwt"

# --- uninstall ---------------------------------------------------------------
if [[ "$UNINSTALL" -eq 1 ]]; then
  if [[ -L "$LINK" || -e "$LINK" ]]; then
    rm -f "$LINK" && ok "removed $LINK"
  else
    warn "nothing to remove at $LINK"
  fi
  exit 0
fi

# --- prereq check (warn only; the tool itself hard-checks at runtime) --------
missing=()
for c in git tmux yq bash; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  warn "missing prerequisites: ${missing[*]}"
  warn "install them before using multiwt (e.g. brew install ${missing[*]})"
fi

# --- link --------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
if [[ -e "$LINK" || -L "$LINK" ]]; then
  if [[ "$(readlink "$LINK" 2>/dev/null)" == "$TARGET" ]]; then
    ok "already installed: $LINK -> $TARGET"
  else
    warn "$LINK already exists; overwriting"
    ln -sf "$TARGET" "$LINK"
    ok "installed $LINK -> $TARGET"
  fi
else
  ln -s "$TARGET" "$LINK"
  ok "installed $LINK -> $TARGET"
fi

# --- PATH hint ---------------------------------------------------------------
if ! in_path "$INSTALL_DIR"; then
  warn "$INSTALL_DIR is not on your \$PATH"
  case "${SHELL:-}" in
    *zsh)  rc="~/.zshrc" ;;
    *bash) rc="~/.bash_profile" ;;
    *)     rc="your shell profile" ;;
  esac
  info "add this to $rc, then restart your shell:"
  printf '  %sexport PATH="%s:$PATH"%s\n' "$DIM" "$INSTALL_DIR" "$RST"
else
  info "run ${DIM}multiwt --help${RST} to get started"
fi
