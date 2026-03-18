#!/usr/bin/env bash
# =============================================================================
# atuin_session_logger.sh — Session logging using Atuin as the history backend
#
# USAGE:
#   source ~/.atuin_session_logger.sh    # add to your .bashrc / .zshrc
#
# COMMANDS:
#   startlog [session-name]   Snapshot current Atuin session ID + timestamp
#   stoplog                   Mark the session end time
#   dumplog                   Print commands captured between start/stop
#   jira-summary [context]    Send log to Claude → Jira ticket draft
#   sessionhelp               Show this help
#
# REQUIREMENTS:
#   atuin      https://atuin.sh  (already installed & shell hook active)
#   curl       for Claude API calls
#   python3    for JSON parsing
# =============================================================================

_ATUIN_SESSION_NAME=""
_ATUIN_SESSION_START=""
_ATUIN_SESSION_END=""

_SESSION_LOG_DIR="${ATUIN_SESSION_LOG_DIR:-$HOME/.session_logs}"
_SESSION_STATE_FILE="$_SESSION_LOG_DIR/.current_session"

# ---------------------------------------------------------------------------
# _session_save_state / _session_load_state — persist across terminal sessions
# ---------------------------------------------------------------------------
_session_save_state() {
    mkdir -p "$_SESSION_LOG_DIR"
    printf 'name=%s\nstart=%s\nend=%s\n' \
        "$_ATUIN_SESSION_NAME" \
        "$_ATUIN_SESSION_START" \
        "$_ATUIN_SESSION_END" \
        > "$_SESSION_STATE_FILE"
    # Also save a named copy so loadlog can find it later
    cp "$_SESSION_STATE_FILE" "$_SESSION_LOG_DIR/${_ATUIN_SESSION_NAME}.state"
}

_session_load_state() {
    [[ -f "$_SESSION_STATE_FILE" ]] || return
    while IFS='=' read -r key val; do
        case "$key" in
            name)  _ATUIN_SESSION_NAME="$val" ;;
            start) _ATUIN_SESSION_START="$val" ;;
            end)   _ATUIN_SESSION_END="$val" ;;
        esac
    done < "$_SESSION_STATE_FILE"
}

# Auto-restore last session state on shell start
_session_load_state

# ---------------------------------------------------------------------------
# startlog — record the current moment as the session start
# ---------------------------------------------------------------------------
startlog() {
    local name="${1:-session_$(date '+%Y%m%d_%H%M%S')}"
    _ATUIN_SESSION_NAME="$name"
    _ATUIN_SESSION_START=$(date '+%Y-%m-%dT%H:%M:%S')
    _ATUIN_SESSION_END=""
    _session_save_state

    echo "▶  Session '$name' started at $_ATUIN_SESSION_START"
    echo "   Run your commands, then call 'stoplog' when done."
}

# ---------------------------------------------------------------------------
# stoplog — record the end timestamp
# ---------------------------------------------------------------------------
stoplog() {
    if [[ -z "$_ATUIN_SESSION_START" ]]; then
        echo "No active session. Run 'startlog' first." >&2
        return 1
    fi
    _ATUIN_SESSION_END=$(date '+%Y-%m-%dT%H:%M:%S')
    _session_save_state
    echo "■  Session '$_ATUIN_SESSION_NAME' stopped at $_ATUIN_SESSION_END"
    echo "   $(dumplog | grep -cv '^#' 2>/dev/null || echo '?') commands captured. Run 'dumplog' or 'jira-summary'."
}


# ---------------------------------------------------------------------------
# describe [session-name] — write/update a description for a session
# Inline heredoc prompt — Ctrl-D to save, Ctrl-C to cancel.
# Stored at ~/.session_logs/<name>.desc alongside the .state file.
# ---------------------------------------------------------------------------
describe() {
    local name="${1:-$_ATUIN_SESSION_NAME}"
    if [[ -z "$name" ]]; then
        echo "No active session and no name given. Run 'startlog' first or pass a session name." >&2
        return 1
    fi

    local descfile="$_SESSION_LOG_DIR/${name}.desc"
    mkdir -p "$_SESSION_LOG_DIR"

    # Show existing content if any
    if [[ -f "$descfile" && -s "$descfile" ]]; then
        echo "Current description for '$name':"
        echo "────────────────────────────────"
        cat "$descfile"
        echo "────────────────────────────────"
        echo "Enter new description below (replaces above). Ctrl-D to save, Ctrl-C to cancel."
    else
        echo "Description for '$name' — Ctrl-D when done, Ctrl-C to cancel:"
    fi

    local content
    if ! content=$(cat); then
        echo "Cancelled." >&2
        return 1
    fi

    if [[ -z "$content" ]]; then
        echo "Empty input — description unchanged." >&2
        return 1
    fi

    printf '%s
' "$content" > "$descfile"
    echo "✓  Description saved to $descfile"
}

# ---------------------------------------------------------------------------
# loadlog — restore a named session by name
# ---------------------------------------------------------------------------
loadlog() {
    if [[ -z "$1" ]]; then
        echo "Usage: loadlog <session-name>" >&2
        lslogs
        return 1
    fi
    local statefile="$_SESSION_LOG_DIR/$1.state"
    if [[ ! -f "$statefile" ]]; then
        echo "No saved session '$1' found in $_SESSION_LOG_DIR" >&2
        return 1
    fi
    while IFS='=' read -r key val; do
        case "$key" in
            name)  _ATUIN_SESSION_NAME="$val" ;;
            start) _ATUIN_SESSION_START="$val" ;;
            end)   _ATUIN_SESSION_END="$val" ;;
        esac
    done < "$statefile"
    cp "$statefile" "$_SESSION_STATE_FILE"
    echo "↩  Loaded session '$_ATUIN_SESSION_NAME' (${_ATUIN_SESSION_START} → ${_ATUIN_SESSION_END:-ongoing})"
}

# ---------------------------------------------------------------------------
# lslogs — list all saved sessions
# ---------------------------------------------------------------------------
lslogs() {
    if [[ ! -d "$_SESSION_LOG_DIR" ]] || ! ls "$_SESSION_LOG_DIR"/*.state &>/dev/null; then
        echo "No saved sessions in $_SESSION_LOG_DIR"
        return
    fi
    echo "Saved sessions:"
    for f in "$_SESSION_LOG_DIR"/*.state; do
        local name="" start="" end=""
        while IFS='=' read -r key val; do
            case "$key" in
                name)  name="$val" ;;
                start) start="$val" ;;
                end)   end="$val" ;;
            esac
        done < "$f"
        printf '  %-30s  %s → %s\n' "$name" "$start" "${end:-ongoing}"
    done
}

# ---------------------------------------------------------------------------
# _session_resolve [name] — echo "name start end" for a session
# If name given, reads from its .state file; otherwise uses current state vars.
# ---------------------------------------------------------------------------
_session_resolve() {
    local name="$1"
    if [[ -n "$name" ]]; then
        local statefile="$_SESSION_LOG_DIR/${name}.state"
        if [[ ! -f "$statefile" ]]; then
            echo "No saved session '$name' in $_SESSION_LOG_DIR" >&2
            return 1
        fi
        local r_name="" r_start="" r_end=""
        while IFS='=' read -r key val; do
            case "$key" in
                name)  r_name="$val" ;;
                start) r_start="$val" ;;
                end)   r_end="$val" ;;
            esac
        done < "$statefile"
        echo "$r_name" "$r_start" "$r_end"
    else
        if [[ -z "$_ATUIN_SESSION_START" ]]; then
            echo "No active session. Run 'startlog' first, or pass a session name." >&2
            return 1
        fi
        echo "$_ATUIN_SESSION_NAME" "$_ATUIN_SESSION_START" "${_ATUIN_SESSION_END:-}"
    fi
}

# ---------------------------------------------------------------------------
# _atuin_search <start> <end> — query Atuin between two timestamps
# ---------------------------------------------------------------------------
_atuin_search() {
    local after="$1"
    local before="${2:-$(date '+%Y-%m-%dT%H:%M:%S')}"

    atuin search \
        --after  "$after" \
        --before "$before" \
        --format "{time}\t{command}" \
        2>/dev/null
}

# ---------------------------------------------------------------------------
# dumplog [session-name] — print commands for current or named session
# ---------------------------------------------------------------------------
dumplog() {
    local resolved
    resolved=$(_session_resolve "$1") || return 1
    read -r s_name s_start s_end <<< "$resolved"

    echo "# Session:  $s_name"
    echo "# From:     $s_start"
    echo "# To:       ${s_end:-ongoing}"

    local descfile="$_SESSION_LOG_DIR/${s_name}.desc"
    if [[ -f "$descfile" && -s "$descfile" ]]; then
        echo "# Description:"
        while IFS= read -r line; do
            echo "#   $line"
        done < "$descfile"
    fi

    echo "#"
    _atuin_search "$s_start" "$s_end"
}

# ---------------------------------------------------------------------------
# jira-summary [session-name] [extra context...] — generate Jira ticket draft
# If session-name matches a saved .state file, uses that session.
# Otherwise treats all args as extra context for the current session.
# ---------------------------------------------------------------------------
jira-summary() {
    # If first arg matches a saved session, use it; otherwise use current
    local session_arg=""
    if [[ -n "$1" && -f "$_SESSION_LOG_DIR/$1.state" ]]; then
        session_arg="$1"
        shift
    fi

    local resolved
    resolved=$(_session_resolve "$session_arg") || return 1
    read -r s_name s_start s_end <<< "$resolved"

    if [[ -z "$ANTHROPIC_API_KEY" ]]; then
        echo "⚠  ANTHROPIC_API_KEY is not set." >&2
        echo "   Export it: export ANTHROPIC_API_KEY='sk-ant-...'" >&2
        return 1
    fi

    local extra_context="${*}"
    local log_content
    log_content=$(dumplog "$session_arg")

    if [[ -z "$log_content" ]]; then
        echo "No commands found in this session window." >&2
        return 1
    fi

    # Load description file if present
    local description=""
    local descfile="$_SESSION_LOG_DIR/${s_name}.desc"
    [[ -f "$descfile" && -s "$descfile" ]] && description=$(cat "$descfile")

    echo "⏳ Generating Jira summary via Claude..."

    local prompt="You are a senior software engineer writing a Jira ticket based on a shell session log.

The log format is:  YYYY-MM-DD HH:MM:SS<TAB>command
${description:+
The engineer provided this description of the work:
---
$description
---
}
${extra_context:+
Additional context from the engineer:
$extra_context
}
Shell session log:
\`\`\`
${log_content}
\`\`\`

Produce a professional Jira ticket with these exact sections:

**Summary** (one line, imperative mood, ≤80 chars)
**Description** (2–4 sentences: what was done and why)
**Technical Details** (bullet list of key commands/changes)
**Acceptance Criteria** (bullet list, inferred from the work)
**Labels** (comma-separated, e.g. backend, infra, bugfix, feature)

Be specific. Infer intent from the commands and description. Avoid vague language."

    local payload
    payload=$(python3 -c "
import json, sys
prompt = sys.stdin.read()
print(json.dumps({
    'model': 'claude-sonnet-4-20250514',
    'max_tokens': 1024,
    'messages': [{'role': 'user', 'content': prompt}]
}))
" <<< "$prompt")

    local response
    response=$(curl -sf https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$payload")

    if [[ $? -ne 0 || -z "$response" ]]; then
        echo "❌ API call failed. Check ANTHROPIC_API_KEY and network." >&2
        return 1
    fi

    local summary
    summary=$(python3 -c "
import json, sys
data = json.load(sys.stdin)
for block in data.get('content', []):
    if block.get('type') == 'text':
        print(block['text'])
" <<< "$response")

    echo "$summary"

    local outfile="$_SESSION_LOG_DIR/${s_name}_jira_$(date '+%Y%m%d_%H%M%S').md"
    {
        echo "# Jira Summary — $_ATUIN_SESSION_NAME"
        echo "# Generated: $(date)"
        echo ""
        echo "$summary"
        echo ""
        echo "---"
        echo "## Raw Session Log"
        echo ""
        echo "$log_content"
    } > "$outfile"

    echo ""
    echo "💾 Saved to: $outfile"
}

# ---------------------------------------------------------------------------
# jira-update [session-name] <jira-key> [extra context...] — update a Jira ticket
# If session-name matches a saved .state file, uses that session for the log.
# Requires a <jira-key> to identify the ticket being updated.
# Generates a progress update/comment draft via Claude API.
# ---------------------------------------------------------------------------

jira-update() {
    local jira_key="$1"
    shift
    local session_arg=""
    
    # Check if the first arg was actually a session name
    if [[ -f "$_SESSION_LOG_DIR/$jira_key.state" ]]; then
        session_arg="$jira_key"
        jira_key="$1"
        shift
    fi

    if [[ -z "$jira_key" ]]; then
        echo "Usage: jira-update [session-name] <JIRA-KEY> [extra context]" >&2
        return 1
    fi

    local log_content
    log_content=$(dumplog "$session_arg")
    local extra_context="${*}"

    local prompt="You are a senior engineer providing a progress update for Jira ticket $jira_key.
    
Log:
\`\`\`
$log_content
\`\`\`
Context: $extra_context

Produce a professional progress update/comment with these sections:
**Progress Update**: (What specifically was achieved in this session)
**Technical Changes**: (Key files touched or commands run)
**Next Steps**: (What remains to be done for $jira_key)
"

    echo "⏳ Generating update for $jira_key via Claude..."
    _call_claude "$prompt"
}


# ---------------------------------------------------------------------------
# sessionhelp
# ---------------------------------------------------------------------------
sessionhelp() {
    cat <<'EOF'
Atuin Session Logger
────────────────────
  startlog [name]                  Mark session start
  describe [name]                  Write/update session description (Ctrl-D to save)
  stoplog                          Mark session end
  dumplog [name]                   Print description + commands for current or named session
  lslogs                           List all saved sessions
  loadlog <name>                   Restore a previous session
  jira-summary [name] [context]    Generate Jira ticket via Claude API
  jira-update  [name] [context]    Create a progress update for an existing ticket

Environment Variables
─────────────────────
  ANTHROPIC_API_KEY        Required for jira-summary
  ATUIN_SESSION_LOG_DIR    Where state + summaries are saved (default: ~/.session_logs)

Typical workflow
────────────────
  startlog fix-auth-bug
  describe                          # write intent/context before you start
  # ... do your work ...
  describe                          # optionally update mid-session
  stoplog
  jira-summary

  # Named session from any terminal:
  dumplog fix-auth-bug
  jira-summary fix-auth-bug "extra context"

Files written per session
─────────────────────────
  ~/.session_logs/<name>.state      timestamps (auto-restored on new shell)
  ~/.session_logs/<name>.desc       your description
  ~/.session_logs/<name>_jira_*.md  generated ticket drafts
EOF
}