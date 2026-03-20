# wj — work journal

A modular, shell-native work journal. Sessions, timestamped notes, shell
history capture, todo tracking, and optional sync to Obsidian and Jira.
No daemon. No database. Plain files.

## Install

```bash
git clone <repo> ~/.wj
echo 'source ~/.wj/wj.sh' >> ~/.zshrc   # or .bashrc
source ~/.wj/wj.sh
```

## Quick start

```bash
# Create a todo item
wj todo add "fix token refresh race condition" --tag auth
# → todo-a3f2

# Start a session linked to that todo
wj start todo-a3f2

# Add notes as you work
wj note "root cause: mutex not held across async boundary"
wj note "fix: wrap refresh call in lock, add test for concurrent requests"

# End the session — todo is marked done, time recorded
wj stop

# Review what happened
wj dump

# Generate a summary and push to Jira
wj summarise && wj push
```

## Commands

| Command | Description |
|---|---|
| `wj start [todo-id \| name]` | Begin a session |
| `wj stop [--pause]` | End or pause the current session |
| `wj load <name>` | Restore a past session |
| `wj ls` | List all saved sessions |
| `wj note ["text"]` | Add a timestamped note |
| `wj dump [name]` | Print notes + command history |
| `wj todo add "desc" [--tag t]` | Create a todo item |
| `wj todo ls [--pending\|--done\|…]` | List today's todos |
| `wj todo done <id>` | Mark done without a session |
| `wj todo rollover` | Copy unfinished items from yesterday |
| `wj summarise [name]` | AI summary via Claude |
| `wj push [name] [--type T]` | Create Jira ticket from summary |
| `wj obs status` | Check Obsidian API connection |
| `wj export [name] [--format md\|json]` | Export session |

## File layout

```
~/.wj/
  wj.sh                     # entry point — source this
  lib/
    todo.sh                 # todo lifecycle
    session.sh              # session lifecycle
    notes.sh                # wj note / wj dump
    history.sh              # shell history backend adapter
  integrations/
    obsidian.sh             # Obsidian Local REST API (optional)
    ai.sh                   # Claude API — wj summarise (optional)
    jira.sh                 # Jira API — wj push (optional)
    export.sh               # markdown/JSON export (optional)
  plugins/                  # drop your own .sh files here
  sessions/                 # .state, .desc, _summary_*.md per session
  todos/                    # YYYY-MM-DD.todo files
```

## Environment variables

```bash
# Core
export WJ_DIR=~/.wj                     # storage root (default)
export WJ_HISTORY_BACKEND=atuin         # atuin | zsh | bash | plain

# Obsidian (enables obsidian.sh)
export OBSIDIAN_API_KEY=your-key
export OBSIDIAN_VAULT_URL=https://127.0.0.1:27124
export OBSIDIAN_DAILY_DIR=Daily

# Claude (enables ai.sh / wj summarise)
export ANTHROPIC_API_KEY=sk-ant-...
export WJ_AI_MODEL=claude-sonnet-4-6    # optional override

# Jira (enables jira.sh / wj push)
export JIRA_BASE_URL=https://yourworkspace.atlassian.net
export JIRA_EMAIL=you@example.com
export JIRA_API_TOKEN=your-token
export JIRA_PROJECT_KEY=AUTH
export JIRA_ACCOUNT_ID=your-account-id  # optional, for auto-assign
```

## Todo → session flow

Todo items are the primary way to track work. Each todo gets a short block ID
(`todo-a3f2`). When you `wj start todo-a3f2`, the todo description becomes the
session name and the item is marked in-progress. On `wj stop`, elapsed time is
accumulated on the todo and its state is updated.

Multi-session work is supported: `wj stop --pause` marks the todo `[-]` and
preserves accumulated time. The next `wj start todo-a3f2` picks up where you
left off. Total time across all sessions is recorded.

## Obsidian integration

When `OBSIDIAN_API_KEY` is set and Obsidian is running with the
[Local REST API plugin](https://github.com/coddingtonbear/obsidian-local-rest-api):

- `wj todo add` appends to today's daily note under `## Todo`
- `wj start` / `wj stop` update the checkbox state and write the session block
- `wj todo rollover` mirrors unfinished items to the next day's note
- Obsidian is a **view layer only** — local files are always the source of truth

Check the connection: `wj obs status`

## Plugins

Drop any `.sh` file into `~/.wj/plugins/` and it will be sourced automatically
on shell start. Register hooks by defining functions named:

```bash
_wj_hook_<plugin>_session_start()  { ... }
_wj_hook_<plugin>_session_stop()   { ... }
```

These are called by `session.sh` via `_wj_hook_fire` without any knowledge of
your plugin's existence.

## History backends

| Backend | Timestamps | Requirements |
|---|---|---|
| `atuin` | Yes — per-command | `atuin` on PATH (autodetected) |
| `zsh` | Yes — if `setopt EXTENDED_HISTORY` | ZSH |
| `bash` | No — last 50 commands | Bash |
| `plain` | No | Set `WJ_HISTORY_FILE` |

## Relationship to atuin-session-logger.sh

`wj` is a ground-up rewrite of `atuin_session_logger.sh` as a modular system.
The core concepts (`startlog`/`stoplog`/`describe`/`dumplog`) are preserved and
extended. Jira functions are ported directly. The main additions are the todo
module, Obsidian integration, and the hook system that keeps integrations
decoupled from core logic.
