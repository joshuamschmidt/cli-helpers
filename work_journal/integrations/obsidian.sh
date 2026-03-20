#!/usr/bin/env bash
# =============================================================================
# obsidian.sh — Obsidian Local REST API integration for wj
#
# Part of wj (work journal). Source via wj.sh when OBSIDIAN_API_KEY is set.
# Never sourced directly by session.sh or todo.sh — hooks fire it instead.
#
# REQUIREMENTS:
#   Obsidian desktop app running
#   obsidian-local-rest-api plugin installed and enabled
#   https://github.com/coddingtonbear/obsidian-local-rest-api
#
# ENVIRONMENT:
#   OBSIDIAN_API_KEY     required — API key from the plugin settings
#   OBSIDIAN_VAULT_URL   optional — defaults to https://127.0.0.1:27124
#   OBSIDIAN_DAILY_DIR   optional — path inside vault to daily notes,
#                                   defaults to "Daily"
#   OBSIDIAN_TODO_HEADING   optional — heading for todos, default "Todo"
#   OBSIDIAN_SESSION_HEADING optional — heading for sessions, default "Sessions"
#
# HOOKS REGISTERED (called automatically by session.sh / todo.sh):
#   _wj_hook_obsidian_session_start  name start todo_id
#   _wj_hook_obsidian_session_stop   name start end elapsed_secs todo_id pause
#   _wj_obs_todo_add                 id desc tag
#   _wj_obs_todo_start               id desc
#   _wj_obs_todo_stop                id desc state duration_str
#   _wj_obs_todo_rollover            yesterday_date
# =============================================================================

_OBS_URL="${OBSIDIAN_VAULT_URL:-https://127.0.0.1:27124}"
_OBS_DAILY_DIR="${OBSIDIAN_DAILY_DIR:-Daily}"
_OBS_TODO_H="${OBSIDIAN_TODO_HEADING:-Todo}"
_OBS_SESSION_H="${OBSIDIAN_SESSION_HEADING:-Sessions}"

# ---------------------------------------------------------------------------
# _wj_obs_alive — returns 0 if the API is reachable, 1 otherwise (silent)
# ---------------------------------------------------------------------------
_wj_obs_alive() {
    [[ -z "$OBSIDIAN_API_KEY" ]] && return 1
    curl -ks --max-time 2 \
        -H "Authorization: Bearer $OBSIDIAN_API_KEY" \
        "${_OBS_URL}/" \
        -o /dev/null -w '%{http_code}' 2>/dev/null \
        | grep -q '^200$'
}

# ---------------------------------------------------------------------------
# _wj_obs_daily_path [<date>] — vault-relative path to a daily note
# e.g.  Daily/2026-03-20.md
# ---------------------------------------------------------------------------
_wj_obs_daily_path() {
    local date="${1:-$(date '+%Y-%m-%d')}"
    echo "${_OBS_DAILY_DIR}/${date}.md"
}

# ---------------------------------------------------------------------------
# _wj_obs_ensure_daily [<date>]
# Creates the daily note with frontmatter + headings if it doesn't exist.
# ---------------------------------------------------------------------------
_wj_obs_ensure_daily() {
    local date="${1:-$(date '+%Y-%m-%d')}"
    local path
    path=$(_wj_obs_daily_path "$date")

    # Check if it already exists
    local status
    status=$(curl -ks --max-time 3 \
        -H "Authorization: Bearer $OBSIDIAN_API_KEY" \
        -o /dev/null -w '%{http_code}' \
        "${_OBS_URL}/vault/${path}")

    [[ "$status" == "200" ]] && return 0

    # Create it
    local body
    body=$(printf '---\ndate: %s\n---\n\n## %s\n\n## %s\n' \
        "$date" "$_OBS_TODO_H" "$_OBS_SESSION_H")

    curl -ks --max-time 5 \
        -X PUT \
        -H "Authorization: Bearer $OBSIDIAN_API_KEY" \
        -H "Content-Type: text/markdown" \
        --data "$body" \
        "${_OBS_URL}/vault/${path}" \
        -o /dev/null
}

# ---------------------------------------------------------------------------
# _wj_obs_patch_heading <vault_path> <heading> <operation> <content>
# Append/prepend content under a named heading.
# operation: "append" | "prepend"
# ---------------------------------------------------------------------------
_wj_obs_patch_heading() {
    local vault_path="$1" heading="$2" operation="$3" content="$4"

    curl -ks --max-time 5 \
        -X PATCH \
        -H "Authorization: Bearer $OBSIDIAN_API_KEY" \
        -H "Operation: ${operation}" \
        -H "Target-Type: heading" \
        -H "Target: ${heading}" \
        -H "Create-Target-If-Missing: true" \
        -H "Content-Type: text/markdown" \
        --data "$content" \
        "${_OBS_URL}/vault/${vault_path}" \
        -o /dev/null
}

# ---------------------------------------------------------------------------
# _wj_obs_patch_block <vault_path> <block_id> <content>
# Replace a specific block reference line entirely.
# ---------------------------------------------------------------------------
_wj_obs_patch_block() {
    local vault_path="$1" block_id="$2" content="$3"

    curl -ks --max-time 5 \
        -X PATCH \
        -H "Authorization: Bearer $OBSIDIAN_API_KEY" \
        -H "Operation: replace" \
        -H "Target-Type: block" \
        -H "Target: ${block_id}" \
        -H "Content-Type: text/markdown" \
        --data "$content" \
        "${_OBS_URL}/vault/${vault_path}" \
        -o /dev/null
}

# ---------------------------------------------------------------------------
# _wj_obs_todo_add <id> <desc> <tag>
# Called by todo.sh after a new todo is created locally.
# ---------------------------------------------------------------------------
_wj_obs_todo_add() {
    local id="$1" desc="$2" tag="$3"
    _wj_obs_alive || return 0  # silent degradation

    local path
    path=$(_wj_obs_daily_path)
    _wj_obs_ensure_daily

    local line="- [ ] ${desc}  ^${id}"
    [[ -n "$tag" ]] && line="- [ ] ${desc}  [${tag}]  ^${id}"

    _wj_obs_patch_heading "$path" "$_OBS_TODO_H" "append" "$line"
}

# ---------------------------------------------------------------------------
# _wj_obs_todo_start <id> <desc>
# Mark a todo item active [/] in the daily note.
# ---------------------------------------------------------------------------
_wj_obs_todo_start() {
    local id="$1" desc="$2"
    _wj_obs_alive || return 0

    local path now
    path=$(_wj_obs_daily_path)
    now=$(date '+%Y-%m-%dT%H:%M:%S')

    local line="- [/] ${desc}  ^${id}  <!-- active | ${now} -->"
    _wj_obs_patch_block "$path" "$id" "$line"
}

# ---------------------------------------------------------------------------
# _wj_obs_todo_stop <id> <desc> <state> <duration_str>
# Mark a todo done [x] or paused [-] with duration inline.
# ---------------------------------------------------------------------------
_wj_obs_todo_stop() {
    local id="$1" desc="$2" state="$3" duration_str="$4"
    _wj_obs_alive || return 0

    local path now glyph
    path=$(_wj_obs_daily_path)
    now=$(date '+%Y-%m-%dT%H:%M:%S')

    case "$state" in
        done)   glyph="x" ;;
        paused) glyph="-" ;;
        *)      glyph="x" ;;
    esac

    local line="- [${glyph}] ${desc}  ^${id}  <!-- ${state} | ${now} | ${duration_str} -->"
    _wj_obs_patch_block "$path" "$id" "$line"
}

# ---------------------------------------------------------------------------
# _wj_hook_obsidian_session_start <name> <start_iso> <todo_id>
# Registered hook — called by session.sh via _wj_hook_fire.
# Appends a session header under ## Sessions in today's daily note.
# ---------------------------------------------------------------------------
_wj_hook_obsidian_session_start() {
    local name="$1" start="$2" todo_id="$3"
    _wj_obs_alive || return 0

    local path
    path=$(_wj_obs_daily_path)
    _wj_obs_ensure_daily

    local header="### ${name}"
    [[ -n "$todo_id" ]] && header="### ${name}  (${todo_id})"

    local content
    content=$(printf '%s\n**%s → ...**\n' "$header" "$start")

    _wj_obs_patch_heading "$path" "$_OBS_SESSION_H" "append" "$content"
}

# ---------------------------------------------------------------------------
# _wj_hook_obsidian_session_stop <name> <start> <end> <elapsed_secs> <todo_id> <pause>
# Updates the open session entry with end time and duration.
# Also appends the session note (description + command count) if available.
# ---------------------------------------------------------------------------
_wj_hook_obsidian_session_stop() {
    local name="$1" start="$2" end="$3" elapsed_secs="$4" \
          todo_id="$5" pause_flag="$6"
    _wj_obs_alive || return 0

    # Format duration using todo.sh helper if available, else plain minutes
    local dur_str
    dur_str=$(declare -f _wj_todo_duration_fmt &>/dev/null \
        && _wj_todo_duration_fmt "$elapsed_secs" \
        || printf '%dm' $(( elapsed_secs / 60 )))

    local path
    path=$(_wj_obs_daily_path)

    # Read description from local .desc file if it exists
    local desc_file="${_WJ_SESSION_DIR:-$HOME/.wj/sessions}/${name}.desc"
    local desc_content=""
    [[ -f "$desc_file" ]] && desc_content=$(cat "$desc_file")

    # Read command count from notes module if available
    local cmd_count=""
    if declare -f _wj_notes_cmd_count &>/dev/null; then
        cmd_count=$(_wj_notes_cmd_count "$name")
    fi

    # Build the session block to append
    local block
    block=$(printf '### %s%s\n**%s → %s · %s**\n' \
        "$name" \
        "${todo_id:+  ($todo_id)}" \
        "$start" "$end" "$dur_str")

    [[ -n "$desc_content" ]] && \
        block="${block}${desc_content}\n"
    [[ -n "$cmd_count" ]] && \
        block="${block}Commands: ${cmd_count}\n"

    # Replace the open session stub (started during wj_start hook)
    # by appending the completed version — Obsidian will show both;
    # the user can manually clean up the stub, or we could use a block ref.
    # For now append the completed record under ## Sessions.
    _wj_obs_patch_heading "$path" "$_OBS_SESSION_H" "append" "$block"
}

# ---------------------------------------------------------------------------
# _wj_obs_todo_rollover <yesterday_date>
# Append rolled-over items to today's daily note under ## Todo.
# The individual todo lines are already written by todo.sh locally;
# this mirrors them into Obsidian.
# ---------------------------------------------------------------------------
_wj_obs_todo_rollover() {
    local yesterday="$1"
    _wj_obs_alive || return 0

    local src_file
    src_file="${_WJ_DIR:-$HOME/.wj}/todos/${yesterday}.todo"
    [[ -f "$src_file" ]] || return 0

    local path
    path=$(_wj_obs_daily_path)
    _wj_obs_ensure_daily

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local state id desc tag total_secs
        state=$(echo "$line" | cut -d'|' -f2)
        id=$(echo "$line" | cut -d'|' -f1)
        desc=$(echo "$line" | cut -d'|' -f3)
        tag=$(echo "$line" | cut -d'|' -f4)
        total_secs=$(echo "$line" | cut -d'|' -f6)

        [[ "$state" == "pending" || "$state" == "paused" ]] || continue

        local glyph="[ ]"
        [[ "$state" == "paused" ]] && glyph="[-]"

        local dur_note=""
        if (( total_secs > 0 )); then
            local dur_str
            dur_str=$(declare -f _wj_todo_duration_fmt &>/dev/null \
                && _wj_todo_duration_fmt "$total_secs" \
                || printf '%dm' $(( total_secs / 60 )))
            dur_note="  <!-- rolled from ${yesterday}, ${dur_str} spent -->"
        fi

        local obs_line="- ${glyph} ${desc}${tag:+  [${tag}]}  ^${id}${dur_note}"
        _wj_obs_patch_heading "$path" "$_OBS_TODO_H" "append" "$obs_line"
    done < "$src_file"
}

# ---------------------------------------------------------------------------
# wj_obs_status — human-readable check of the Obsidian connection
# ---------------------------------------------------------------------------
wj_obs_status() {
    if [[ -z "$OBSIDIAN_API_KEY" ]]; then
        echo "  OBSIDIAN_API_KEY is not set — Obsidian integration disabled."
        return
    fi
    if _wj_obs_alive; then
        echo "  Obsidian API reachable at ${_OBS_URL}"
        echo "  Daily dir : ${_OBS_DAILY_DIR}"
        echo "  Todo heading   : ${_OBS_TODO_H}"
        echo "  Session heading: ${_OBS_SESSION_H}"
    else
        echo "  Obsidian API not reachable at ${_OBS_URL}"
        echo "  (Is Obsidian running with the Local REST API plugin enabled?)"
    fi
}
