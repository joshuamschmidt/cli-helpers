#!/usr/bin/env bash
# =============================================================================
# todo.sh — todo management for the work journal
#
# Part of wj (work journal). Source this file; do not execute directly.
#
# Exposes:
#   wj_todo_add   "description" [--tag <tag>]
#   wj_todo_ls    [--pending | --active | --paused | --done | --all]
#   wj_todo_done  <todo-id>
#   wj_todo_rollover
#
# Internal hooks (called by session.sh):
#   _wj_todo_on_start  <todo-id>
#   _wj_todo_on_stop   <todo-id> <duration_seconds> [--pause]
#
# State variables set after wj_todo_add or _wj_todo_resolve:
#   _WJ_TODO_ID    e.g. todo-a3f2
#   _WJ_TODO_DESC  e.g. "fix token refresh race condition"
#
# Local file format  (~/.wj/todos/YYYY-MM-DD.todo):
#   One entry per line, pipe-delimited:
#   <id>|<state>|<desc>|<tag>|<created_iso>|<total_seconds>|<last_started_iso>
#
#   States: pending | active | paused | done
# =============================================================================

_WJ_TODO_ID=""
_WJ_TODO_DESC=""

# ---------------------------------------------------------------------------
# _wj_todo_dir / _wj_todo_file — path helpers
# ---------------------------------------------------------------------------
_wj_todo_dir() {
    echo "${WJ_DIR:-$HOME/.wj}/todos"
}

_wj_todo_file() {
    local date="${1:-$(date '+%Y-%m-%d')}"
    echo "$(_wj_todo_dir)/${date}.todo"
}

# ---------------------------------------------------------------------------
# _wj_todo_gen_id — generate a short unique block ID
# ---------------------------------------------------------------------------
_wj_todo_gen_id() {
    local hex
    # Try multiple sources for portability
    if command -v od &>/dev/null; then
        hex=$(od -An -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | head -c8)
    fi
    if [[ -z "$hex" ]] && command -v xxd &>/dev/null; then
        hex=$(xxd -l4 -p /dev/urandom 2>/dev/null)
    fi
    if [[ -z "$hex" ]]; then
        hex=$(printf '%08x' $((RANDOM * RANDOM)))
    fi
    echo "todo-${hex:0:4}"
}

# ---------------------------------------------------------------------------
# _wj_todo_read_field <line> <field_number> — extract pipe-delimited field
# Fields: 1=id 2=state 3=desc 4=tag 5=created 6=total_secs 7=last_started
# ---------------------------------------------------------------------------
_wj_todo_read_field() {
    echo "$1" | cut -d'|' -f"$2"
}

# ---------------------------------------------------------------------------
# _wj_todo_resolve <id-or-partial> — find a todo entry by ID, echo the line
# ---------------------------------------------------------------------------
_wj_todo_resolve() {
    local query="$1"
    local todofile
    todofile=$(_wj_todo_file)

    [[ -f "$todofile" ]] || { echo "No todos for today." >&2; return 1; }

    local match
    match=$(grep "^${query}|" "$todofile" 2>/dev/null)
    if [[ -z "$match" ]]; then
        match=$(grep "^todo-${query}|" "$todofile" 2>/dev/null)
    fi
    if [[ -z "$match" ]]; then
        echo "Todo '${query}' not found in today's list." >&2
        return 1
    fi
    echo "$match"
}

# ---------------------------------------------------------------------------
# _wj_todo_update_line <id> <new_line> — replace a line in today's .todo file
# ---------------------------------------------------------------------------
_wj_todo_update_line() {
    local id="$1" new_line="$2"
    local todofile
    todofile=$(_wj_todo_file)
    [[ -f "$todofile" ]] || return 1

    local tmpfile="${todofile}.tmp"
    while IFS= read -r line; do
        if [[ "$line" == "${id}|"* ]]; then
            echo "$new_line"
        else
            echo "$line"
        fi
    done < "$todofile" > "$tmpfile"
    mv "$tmpfile" "$todofile"
}

# ---------------------------------------------------------------------------
# _wj_todo_duration_fmt <seconds> — format seconds as "1h 23m" or "45m"
# ---------------------------------------------------------------------------
_wj_todo_duration_fmt() {
    local secs="$1"
    local h=$(( secs / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    if (( h > 0 )); then
        echo "${h}h ${m}m"
    else
        echo "${m}m"
    fi
}

# ---------------------------------------------------------------------------
# _wj_todo_state_glyph <state> — return the markdown checkbox glyph
# ---------------------------------------------------------------------------
_wj_todo_state_glyph() {
    case "$1" in
        pending)  echo "[ ]" ;;
        active)   echo "[/]" ;;
        paused)   echo "[-]" ;;
        done)     echo "[x]" ;;
        *)        echo "[ ]" ;;
    esac
}

# ---------------------------------------------------------------------------
# wj_todo_add "description" [--tag <tag>]
# ---------------------------------------------------------------------------
wj_todo_add() {
    local desc="" tag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag) tag="$2"; shift 2 ;;
            *)     desc="$1"; shift ;;
        esac
    done

    if [[ -z "$desc" ]]; then
        echo "Usage: wj todo add \"description\" [--tag <tag>]" >&2
        return 1
    fi

    local id created todofile
    id=$(_wj_todo_gen_id)
    created=$(date '+%Y-%m-%dT%H:%M:%S')
    todofile=$(_wj_todo_file)

    mkdir -p "$(_wj_todo_dir)"

    # id|state|desc|tag|created|total_secs|last_started
    echo "${id}|pending|${desc}|${tag}|${created}|0|" >> "$todofile"

    _WJ_TODO_ID="$id"
    _WJ_TODO_DESC="$desc"

    echo "  ${id}  ${desc}${tag:+  [${tag}]}"

    # Fire Obsidian hook if available
    if declare -f _wj_obs_todo_add &>/dev/null; then
        _wj_obs_todo_add "$id" "$desc" "$tag"
    fi
}

# ---------------------------------------------------------------------------
# wj_todo_ls [--pending | --active | --paused | --done | --all]
# ---------------------------------------------------------------------------
wj_todo_ls() {
    local filter="today"
    [[ "$1" == "--all" ]]     && filter="all"
    [[ "$1" == "--pending" ]] && filter="pending"
    [[ "$1" == "--active" ]]  && filter="active"
    [[ "$1" == "--paused" ]]  && filter="paused"
    [[ "$1" == "--done" ]]    && filter="done"

    local todofile
    todofile=$(_wj_todo_file)

    if [[ ! -f "$todofile" ]] || [[ ! -s "$todofile" ]]; then
        echo "No todos today. Add one with: wj todo add \"description\""
        return
    fi

    local shown=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local id state desc tag total_secs
        id=$(_wj_todo_read_field "$line" 1)
        state=$(_wj_todo_read_field "$line" 2)
        desc=$(_wj_todo_read_field "$line" 3)
        tag=$(_wj_todo_read_field "$line" 4)
        total_secs=$(_wj_todo_read_field "$line" 6)

        # Apply filter
        if [[ "$filter" != "all" && "$filter" != "today" ]]; then
            [[ "$state" != "$filter" ]] && continue
        fi

        local glyph duration_str=""
        glyph=$(_wj_todo_state_glyph "$state")
        (( total_secs > 0 )) && duration_str="  $(_wj_todo_duration_fmt "$total_secs")"

        printf '  %s  %-14s  %s%s%s\n' \
            "$glyph" \
            "$id" \
            "$desc" \
            "${tag:+  [${tag}]}" \
            "$duration_str"
        (( shown++ ))
    done < "$todofile"

    (( shown == 0 )) && echo "  (none matching)"
}

# ---------------------------------------------------------------------------
# _wj_todo_on_start <todo-id> — called by session.sh when wj start <id>
# Marks item active, records start time, sets _WJ_TODO_ID / _WJ_TODO_DESC
# ---------------------------------------------------------------------------
_wj_todo_on_start() {
    local id="$1"
    local line
    line=$(_wj_todo_resolve "$id") || return 1

    local state desc tag created total_secs
    state=$(_wj_todo_read_field "$line" 2)
    desc=$(_wj_todo_read_field "$line" 3)
    tag=$(_wj_todo_read_field "$line" 4)
    created=$(_wj_todo_read_field "$line" 5)
    total_secs=$(_wj_todo_read_field "$line" 6)

    if [[ "$state" == "done" ]]; then
        echo "  Todo '$id' is already done. Start a new one or use a different ID." >&2
        return 1
    fi

    local now
    now=$(date '+%Y-%m-%dT%H:%M:%S')

    # id|state|desc|tag|created|total_secs|last_started
    local new_line="${id}|active|${desc}|${tag}|${created}|${total_secs}|${now}"
    _wj_todo_update_line "$id" "$new_line"

    _WJ_TODO_ID="$id"
    _WJ_TODO_DESC="$desc"

    # Fire Obsidian hook
    if declare -f _wj_obs_todo_start &>/dev/null; then
        _wj_obs_todo_start "$id" "$desc"
    fi
}

# ---------------------------------------------------------------------------
# _wj_todo_on_stop <todo-id> <session_duration_seconds> [--pause]
# Called by session.sh on wj stop. Accumulates time, updates state.
# ---------------------------------------------------------------------------
_wj_todo_on_stop() {
    local id="$1" session_secs="$2" pause_flag="$3"
    [[ -z "$id" ]] && return 0  # plain session, no todo attached

    local line
    line=$(_wj_todo_resolve "$id") || return 1

    local desc tag created total_secs
    desc=$(_wj_todo_read_field "$line" 3)
    tag=$(_wj_todo_read_field "$line" 4)
    created=$(_wj_todo_read_field "$line" 5)
    total_secs=$(_wj_todo_read_field "$line" 6)

    local new_total=$(( total_secs + session_secs ))
    local new_state="done"
    [[ "$pause_flag" == "--pause" ]] && new_state="paused"

    local new_line="${id}|${new_state}|${desc}|${tag}|${created}|${new_total}|"
    _wj_todo_update_line "$id" "$new_line"

    local duration_str
    duration_str=$(_wj_todo_duration_fmt "$new_total")

    if [[ "$new_state" == "done" ]]; then
        echo "  Todo '$id' done — total time: ${duration_str}"
    else
        echo "  Todo '$id' paused — accumulated: ${duration_str}"
    fi

    # Fire Obsidian hook
    if declare -f _wj_obs_todo_stop &>/dev/null; then
        _wj_obs_todo_stop "$id" "$desc" "$new_state" "$duration_str"
    fi
}

# ---------------------------------------------------------------------------
# wj_todo_done <todo-id> — mark done manually without a running session
# ---------------------------------------------------------------------------
wj_todo_done() {
    local id="$1"
    if [[ -z "$id" ]]; then
        echo "Usage: wj todo done <todo-id>" >&2
        return 1
    fi

    local line
    line=$(_wj_todo_resolve "$id") || return 1

    local desc tag created total_secs
    desc=$(_wj_todo_read_field "$line" 3)
    tag=$(_wj_todo_read_field "$line" 4)
    created=$(_wj_todo_read_field "$line" 5)
    total_secs=$(_wj_todo_read_field "$line" 6)

    local new_line="${id}|done|${desc}|${tag}|${created}|${total_secs}|"
    _wj_todo_update_line "$id" "$new_line"

    echo "  Marked done: ${id}  ${desc}"

    if declare -f _wj_obs_todo_stop &>/dev/null; then
        _wj_obs_todo_stop "$id" "$desc" "done" "$(_wj_todo_duration_fmt "$total_secs")"
    fi
}

# ---------------------------------------------------------------------------
# wj_todo_rollover — copy pending/paused items from yesterday into today
# ---------------------------------------------------------------------------
wj_todo_rollover() {
    local yesterday today
    yesterday=$(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null \
        || date -v-1d '+%Y-%m-%d' 2>/dev/null)  # GNU / BSD compat

    if [[ -z "$yesterday" ]]; then
        echo "Could not determine yesterday's date." >&2
        return 1
    fi

    local src_file dst_file
    src_file=$(_wj_todo_file "$yesterday")
    dst_file=$(_wj_todo_file)

    if [[ ! -f "$src_file" ]]; then
        echo "  No todo file found for $yesterday — nothing to roll over."
        return 0
    fi

    mkdir -p "$(_wj_todo_dir)"

    local rolled=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local state
        state=$(_wj_todo_read_field "$line" 2)
        if [[ "$state" == "pending" || "$state" == "paused" ]]; then
            # Check it's not already in today's file
            local id
            id=$(_wj_todo_read_field "$line" 1)
            if ! grep -q "^${id}|" "$dst_file" 2>/dev/null; then
                echo "$line" >> "$dst_file"
                local desc
                desc=$(_wj_todo_read_field "$line" 3)
                echo "  rolled over: ${id}  ${desc}  [${state}]"
                (( rolled++ ))
            fi
        fi
    done < "$src_file"

    if (( rolled == 0 )); then
        echo "  Nothing to roll over from $yesterday."
    else
        echo "  $rolled item(s) rolled over from $yesterday."
        # Fire Obsidian hook for bulk rollover
        if declare -f _wj_obs_todo_rollover &>/dev/null; then
            _wj_obs_todo_rollover "$yesterday"
        fi
    fi
}
