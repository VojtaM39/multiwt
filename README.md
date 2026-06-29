# multiwt

One command to spin up (or tear down) a git worktree + tmux session, with env
files copied and setup hooks run.

## Prereqs

- `git` ≥ 2.20
- `tmux`
- `yq` (mikefarah, Go version) — `brew install yq`
- `bash` ≥ 4

## Install

Add `bin/` to your `$PATH`:

```bash
echo 'export PATH="$HOME/agentic/tools/multiwt/bin:$PATH"' >> ~/.bash_profile
```

Then in any git repo:

```bash
multiwt register     # writes ~/.agentic/repos/<slug>.yml, opens $EDITOR
multiwt up feat/foo  # creates worktree + tmux session, attaches
```

## Commands

| Command                                  | What it does                                                        |
| ---------------------------------------- | ------------------------------------------------------------------- |
| `multiwt up <name> [--from <ref>]`       | Create worktree + branch + tmux session, copy env, run setup, attach |
| `multiwt up <name> --no-attach`          | Same, but don't attach to tmux                                       |
| `multiwt up <name> --no-install`         | Skip `worktree.setup` commands                                       |
| `multiwt rm <name\|path> [--force]`      | Kill tmux session, `git worktree remove`. `--force` for dirty trees |
| `multiwt rm <name> --purge`              | Also delete `~/.agentic/runs/<project>/<branch>/`                    |
| `multiwt ls`                             | Worktrees with DIRTY / AHEAD / BEHIND / TMUX columns                 |
| `multiwt status`                         | Dashboard: branch, dirty, ahead/behind, pane count, last commit      |
| `multiwt sync [--all]`                   | Fetch + rebase current (or all) worktrees on upstream                |
| `multiwt exec <cmd>`                     | Run `<cmd>` in every worktree, prefix output with branch (parallel)  |
| `multiwt cd <name>`                      | Print the worktree path — use as `cd "$(multiwt cd feat/foo)"`       |
| `multiwt register [--name <slug>]`       | Initialize this repo's config                                        |
| `multiwt register --refresh`             | Walk `~/.agentic/repos/`, rewrite stale `path:` entries              |

`multiwt up` is idempotent: re-running on an existing worktree just re-attaches.
To rebuild, `multiwt rm` then `multiwt up`.

## Config

Per-repo config lives at `~/.agentic/repos/<name>.yml`; global defaults at
`~/.agentic/config.yml` deep-merge underneath.

```yaml
path: /Users/me/code/myproj       # required, canonical lookup key
name: myproj                      # required, used for tmux prefix and runs/

worktree:
  parent_dir: ../worktrees        # default
  base_ref: origin/main           # default
  tmux_session_prefix: ""         # e.g. "myproj-" for collision protection
  copy_env:                       # files/dirs to copy from main worktree
    - .env
    - apps/backend/.env
  setup:                          # run sequentially in the new worktree
    - pnpm i
    - pnpm db:generate
  sync_strategy: rebase           # or "merge"
```

In-repo `<repo>/.agentic.yml` is used as a fallback if no `~/.agentic/repos/*.yml`
matches the repo's path.

## Storage layout

```
~/.agentic/
├── config.yml                # global defaults
├── repos/<name>.yml          # one per repo
└── runs/<project>/<branch>/multiwt/setup-<idx>.log
```

`multiwt rm` leaves `runs/` in place by default. `--purge` deletes it.

## Notes

- Branch names with spaces, `#`, `?`, `~`, `^`, `*`, `\` are rejected.
- tmux session names can't contain `:` or `.` — those are normalized to `_`.
- Bare repos are not supported.
- `multiwt up` from any worktree of a project resolves to the same config
  (uses `git rev-parse --git-common-dir`).
- If `tmux` isn't running, `up` still creates the worktree and warns.

## Env vars

- `MULTIWT_AGENTIC_ROOT` — override `~/.agentic` (default).
- `MULTIWT_VERBOSE=1` (or `--verbose`) — extra logging.
- `EDITOR` — used by `multiwt register` to open the new yaml.
