#!/usr/bin/env bash
# =============================================================================
# atuin_session_logger.sh — Session logging using Atuin as the history backend
#
# USAGE:
#   source ~/.atuin_session_logger.sh    # add to your .bashrc / .zshrc
#
# COMMANDS:
#   startlog  [name]                 Begin a named session (timestamps via Atuin)
#   describe  [name]                 Write/update session description (Ctrl-D to save)
#   stoplog                          End the current session
#   dumplog   [name]                 Print description + commands for any session
#   lslogs                           List all saved sessions
#   loadlog   <name>                 Restore a past session as current
#   jira-summary [name] [context]    Generate a Jira ticket draft via Claude
#   jira-push    [name] [--type T]   Push draft to Jira; saves key, opens browser
#   jira-update  [name] <KEY> [ctx]  Generate a progress update comment via Claude
#   sessionhelp                      Show this help
#
# REQUIREMENTS:
#   atuin            https://atuin.sh  (installed & shell hook active)
#   curl             for Jira + Claude API calls
#   python3          for JSON handling and ADF conversion
#
# ENVIRONMENT (set in ~/.config/atuin-session-logger/logger-env):
#   ANTHROPIC_API_KEY   required for jira-summary, jira-update
#   JIRA_BASE_URL       e.g. https://yourworkspace.atlassian.net
#   JIRA_EMAIL          your Atlassian account email
#   JIRA_API_TOKEN      your Atlassian API token
#   JIRA_PROJECT_KEY    default project key, e.g. AUTH
#   JIRA_ACCOUNT_ID     your Atlassian account ID (for auto-assign)
# =============================================================================

_ATUIN_SESSION_NAME=""
_ATUIN_SESSION_START=""
_ATUIN_SESSION_END=""
_ATUIN_SESSION_JIRA_KEY=""

_SESSION_LOG_DIR="${ATUIN_SESSION_LOG_DIR:-$HOME/.session_logs}"
_SESSION_STATE_FILE="$_SESSION_LOG_DIR/.current_session"

# ---------------------------------------------------------------------------
# _session_save_state / _session_load_state — persist across terminal sessions
# ---------------------------------------------------------------------------
_session_save_state() {
    mkdir -p "$_SESSION_LOG_DIR"
    printf 'name=%s\nstart=%s\nend=%s\njira_key=%s\n' \
        "$_ATUIN_SESSION_NAME" \
        "$_ATUIN_SESSION_START" \
        "$_ATUIN_SESSION_END" \
        "$_ATUIN_SESSION_JIRA_KEY" \
        > "$_SESSION_STATE_FILE"
    # Also save a named copy so loadlog can find it later
    cp "$_SESSION_STATE_FILE" "$_SESSION_LOG_DIR/${_ATUIN_SESSION_NAME}.state"
}

_session_load_state() {
    [[ -f "$_SESSION_STATE_FILE" ]] || return
    while IFS='=' read -r key val; do
        case "$key" in
            name)     _ATUIN_SESSION_NAME="$val" ;;
            start)    _ATUIN_SESSION_START="$val" ;;
            end)      _ATUIN_SESSION_END="$val" ;;
            jira_key) _ATUIN_SESSION_JIRA_KEY="$val" ;;
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
            name)     _ATUIN_SESSION_NAME="$val" ;;
            start)    _ATUIN_SESSION_START="$val" ;;
            end)      _ATUIN_SESSION_END="$val" ;;
            jira_key) _ATUIN_SESSION_JIRA_KEY="$val" ;;
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
# _call_claude <prompt> — shared helper: send a prompt, return text response
# ---------------------------------------------------------------------------
_call_claude() {
    local prompt="$1"

    if [[ -z "$ANTHROPIC_API_KEY" ]]; then
        echo "⚠  ANTHROPIC_API_KEY is not set." >&2
        echo "   Export it: export ANTHROPIC_API_KEY=\'sk-ant-...\'" >&2
        return 1
    fi

    local payload
    payload=$(python3 -c "
import json, sys
prompt = sys.stdin.read()
print(json.dumps({
    \"model\": \"claude-sonnet-4-20250514\",
    \"max_tokens\": 1024,
    \"messages\": [{\"role\": \"user\", \"content\": prompt}]
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

    python3 -c "
import json, sys
data = json.load(sys.stdin)
for block in data.get(\"content\", []):
    if block.get(\"type\") == \"text\":
        print(block[\"text\"])
" <<< "$response"
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

    local summary
    summary=$(_call_claude "$prompt") || return 1

    echo "$summary"

    local outfile="$_SESSION_LOG_DIR/${s_name}_jira_$(date \'+%Y%m%d_%H%M%S\').md"
    {
        echo "# Jira Summary — $s_name"
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
# jira-update [session-name] <JIRA-KEY> [extra context] — progress update/comment
# Generates a comment draft for an existing ticket using the session log.
# ---------------------------------------------------------------------------
jira-update() {
    local session_arg=""
    local jira_key="$1"

    # If first arg matches a saved session, treat it as session name
    if [[ -n "$1" && -f "$_SESSION_LOG_DIR/$1.state" ]]; then
        session_arg="$1"
        jira_key="$2"
        shift 2
    else
        shift
    fi

    if [[ -z "$jira_key" ]]; then
        echo "Usage: jira-update [session-name] <JIRA-KEY> [extra context]" >&2
        return 1
    fi

    local resolved
    resolved=$(_session_resolve "$session_arg") || return 1
    read -r s_name s_start s_end <<< "$resolved"

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

    local extra_context="${*}"

    local prompt="You are a senior engineer writing a progress update comment for Jira ticket $jira_key.

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

Produce a concise, professional Jira comment with these sections:

**Progress Update** (what was achieved this session, 2–3 sentences)
**Technical Changes** (bullet list: key commands, files changed, decisions made)
**Next Steps** (bullet list: what remains to complete $jira_key)

Be specific. Infer progress from the commands and description."

    echo "⏳ Generating update for $jira_key via Claude..."

    local update
    update=$(_call_claude "$prompt") || return 1

    echo "$update"

    local outfile="$_SESSION_LOG_DIR/${s_name}_${jira_key}_update_$(date \'+%Y%m%d_%H%M%S\').md"
    {
        echo "# Jira Update — $jira_key ($s_name)"
        echo "# Generated: $(date)"
        echo ""
        echo "$update"
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
# _markdown_to_adf <text> — convert simple markdown to Atlassian Document Format
# ---------------------------------------------------------------------------
_markdown_to_adf() {
    local md_text="$1"
    python3 - "$md_text" <<'PYEOF'
import json, sys, re

text = sys.argv[1]
nodes = []
list_items = []

def flush_list():
    if list_items:
        nodes.append({"type": "bulletList", "content": list_items[:]})
        list_items.clear()

def parse_inline(s):
    parts = re.split(r"(\*\*[^*]+\*\*)", s)
    inline = []
    for p in parts:
        if p.startswith("**") and p.endswith("**"):
            inline.append({"type":"text","text":p[2:-2],"marks":[{"type":"strong"}]})
        elif p:
            inline.append({"type":"text","text":p})
    return inline

for line in text.splitlines():
    s = line.strip()
    if not s:
        flush_list()
        continue
    if s.startswith("- ") or s.startswith("* "):
        list_items.append({"type":"listItem","content":[{"type":"paragraph","content":parse_inline(s[2:])}]})
    elif s.startswith("**") and s.endswith("**"):
        flush_list()
        nodes.append({"type":"paragraph","content":[{"type":"text","text":s[2:-2],"marks":[{"type":"strong"}]}]})
    else:
        flush_list()
        nodes.append({"type":"paragraph","content":parse_inline(s)})

flush_list()
print(json.dumps({"version":1,"type":"doc","content":nodes}))
PYEOF
}

# ---------------------------------------------------------------------------
# _session_set_jira_key <session-name> <jira-key> — write key into .state file
# ---------------------------------------------------------------------------
_session_set_jira_key() {
    local name="$1" key="$2"
    local statefile="$_SESSION_LOG_DIR/${name}.state"
    if grep -q "^jira_key=" "$statefile" 2>/dev/null; then
        sed -i.bak "s/^jira_key=.*/jira_key=$key/" "$statefile" && rm -f "${statefile}.bak"
    else
        echo "jira_key=$key" >> "$statefile"
    fi
    if [[ "$name" == "$_ATUIN_SESSION_NAME" ]]; then
        _ATUIN_SESSION_JIRA_KEY="$key"
        if grep -q "^jira_key=" "$_SESSION_STATE_FILE" 2>/dev/null; then
            sed -i.bak "s/^jira_key=.*/jira_key=$key/" "$_SESSION_STATE_FILE" && rm -f "${_SESSION_STATE_FILE}.bak"
        else
            echo "jira_key=$key" >> "$_SESSION_STATE_FILE"
        fi
    fi
}

# ---------------------------------------------------------------------------
# _open_url <url> — open in default browser, macOS + Linux
# ---------------------------------------------------------------------------
_open_url() {
    if command -v open &>/dev/null; then
        open "$1"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$1"
    else
        echo "   (No browser opener found — visit manually: $1)"
    fi
}

# ---------------------------------------------------------------------------
# jira-push [session-name] [--type Task|Story|Bug]
# Reads the most recent jira-summary .md, parses it, and POSTs to Jira API.
# Saves the new ticket key back to the session .state file and opens the URL.
# ---------------------------------------------------------------------------
jira-push() {
    local session_arg=""
    if [[ -n "$1" && -f "$_SESSION_LOG_DIR/$1.state" ]]; then
        session_arg="$1"; shift
    fi

    local issue_type="Task"
    if [[ "$1" == "--type" && -n "$2" ]]; then
        issue_type="$2"; shift 2
    fi

    local resolved
    resolved=$(_session_resolve "$session_arg") || return 1
    read -r s_name s_start s_end <<< "$resolved"

    # Check required env vars
    local missing=()
    [[ -z "$JIRA_BASE_URL" ]]    && missing+=("JIRA_BASE_URL")
    [[ -z "$JIRA_EMAIL" ]]       && missing+=("JIRA_EMAIL")
    [[ -z "$JIRA_API_TOKEN" ]]   && missing+=("JIRA_API_TOKEN")
    [[ -z "$JIRA_PROJECT_KEY" ]] && missing+=("JIRA_PROJECT_KEY")
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "⚠  Missing required environment variables:" >&2
        printf "     %s\n" "${missing[@]}" >&2
        echo "   Set these in ~/.config/atuin-session-logger/env" >&2
        return 1
    fi

    # Find the most recent jira summary .md for this session
    local summary_file
    summary_file=$(ls -t "$_SESSION_LOG_DIR/${s_name}_jira_"*.md 2>/dev/null | head -1)
    if [[ -z "$summary_file" ]]; then
        echo "No jira-summary found for '$s_name'. Run 'jira-summary' first." >&2
        return 1
    fi
    echo "📄 Using: $(basename "$summary_file")"

    # Parse **Summary** line — try same-line value first, then next line
    local jira_summary
    jira_summary=$(grep -m1 "^\*\*Summary\*\*" "$summary_file" \
        | sed 's/\*\*Summary\*\*[[:space:]]*//' | sed 's/^[[:space:]]*//')
    if [[ -z "$jira_summary" ]]; then
        jira_summary=$(awk '/^\*\*Summary\*\*/{found=1;next} found&&NF{print;exit}' "$summary_file")
    fi
    if [[ -z "$jira_summary" ]]; then
        echo "❌ Could not parse a Summary line from $(basename "$summary_file")." >&2
        return 1
    fi

    # Extract everything between **Description** and the next **Section**
    local description_md
    description_md=$(awk '/^\*\*Description\*\*/{found=1;next} found&&/^\*\*[A-Z]/{exit} found{print}' \
        "$summary_file" | sed '/^[[:space:]]*$/d')
    [[ -z "$description_md" ]] && description_md=$(cat "$summary_file")

    # Convert to ADF
    local adf_body
    adf_body=$(_markdown_to_adf "$description_md")
    if [[ $? -ne 0 || -z "$adf_body" ]]; then
        echo "❌ Failed to convert description to ADF." >&2; return 1
    fi

    # Build payload
    local payload
    payload=$(python3 -c "
import json, sys
summary, adf_raw, itype, proj, account_id = sys.argv[1:6]
fields = {
    'project':     {'key': proj},
    'summary':     summary,
    'description': json.loads(adf_raw),
    'issuetype':   {'name': itype}
}
if account_id:
    fields['assignee'] = {'accountId': account_id}
print(json.dumps({'fields': fields}))
" "$jira_summary" "$adf_body" "$issue_type" "$JIRA_PROJECT_KEY" "${JIRA_ACCOUNT_ID:-}")

    echo "⏳ Creating $issue_type in $JIRA_PROJECT_KEY..."

    local response http_code
    response=$(curl -s -w "\n%{http_code}" \
        -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        "$JIRA_BASE_URL/rest/api/3/issue" \
        -d "$payload")

    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "201" ]]; then
        echo "❌ Jira API returned HTTP $http_code:" >&2
        echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('errorMessages',[])); print(d.get('errors',{}))" 2>/dev/null || echo "$response" >&2
        return 1
    fi

    local jira_key jira_url
    jira_key=$(python3 -c "import json,sys; print(json.load(sys.stdin)['key'])" <<< "$response")
    jira_url="${JIRA_BASE_URL}/browse/${jira_key}"

    echo "✅ Created: $jira_key"
    echo "   $jira_url"

    _session_set_jira_key "$s_name" "$jira_key"
    echo "💾 Key saved to session state."

    _open_url "$jira_url"
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
  jira-summary [name] [context]         Generate Jira ticket draft via Claude API
  jira-push    [name] [--type T]        Push draft to Jira (creates ticket)
  jira-update  [name] <KEY> [context]   Generate a progress update comment

Environment Variables
─────────────────────
  ANTHROPIC_API_KEY        Required for jira-summary, jira-update
  JIRA_BASE_URL            e.g. https://yourworkspace.atlassian.net
  JIRA_EMAIL               Your Atlassian account email
  JIRA_API_TOKEN           Atlassian API token
  JIRA_PROJECT_KEY         Default project key, e.g. AUTH
  JIRA_ACCOUNT_ID          Atlassian account ID (auto-assigns tickets to you)
  ATUIN_SESSION_LOG_DIR    Where state + summaries are saved (default: ~/.session_logs)

Typical workflow
────────────────
  startlog fix-auth-bug
  describe                          # write intent/context before you start
  # ... do your work ...
  describe                          # optionally update mid-session
  stoplog
  jira-summary                      # generate draft
  jira-push                         # push to Jira, opens in browser

  # Named session, from any terminal:
  dumplog fix-auth-bug
  jira-summary fix-auth-bug
  jira-push fix-auth-bug --type Story

Files written per session
─────────────────────────
  ~/.session_logs/<name>.state      timestamps (auto-restored on new shell)
  ~/.session_logs/<name>.desc       your description
  ~/.session_logs/<name>_jira_*.md  generated ticket drafts
EOF
}