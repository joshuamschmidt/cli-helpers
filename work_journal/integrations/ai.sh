#!/usr/bin/env bash
# =============================================================================
# ai.sh — Claude API integration for wj
#
# Part of wj (work journal). Source via wj.sh when ANTHROPIC_API_KEY is set.
#
# Exposes:
#   wj_summarise [<n>] [<context>]
#     Generate a structured summary of a session using Claude.
#     Output is written to ~/.wj/sessions/<n>_summary_<ts>.md
#     and printed to stdout.
#
# ENVIRONMENT:
#   ANTHROPIC_API_KEY   required
#   WJ_AI_MODEL         optional, default claude-sonnet-4-6
#   WJ_AI_MAX_TOKENS    optional, default 1024
# =============================================================================

_WJ_AI_MODEL="${WJ_AI_MODEL:-claude-sonnet-4-6}"
_WJ_AI_MAX_TOKENS="${WJ_AI_MAX_TOKENS:-1024}"
_WJ_AI_ENDPOINT="https://api.anthropic.com/v1/messages"

# ---------------------------------------------------------------------------
# _wj_ai_call <system_prompt> <user_content> → echoes response text
# ---------------------------------------------------------------------------
_wj_ai_call() {
    local system="$1" user_content="$2"

    if [[ -z "$ANTHROPIC_API_KEY" ]]; then
        echo "  ANTHROPIC_API_KEY is not set." >&2
        return 1
    fi

    # Build JSON payload via python3 to handle escaping safely
    local payload
    payload=$(python3 -c "
import json, sys
system  = sys.argv[1]
content = sys.argv[2]
model   = sys.argv[3]
tokens  = int(sys.argv[4])
print(json.dumps({
    'model': model,
    'max_tokens': tokens,
    'system': system,
    'messages': [{'role': 'user', 'content': content}]
}))
" "$system" "$user_content" "$_WJ_AI_MODEL" "$_WJ_AI_MAX_TOKENS") || return 1

    local response http_code
    response=$(curl -s -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -X POST "$_WJ_AI_ENDPOINT" \
        -d "$payload")

    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        echo "  Claude API returned HTTP $http_code" >&2
        echo "$response" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message','unknown error'))" \
            2>/dev/null >&2
        return 1
    fi

    python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d['content'][0]['text'])
" <<< "$response"
}

# ---------------------------------------------------------------------------
# wj_summarise [<n>] [<context>]
#
# Collects session notes + command history, sends to Claude,
# writes output to a dated .md file and prints it.
# ---------------------------------------------------------------------------
wj_summarise() {
    local name_arg="" context=""

    # Parse args — first non-flag arg is name, second is context
    for arg in "$@"; do
        if [[ -z "$name_arg" ]]; then
            name_arg="$arg"
        else
            context="$arg"
        fi
    done

    local name="${name_arg:-$_WJ_SESSION_NAME}"
    if [[ -z "$name" ]]; then
        echo "  No session specified and no active session." >&2
        return 1
    fi

    echo "  Collecting session data for '$name'..."

    # Get full dump as context for Claude
    local session_dump
    session_dump=$(wj_dump "$name" 2>/dev/null)
    if [[ -z "$session_dump" ]]; then
        echo "  Could not retrieve session data for '$name'." >&2
        return 1
    fi

    local system_prompt
    system_prompt="You are a technical writing assistant helping a software developer
document their work session. Produce a structured summary in markdown with
these exact sections:

**Summary** — one sentence describing the core work done.
**Problem** — what issue or goal prompted this session.
**Approach** — key steps taken and decisions made.
**Outcome** — result: resolved, in-progress, blocked, etc.
**Follow-up** — any next actions or open questions.

Be concise and specific. Use the developer's own words where they are precise.
Do not invent details not present in the session data. Output only the markdown,
no preamble or explanation."

    local user_content="Session data:\n\n${session_dump}"
    [[ -n "$context" ]] && \
        user_content="${user_content}\n\nAdditional context from developer:\n${context}"

    echo "  Calling Claude (${_WJ_AI_MODEL})..."

    local result
    result=$(_wj_ai_call "$system_prompt" "$user_content") || return 1

    # Write to file
    local ts outfile
    ts=$(date '+%Y%m%d_%H%M%S')
    outfile="${_WJ_SESSION_DIR:-${WJ_DIR:-$HOME/.wj}/sessions}/${name}_summary_${ts}.md"

    printf '# Summary: %s\n_Generated: %s_\n\n%s\n' \
        "$name" "$(date '+%Y-%m-%d %H:%M')" "$result" \
        > "$outfile"

    echo ""
    cat "$outfile"
    echo ""
    echo "  Saved to: $outfile"

    # Fire Obsidian hook if available
    if declare -f _wj_obs_summary_add &>/dev/null; then
        _wj_obs_summary_add "$name" "$result"
    fi
}
