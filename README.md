# multiwt

One command to spin up (or tear down) a git worktree + tmux session, with env
files copied and setup hooks run.

## Prereqs

- `git` ≥ 2.20
- `tmux`
- `yq` (mikefarah, Go version) — `brew install yq`
- `bash` ≥ 4
- `fzf` — `brew install fzf` (only for `multiwt switch`)

## Install

Clone the repo anywhere, then run the installer:

```bash
git clone <repo-url> multiwt
cd multiwt
./install.sh
```

This symlinks `multiwt` into a directory on your `$PATH` (prefers
`~/.local/bin`, then `~/bin`, then `/usr/local/bin`) and points it back at this
checkout — so `git pull` here keeps your installed version current. If the
chosen directory isn't already on `$PATH`, the installer prints the `export`
line to add to your shell profile.

Options:

```bash
./install.sh --dir ~/bin    # install into a specific directory
./install.sh --uninstall    # remove the symlink
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
| `multiwt switch [--all]`                 | fzf switcher across registered projects/worktrees with Claude status. Opens on active worktrees; `--all` starts unfiltered |
| `multiwt next [--print]`                 | Jump to the next Claude session needing attention (`--print`: just print its pane id) |
| `multiwt register [--name <slug>]`       | Initialize this repo's config                                        |
| `multiwt register --refresh`             | Walk `~/.agentic/repos/`, rewrite stale `path:` entries              |
| `multiwt claude-hook`                    | Internal: endpoint for Claude Code hooks (see below)                 |

`multiwt up` is idempotent: re-running on an existing worktree just re-attaches.
To rebuild, `multiwt rm` then `multiwt up`.

## Switcher

`multiwt switch` is a global, cwd-independent picker: it lists every worktree
of every repo registered under `~/.agentic/repos/`, one row per worktree, with
an aggregate of the Claude Code sessions running inside it:

```
agentic      ▸ feat/switcher   ⚠1 ●1
agentic      ▸ main            ◐1
backend      ▸ fix/auth-race   ○  (no tmux)
```

- `⚠ N` — sessions blocked on you (permission prompt) · `◐ N` — finished,
  waiting for your next prompt · `● N` — running · `○` — no Claude session.
- The preview panel shows per-worktree detail: dirty/ahead/behind, last
  commit, and each Claude session with its pane and age.
- By default the switcher opens filtered to active worktrees — those with a
  live tmux session (or a Claude session running outside tmux); `ctrl-w`
  toggles between that and all worktrees (the header row shows which view
  you're in), `ctrl-s` shows one row per Claude session. `multiwt switch
  --all` opens unfiltered.
- `ctrl-x` removes the highlighted worktree and kills its tmux session —
  but only when safe: never the main worktree, never a dirty tree (there is
  deliberately no `--force` here; use `multiwt rm --force`), and never while
  a Claude session is still running inside it. The outcome appears in the
  header row. The branch itself is kept, so a removed worktree can be
  recreated with `multiwt up`.

Enter switches to the worktree's tmux session, creating it first if needed.
If the most urgent Claude session is blocked (`⚠`) or waiting (`◐`), enter
additionally focuses its exact window/pane — via `select-window`/`select-pane`
only, so the session's layout is never modified. In the `ctrl-s` view, enter
always jumps to that specific session's pane. Plain `● running` worktrees get
a plain switch, landing wherever you last were.

Bind it as a tmux popup (e.g. replacing your session switcher):

```tmux
# ~/.tmux.conf
bind-key i display-popup -E -w 90% -h 70% "multiwt switch"
```

If your tmux launches commands with a non-login shell that lacks your `$PATH`,
use the absolute path to the `multiwt` symlink (e.g.
`~/.local/bin/multiwt switch`).

### Dashboard

`multiwt dash` is a full-screen, always-on TUI meant for a spare monitor:
every registered project, its active worktrees, and the Claude sessions
inside them, fully re-scanned every tick — nothing is cached, nothing needs
a manual refresh.

```
multiwt · 18:48:49 · q quit

agentic
  ▸ main                          * ●1
      ● running     %11     3s
ai-scraper3
  ▸ main                            ⚠1 ◐1
      ⚠ needs input %10     2m  Claude needs your permission to use Bash
      ◐ waiting     %13    10m  Claude is waiting for your input
```

- Only active worktrees are shown: a live tmux session, or a Claude session
  running outside tmux. Everything else is hidden (use the switcher's
  `ctrl-w` view to see all worktrees).
- Sessions needing input are painted red — visible from across the room.
- Refresh cadence is `--interval` seconds (default 2); `q` quits.
- Frames redraw in place (no clear-screen), so there's no flicker.
- `multiwt dash --once` prints a single frame and exits — usable in scripts
  or `watch`-style setups.

Run it in a plain terminal on the second monitor, or give it a dedicated
tmux session: `tmux new-session -s dash 'multiwt dash'`.

### Attention jump

`multiwt next` teleports you to the Claude session that needs you most —
permission prompts (`⚠`) first, then finished turns waiting for input (`◐`),
longest-neglected first. Focus changes use `select-window`/`select-pane`
only; layouts are never modified. Bind it:

```tmux
bind g run-shell "multiwt next"
```

Sessions you've already looked at are skipped: every pane visit marks its
Claude session as *seen*, and only sessions with activity newer than their
seen-stamp are jump targets. So repeated presses walk through every needy
session exactly once (across all projects and tmux sessions), then report
"nothing new" without moving — no ping-ponging, no jumping to things you've
already read. A session re-enters the rotation as soon as it produces a new
event (finishes another turn, raises a permission prompt).

Seen-marking has two layers:

- A tmux `pane-focus-in` hook stamps a session seen whenever its pane gains
  focus — however you navigated there (switcher, `choose-session`, manual
  pane switching). Add to `~/.tmux.conf`:

  ```tmux
  set -g focus-events on
  set-hook -g pane-focus-in "run-shell -b 'multiwt seen #{hook_pane}'"
  ```

- As a fallback (e.g. without the hook), `multiwt next` itself stamps every
  pane currently visible in an attached client at press time.

Seen-ness only affects `next`; the switcher always shows the true `⚠/◐/●`
state.

## Claude session status (hooks)

The switcher's `⚠/◐/●` column is fed by Claude Code hooks. This is a manual,
one-time setup: add the hooks to `~/.claude/settings.json` (create the file if
it doesn't exist; if you already have a `hooks` block, merge these entries into
it):

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "multiwt claude-hook" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "multiwt claude-hook" }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "multiwt claude-hook" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "multiwt claude-hook" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "multiwt claude-hook" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "multiwt claude-hook" }] }]
  }
}
```

If `multiwt` isn't on the `$PATH` Claude Code runs hooks with, use the
absolute path to the symlink instead.

How each event maps to a state:

| Event              | State                                                        |
| ------------------ | ------------------------------------------------------------ |
| `UserPromptSubmit` | `●` running                                                   |
| `PostToolUse`      | `●` running — also clears a `⚠` after you approve a permission |
| `Stop`             | `◐` waiting (Claude finished its turn)                        |
| `SessionStart`     | `◐` waiting                                                   |
| `Notification`     | `⚠` needs input (permission prompt); the "waiting for your input" idle nudge maps to `◐` |
| `SessionEnd`       | state file deleted                                            |

`PostToolUse` fires on every tool call, so it's the chattiest hook. It's what
flips `⚠ → ●` when you approve a permission without typing anything; omit it
if you don't mind a stale `⚠` until the next `Stop`.

Mechanics and caveats:

- Each Claude session writes one file to `~/.agentic/state/claude/<session_id>`
  containing its state, cwd, tmux pane (`$TMUX_PANE`), timestamp, and last
  notification message. Multiple sessions in one worktree therefore never
  clobber each other; the switcher aggregates them at render time.
- Sessions are matched to worktrees by cwd prefix, so a Claude session started
  in a subdirectory of a worktree still counts toward it.
- Crash cleanup is automatic: at render time, a state file whose recorded pane
  no longer exists — or exists without a `claude` process under it — is
  deleted. Files older than 7 days are dropped unconditionally (covers
  sessions started outside tmux, which have no pane to verify).
- `multiwt rm` deletes the state files of the removed worktree.
- The hook fires for every Claude session on the machine, including repos not
  registered with multiwt; those state files are simply never displayed and
  get garbage-collected like the rest.
- The hook is deliberately paranoid: it never writes to stdout (Claude Code
  injects `UserPromptSubmit` hook stdout into the model's context) and always
  exits 0, so a broken install can't block or slow a Claude session.

## Config

Per-repo config lives at `~/.agentic/repos/<name>.yml`; global defaults at
`~/.agentic/config.yml` deep-merge underneath.

```yaml
path: /Users/me/code/myproj       # required, canonical lookup key
name: myproj                      # required, used for tmux prefix and runs/

worktree:
  parent_dir: ../worktrees        # default
  base_ref: origin/main           # default
  tmux_enabled: true              # default; false = never create/kill/show tmux sessions
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
├── state/claude/<session_id> # Claude Code session state (written by claude-hook)
└── runs/<project>/<branch>/multiwt/setup-<idx>.log
```

`multiwt rm` leaves `runs/` in place by default. `--purge` deletes it.

## Notes

- `multiwt exec` takes the command as a single quoted string:
  `multiwt exec 'npm test --watch'`. Unquoted args are re-joined with spaces.
- `copy_env` is first-write-wins: existing files in the worktree are never
  overwritten (`cp -n`). This also applies to directory entries — pre-existing
  destination files aren't refreshed.
- Branch names with spaces, `#`, `?`, `~`, `^`, `*`, `\` are rejected.
- tmux session names can't contain `:` or `.` — those are normalized to `_`.
- Bare repos are not supported.
- `multiwt up` from any worktree of a project resolves to the same config
  (uses `git rev-parse --git-common-dir`).
- If `tmux` isn't running, `up` still creates the worktree and warns. To turn
  tmux off on purpose (no warning), set `worktree.tmux_enabled: false`.

## Env vars

- `MULTIWT_AGENTIC_ROOT` — override `~/.agentic` (default).
- `MULTIWT_VERBOSE=1` (or `--verbose`) — extra logging.
- `EDITOR` — used by `multiwt register` to open the new yaml.
