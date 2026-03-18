# atuin-session-logger

Discrete, named shell history sessions — powered by [Atuin](https://atuin.sh) — with one-command Jira ticket creation via Claude.

You're already capturing everything with Atuin. This adds lightweight bookmarks around chunks of work so you can ask "what did I actually do for this ticket?" and get a structured answer pushed directly to your board.

---

## How it works

`startlog` and `stoplog` record timestamps — nothing more. When you call `dumplog`, `jira-summary`, or `jira-push`, the script queries Atuin's history with `--after` / `--before` to reconstruct exactly what ran in that window. No traps, no hooks, no duplicate capture. Session state is written to disk so it survives closing the terminal.

```
startlog fix-auth-bug
  │
  describe              # write intent, goals, context
  │
  │  your normal work, captured by Atuin as always
  │
stoplog
  │
  ├── dumplog           # inspect description + raw commands
  ├── jira-summary      # Claude drafts the ticket
  └── jira-push         # POST to Jira → PROJ-n created, opens in browser
```

---

## Requirements

- [Atuin](https://atuin.sh) — installed and shell hook active
- `curl`
- `python3`
- An [Anthropic API key](https://console.anthropic.com/) — for `jira-summary` and `jira-update`
- An [Atlassian API token](https://id.atlassian.com/manage-profile/security/api-tokens) — for `jira-push`

---

## Installation

```bash
curl -o ~/.atuin_session_logger.sh \
  https://raw.githubusercontent.com/your-username/atuin-session-logger/main/atuin_session_logger.sh

# Add to your shell config
echo 'source ~/.atuin_session_logger.sh' >> ~/.zshrc   # or ~/.bashrc
source ~/.atuin_session_logger.sh
```

### Secrets file

Create a secrets file and source it from your shell config. Never commit this file.

```bash
mkdir -p ~/.config/atuin-session-logger
cat > ~/.config/atuin-session-logger/env << 'EOF'
export ANTHROPIC_API_KEY="sk-ant-..."

export JIRA_BASE_URL="https://yourworkspace.atlassian.net"
export JIRA_EMAIL="you@yourcompany.com"
export JIRA_API_TOKEN="your-atlassian-token"
export JIRA_PROJECT_KEY="PROJ"
export JIRA_ACCOUNT_ID="your-atlassian-account-id"   # from your board URL
EOF

chmod 600 ~/.config/atuin-session-logger/env
echo 'source ~/.config/atuin-session-logger/env' >> ~/.zshrc
```

Your `JIRA_ACCOUNT_ID` is visible in your board URL — it's the value after `assignee=` (e.g. `712020:338e28c2-...`). Setting it auto-assigns every created ticket to you.

---

## Usage

### Full workflow

```bash
startlog fix-auth-bug
describe
# OAuth token refresh hits a race condition under concurrent requests.
# Goal: add a mutex around the refresh call and test it.
# <Ctrl-D>

# ... do your work ...

stoplog
jira-summary                        # Claude generates a structured draft
jira-push                           # creates PROJ-n, assigned to you, opens in browser
```

### Writing a description

`describe` opens an inline prompt — no editor required. Type freely, hit `Ctrl-D` to save, `Ctrl-C` to cancel. Call it any time to update:

```bash
describe                  # write or update description for current session
describe fix-auth-bug     # update a named session retroactively
```

The description is passed to Claude as context when generating tickets and update comments, so the more specific it is, the better the output.

### Generating a progress update

For work-in-progress tickets, `jira-update` generates a comment draft rather than a new ticket:

```bash
jira-update PROJ-42
jira-update fix-auth-bug PROJ-42 "focused on the token refresh path today"
```

### Working with past sessions

Session state persists across terminals automatically — the last session is always restored when you open a new shell. For older sessions:

```bash
lslogs                              # list all saved sessions
dumplog fix-auth-bug                # inspect any past session by name
jira-summary fix-auth-bug           # generate a draft for a past session
jira-push fix-auth-bug --type Story # push with a different issue type
loadlog fix-auth-bug                # restore a session as the current one
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
| `describe [name]` | Write or update the session description inline. Ctrl-D to save. |
| `stoplog` | End the current session. |
| `dumplog [name]` | Print description + commands. Accepts a session name for any past session. |
| `lslogs` | List all saved sessions with their time windows. |
| `loadlog <n>` | Restore a past session as the current one. |
| `jira-summary [name] [context]` | Generate a Jira ticket draft via Claude. |
| `jira-push [name] [--type T]` | Push the most recent draft to Jira. Creates the ticket, saves the key, opens the browser. Issue type defaults to `Task`. |
| `jira-update [name] <KEY> [context]` | Generate a progress update comment for an existing ticket via Claude. |
| `sessionhelp` | Print command reference in the terminal. |

---

## Configuration

Set these in `~/.config/atuin-session-logger/env` and source it from your shell config.

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | For `jira-summary`, `jira-update` | Anthropic API key |
| `JIRA_BASE_URL` | For `jira-push` | e.g. `https://yourworkspace.atlassian.net` |
| `JIRA_EMAIL` | For `jira-push` | Your Atlassian account email |
| `JIRA_API_TOKEN` | For `jira-push` | Atlassian API token — must be a single unbroken string |
| `JIRA_PROJECT_KEY` | For `jira-push` | Default project key, e.g. `PROJ` |
| `JIRA_ACCOUNT_ID` | Optional | Atlassian account ID — auto-assigns tickets to you |
| `ATUIN_SESSION_LOG_DIR` | Optional | Where files are saved. Default: `~/.session_logs` |

---

## Jira ticket output

`jira-summary` sends the session log and description to Claude and produces a draft with:

- **Summary** — one-line, imperative mood, ≤80 chars
- **Description** — what was done and why
- **Technical Details** — key commands and changes
- **Acceptance Criteria** — inferred from the work
- **Labels** — e.g. `backend`, `infra`, `bugfix`

The draft is saved as a `.md` file alongside the session state. `jira-push` reads the most recent one and converts it to Atlassian Document Format (ADF) before posting — Jira's v3 API requires ADF rather than plain markdown.

---

## Files written per session

```
~/.session_logs/
  .current_session                    # always reflects the last active session
  fix-auth-bug.state                  # timestamps + Jira key, reusable by name
  fix-auth-bug.desc                   # your description
  fix-auth-bug_jira_<timestamp>.md    # generated ticket drafts
  fix-auth-bug_PROJ-n_update_<ts>.md  # generated update comments

~/.config/atuin-session-logger/env   # secrets — never commit this
```

State files are plain `key=value` text — easy to inspect, edit, or script against.

---

## Why Atuin instead of a DEBUG trap?

A trap-based logger misses commands run in subshells, sourced scripts, or terminals that crash. Atuin captures everything at the shell level unconditionally. This script just adds a time-windowed view on top of what Atuin already knows.