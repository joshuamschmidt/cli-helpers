# atuin-session-logger

Discrete, named shell history sessions — powered by [Atuin](https://atuin.sh) — with one-command Jira ticket generation via Claude.

You're already capturing everything with Atuin. This adds lightweight bookmarks around chunks of work so you can ask "what did I actually do for this ticket?" and get a structured answer.

---

## How it works

`startlog` and `stoplog` record timestamps — nothing more. When you call `dumplog` or `jira-summary`, the script queries Atuin's history with `--after` / `--before` to reconstruct exactly what ran in that window. No traps, no hooks, no duplicate capture. Session state is written to disk so it survives closing the terminal.

```
startlog fix-auth-bug
  │
  │  your normal work, captured by Atuin as always
  │
stoplog
  │
  ├── dumplog              # inspect the raw commands
  └── jira-summary         # send to Claude → structured Jira ticket
```

---

## Requirements

- [Atuin](https://atuin.sh) — installed and shell hook active
- `curl`
- `python3`
- `ANTHROPIC_API_KEY` — only required for `jira-summary`

---

## Installation

```bash
curl -o ~/.atuin_session_logger.sh \
  https://raw.githubusercontent.com/your-username/atuin-session-logger/main/atuin_session_logger.sh

# Add to your shell config
echo 'source ~/.atuin_session_logger.sh' >> ~/.zshrc   # or ~/.bashrc
source ~/.atuin_session_logger.sh
```

---

## Usage

### Basic workflow

```bash
startlog fix-auth-bug
# ... do your work ...
stoplog

# Preview what was captured
dumplog

# Generate a Jira ticket
export ANTHROPIC_API_KEY="sk-ant-..."
jira-summary "Race condition in the OAuth token refresh path"
```

### Working with past sessions

Session state persists across terminals automatically. The last session is always restored when you open a new shell. For older sessions:

```bash
# List all saved sessions
lslogs

# Dump or summarise any past session by name — no loadlog needed
dumplog fix-auth-bug
jira-summary fix-auth-bug "some extra context"

# Or explicitly load a session as the current one
loadlog fix-auth-bug
dumplog
jira-summary
```

### Composable output

`dumplog` writes to stdout, so it pipes anywhere:

```bash
dumplog fix-auth-bug | grep docker
dumplog fix-auth-bug | pbcopy
dumplog fix-auth-bug | llm "what did I break"
```

---

## Commands

| Command | Description |
|---|---|
| `startlog [name]` | Begin a session. Defaults to a timestamp name if omitted. |
| `stoplog` | End the current session. |
| `dumplog [name]` | Print captured commands. Accepts a session name to dump any past session. |
| `lslogs` | List all saved sessions with their time windows. |
| `loadlog <name>` | Restore a past session as the current one. |
| `jira-summary [name] [context]` | Generate a Jira ticket via Claude. Session name optional — if omitted, uses the current session. Extra context is passed to the model. |
| `sessionhelp` | Print command reference. |

---

## Configuration

| Variable | Default | Description |
|---|---|---|
| `ATUIN_SESSION_LOG_DIR` | `~/.session_logs` | Where `.state` files and Jira summaries are saved. |
| `ANTHROPIC_API_KEY` | — | Required for `jira-summary`. |

---

## Jira ticket output

`jira-summary` sends the session log to `claude-sonnet-4` and prints a ticket draft with:

- **Summary** — one-line, imperative mood
- **Description** — what was done and why
- **Technical Details** — key commands and changes
- **Acceptance Criteria** — inferred from the work
- **Labels** — e.g. `backend`, `infra`, `bugfix`

The summary is also saved as a `.md` file in `ATUIN_SESSION_LOG_DIR` alongside the `.state` file, named `<session>_jira_<timestamp>.md`.

---

## State files

Each session writes two files to `~/.session_logs/`:

```
~/.session_logs/
  .current_session          # always reflects the last active session
  fix-auth-bug.state        # named session, reusable via loadlog / dumplog
  fix-auth-bug_jira_*.md    # generated ticket drafts
```

State files are plain `key=value` text — easy to inspect, edit, or script against.

---

## Why Atuin instead of a DEBUG trap?

A trap-based logger misses commands run in subshells, sourced scripts, or terminals that crash. Atuin captures everything at the shell level unconditionally. This script just adds a time-windowed view on top of what Atuin already knows.
