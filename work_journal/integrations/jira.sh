#!/usr/bin/env bash
# =============================================================================
# jira.sh — Jira integration for wj
#
# Part of wj (work journal). Source via wj.sh when JIRA_BASE_URL is set.
#
# Exposes:
#   wj_push   [<n>] [--type Task|Story|Bug]
#   wj_update [<n>] <JIRA-KEY> [<context>]
#
# ENVIRONMENT (set in ~/.config/wj/env or export in .zshrc):
#   JIRA_BASE_URL       e.g. https://yourworkspace.atlassian.net
#   JIRA_EMAIL          your Atlassian account email
#   JIRA_API_TOKEN      your Atlassian API token
#   JIRA_PROJECT_KEY    default project key, e.g. AUTH
#   JIRA_ACCOUNT_ID     your account ID (for auto-assign, optional)
# =============================================================================

# ---------------------------------------------------------------------------
# _wj_jira_check_env — verify required vars are set
# ---------------------------------------------------------------------------
_wj_jira_check_env() {
    local missing=()
    [[ -z "$JIRA_BASE_URL" ]]    && missing+=("JIRA_BASE_URL")
    [[ -z "$JIRA_EMAIL" ]]       && missing+=("JIRA_EMAIL")
    [[ -z "$JIRA_API_TOKEN" ]]   && missing+=("JIRA_API_TOKEN")
    [[ -z "$JIRA_PROJECT_KEY" ]] && missing+=("JIRA_PROJECT_KEY")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "  Missing Jira environment variables:" >&2
        printf '    %s\n' "${missing[@]}" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# _wj_jira_find_summary <n> — locate the most recent summary .md for a session
# ---------------------------------------------------------------------------
_wj_jira_find_summary() {
    local name="$1"
    local session_dir="${_WJ_SESSION_DIR:-${WJ_DIR:-$HOME/.wj}/sessions}"

    ls -t "${session_dir}/${name}_summary_"*.md 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# _wj_markdown_to_adf <markdown_text>
# Converts a markdown string to Atlassian Document Format JSON.
# Ported directly from the original atuin_session_logger.sh.
# ---------------------------------------------------------------------------
_wj_markdown_to_adf() {
    local md="$1"

    # Write the converter to a temp file to avoid backtick/quoting issues
    # inside bash process substitution
    local tmppy
    tmppy=$(mktemp /tmp/wj_adf_XXXXXX.py)
    cat > "$tmppy" << 'PYEOF'
import json, re, sys

md = sys.argv[1]
nodes = []
list_items = []
list_type  = None
BACKTICK = chr(96)

def parse_inline(s):
    parts, buf, i = [], '', 0
    while i < len(s):
        if s[i:i+2] == '**':
            if buf: parts.append({'type':'text','text':buf}); buf=''
            j = s.find('**', i+2)
            if j == -1: buf += s[i:]; break
            parts.append({'type':'text','text':s[i+2:j],
                          'marks':[{'type':'strong'}]}); i = j+2
        elif s[i] == BACKTICK:
            if buf: parts.append({'type':'text','text':buf}); buf=''
            j = s.find(BACKTICK, i+1)
            if j == -1: buf += s[i:]; break
            parts.append({'type':'text','text':s[i+1:j],
                          'marks':[{'type':'code'}]}); i = j+1
        else:
            buf += s[i]; i += 1
    if buf: parts.append({'type':'text','text':buf})
    return parts or [{'type':'text','text':''}]

def flush_list():
    global list_items, list_type
    if not list_items: return
    node_type = 'bulletList' if list_type=='ul' else 'orderedList'
    nodes.append({'type':node_type,'content':[
        {'type':'listItem','content':[
            {'type':'paragraph','content':parse_inline(t)}
        ]} for t in list_items
    ]})
    list_items.clear()
    list_type = None

for line in md.splitlines():
    if re.match(r'^#{1,3} ', line):
        flush_list()
        lvl = len(re.match(r'^(#+)', line).group(1))
        text = re.sub(r'^#+\s*', '', line)
        nodes.append({'type':'heading','attrs':{'level':min(lvl,3)},
                      'content':parse_inline(text)})
    elif re.match(r'^[-*] ', line):
        t = line[2:]
        if list_type and list_type != 'ul': flush_list()
        list_type = 'ul'; list_items.append(t)
    elif re.match(r'^\d+\. ', line):
        t = re.sub(r'^\d+\.\s*', '', line)
        if list_type and list_type != 'ol': flush_list()
        list_type = 'ol'; list_items.append(t)
    elif line.strip() == '':
        flush_list()
    else:
        flush_list()
        nodes.append({'type':'paragraph','content':parse_inline(line)})

flush_list()
print(json.dumps({'version':1,'type':'doc','content':nodes}))
PYEOF

    python3 "$tmppy" "$md"
    local exit_code=$?
    rm -f "$tmppy"
    return $exit_code
}

# ---------------------------------------------------------------------------
# wj_push [<n>] [--type Task|Story|Bug]
#
# Reads the most recent summary .md for the session and creates a Jira ticket.
# Saves the resulting key back into the session .state file.
# ---------------------------------------------------------------------------
wj_push() {
    _wj_jira_check_env || return 1

    local name_arg="" issue_type="Task"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) issue_type="$2"; shift 2 ;;
            *)      name_arg="$1"; shift ;;
        esac
    done

    local name="${name_arg:-$_WJ_SESSION_NAME}"
    if [[ -z "$name" ]]; then
        echo "  No session specified and no active session." >&2
        return 1
    fi

    local summary_file
    summary_file=$(_wj_jira_find_summary "$name")
    if [[ -z "$summary_file" ]]; then
        echo "  No summary found for '$name'. Run 'wj summarise' first." >&2
        return 1
    fi
    echo "  Using: $(basename "$summary_file")"

    # Parse **Summary** line
    local jira_summary
    jira_summary=$(grep -m1 '^\*\*Summary\*\*' "$summary_file" \
        | sed 's/\*\*Summary\*\*[[:space:]]*//' | sed 's/^[[:space:]]*//')
    if [[ -z "$jira_summary" ]]; then
        jira_summary=$(awk '/^\*\*Summary\*\*/{found=1;next} found&&NF{print;exit}' \
            "$summary_file")
    fi
    if [[ -z "$jira_summary" ]]; then
        echo "  Could not parse a Summary line from $(basename "$summary_file")." >&2
        return 1
    fi

    # Extract description (everything between **Problem** and next ** section)
    local description_md
    description_md=$(awk \
        '/^\*\*Problem\*\*/{found=1;next} found&&/^\*\*[A-Z]/{exit} found{print}' \
        "$summary_file" | sed '/^[[:space:]]*$/d')
    [[ -z "$description_md" ]] && description_md=$(cat "$summary_file")

    # Convert to ADF
    local adf_body
    adf_body=$(_wj_markdown_to_adf "$description_md") || {
        echo "  Failed to convert description to ADF." >&2
        return 1
    }

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
" "$jira_summary" "$adf_body" "$issue_type" \
  "$JIRA_PROJECT_KEY" "${JIRA_ACCOUNT_ID:-}") || return 1

    echo "  Creating $issue_type in $JIRA_PROJECT_KEY..."

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
        echo "  Jira API returned HTTP $http_code:" >&2
        echo "$response" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); \
             print(d.get('errorMessages',[])); print(d.get('errors',{}))" \
            2>/dev/null || echo "$response" >&2
        return 1
    fi

    local jira_key jira_url
    jira_key=$(python3 -c \
        "import json,sys; print(json.load(sys.stdin)['key'])" <<< "$response")
    jira_url="${JIRA_BASE_URL}/browse/${jira_key}"

    echo "  Created: $jira_key"
    echo "  $jira_url"

    # Save key back into session state
    _wj_session_set_field "$name" "jira_key" "$jira_key"
    echo "  Key saved to session state."

    # Open in browser
    _wj_open_url "$jira_url"
}

# ---------------------------------------------------------------------------
# wj_update [<n>] <JIRA-KEY> [<context>]
#
# Posts a progress update comment to an existing Jira ticket.
# ---------------------------------------------------------------------------
wj_update() {
    _wj_jira_check_env || return 1

    local name_arg="" jira_key="" context=""

    # Args: optional session name, required jira key, optional context
    for arg in "$@"; do
        if [[ -z "$name_arg" ]] && [[ -f "${_WJ_SESSION_DIR:-${WJ_DIR:-$HOME/.wj}/sessions}/${arg}.state" ]]; then
            name_arg="$arg"
        elif [[ -z "$jira_key" ]] && [[ "$arg" =~ ^[A-Z]+-[0-9]+$ ]]; then
            jira_key="$arg"
        else
            context="${context:+$context }$arg"
        fi
    done

    local name="${name_arg:-$_WJ_SESSION_NAME}"
    [[ -z "$name" ]]     && { echo "  No session specified." >&2; return 1; }
    [[ -z "$jira_key" ]] && { echo "  No Jira key specified (e.g. AUTH-217)." >&2; return 1; }

    # Build prompt for Claude
    local session_dump
    session_dump=$(wj_dump "$name" 2>/dev/null)

    local system_prompt="You are a technical writing assistant. Write a concise Jira
progress update comment (2-4 sentences) based on this work session data.
Focus on what changed, what was found, and what is next.
Output only the comment text, no preamble."

    local user_content="Session data:\n\n${session_dump}"
    [[ -n "$context" ]] && \
        user_content="${user_content}\n\nAdditional context: ${context}"

    echo "  Generating update for $jira_key..."

    local comment_text
    comment_text=$(_wj_ai_call "$system_prompt" "$user_content") || return 1

    # Convert to ADF for the Jira comment API
    local adf_body
    adf_body=$(_wj_markdown_to_adf "$comment_text") || return 1

    local payload
    payload=$(python3 -c \
        "import json,sys; print(json.dumps({'body': json.loads(sys.argv[1])}))" \
        "$adf_body")

    local response http_code
    response=$(curl -s -w "\n%{http_code}" \
        -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        "$JIRA_BASE_URL/rest/api/3/issue/${jira_key}/comment" \
        -d "$payload")

    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "201" ]]; then
        echo "  Jira API returned HTTP $http_code:" >&2
        echo "$response" >&2
        return 1
    fi

    echo "  Comment posted to $jira_key"
    echo ""
    echo "$comment_text"
}

# ---------------------------------------------------------------------------
# _wj_open_url <url> — open in default browser, macOS + Linux
# ---------------------------------------------------------------------------
_wj_open_url() {
    if command -v open &>/dev/null; then
        open "$1"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$1"
    else
        echo "  Visit: $1"
    fi
}
