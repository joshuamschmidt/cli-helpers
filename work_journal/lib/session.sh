#!/usr/bin/env bash
# =============================================================================
# session.sh — session lifecycle for the work journal
#
# Part of wj (work journal). Source this file; do not execute directly.
#
# Exposes:
#   wj_start  [<todo-id> | <name>]
#   wj_stop   [--pause]
#   wj_load   <name>
#   wj_ls
#   wj_session_resolve  [<name>]   → echoes "name start end"
#
# Internal helpers (used by other modules):
#   _wj_session_set_field <name> <key> <value>
#
# State variables (set after wj_start / wj_load / shell init):
#   _WJ_SESSION_NAME
#   _WJ_SESSION_START   ISO-8601
#   _WJ_SESSION_END     ISO-8601 or empty if in progress
#   _WJ_SESSION_TODO_ID todo-xxxx or empty if plain session
#
# Multi-shell behaviour:
#   Each shell gets its own .current.$$ file keyed by shell PID.
#   Multiple shells can run independent sessions simultaneously.
#   wj_ls reports all active .current.* files and flags orphaned ones
#   (whose PID is no longer running).
# =============================================================================

_WJ_SESSION_NAME=""
_WJ_SESSION_START=""
_WJ_SESSION_END=""
_WJ_SESSION_TODO_ID=""

_WJ_DIR="${WJ_DIR:-$HOME/.wj}"
_WJ_SESSION_DIR="$_WJ_DIR/sessions"
# PID-scoped so each shell has independent active-session state.
# $$ is the PID of the sourcing shell (not a subshell), which is what we want.
_WJ_CURRENT_FILE="$_WJ_SESSION_DIR/.current.$$"

# ---------------------------------------------------------------------------
# _wj_session_save / _wj_session_load — persist state across terminal sessions
# ---------------------------------------------------------------------------
_wj_session_save() {
    mkdir -p "$_WJ_SESSION_DIR"
    printf 'name=%s\nstart=%s\nend=%s\ntodo_id=%s\n' \
        "$_WJ_SESSION_NAME" \
        "$_WJ_SESSION_START" \
        "$_WJ_SESSION_END" \
        "$_WJ_SESSION_TODO_ID" \
        > "$_WJ_CURRENT_FILE"

    # Also write a named copy so wj_load can find it later
    cp "$_WJ_CURRENT_FILE" \
        "$_WJ_SESSION_DIR/${_WJ_SESSION_NAME}.state"
}

_wj_session_load_current() {
    [[ -f "$_WJ_CURRENT_FILE" ]] || return
    while IFS='=' read -r key val; do
        case "$key" in
            name)     _WJ_SESSION_NAME="$val"    ;;
            start)    _WJ_SESSION_START="$val"   ;;
            end)      _WJ_SESSION_END="$val"     ;;
            todo_id)  _WJ_SESSION_TODO_ID="$val" ;;
        esac
    done < "$_WJ_CURRENT_FILE"
}

# Auto-restore on shell start
_wj_session_load_current

# ---------------------------------------------------------------------------
# _wj_session_elapsed_seconds <start_iso> [<end_iso>]
# Returns elapsed seconds between start and now (or end).
# ---------------------------------------------------------------------------
_wj_session_elapsed_seconds() {
    local start="$1" end="${2:-$(date '+%Y-%m-%dT%H:%M:%S')}"

    # Try GNU date first, then BSD date
    local start_epoch end_epoch
    start_epoch=$(date -d "$start" '+%s' 2>/dev/null) \
        || start_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$start" '+%s' 2>/dev/null)
    end_epoch=$(date -d "$end" '+%s' 2>/dev/null) \
        || end_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$end" '+%s' 2>/dev/null)

    if [[ -n "$start_epoch" && -n "$end_epoch" ]]; then
        echo $(( end_epoch - start_epoch ))
    else
        echo 0
    fi
}

# ---------------------------------------------------------------------------
# wj_start [<todo-id> | <name>]
# ---------------------------------------------------------------------------
wj_start() {
    local arg="${1:-}"

    # Guard: warn if a session is already active
    if [[ -n "$_WJ_SESSION_NAME" && -z "$_WJ_SESSION_END" ]]; then
        echo "  Session '$_WJ_SESSION_NAME' is still active." >&2
        echo "  Run 'wj stop' first, or 'wj load <name>' to switch." >&2
        return 1
    fi

    local name todo_id=""

    # Detect whether the argument looks like a todo ID
    if [[ "$arg" == todo-* ]] || [[ "$arg" =~ ^[0-9a-f]{4}$ ]]; then
        # Resolve the todo — sets _WJ_TODO_ID and _WJ_TODO_DESC
        if declare -f _wj_todo_on_start &>/dev/null; then
            _wj_todo_on_start "$arg" || return 1
            todo_id="$_WJ_TODO_ID"
            name="$_WJ_TODO_DESC"
            # Sanitise description for use as a filename
            name=$(echo "$name" | tr '[:upper:]' '[:lower:]' \
                | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//' | cut -c1-48)
        else
            echo "  todo.sh is not loaded — cannot resolve todo IDs." >&2
            return 1
        fi
    elif [[ -n "$arg" ]]; then
        name="$arg"
    else
        name="session_$(date '+%Y%m%d_%H%M%S')"
    fi

    _WJ_SESSION_NAME="$name"
    _WJ_SESSION_START=$(date '+%Y-%m-%dT%H:%M:%S')
    _WJ_SESSION_END=""
    _WJ_SESSION_TODO_ID="$todo_id"

    _wj_session_save

    # Store Atuin's own session ID if available — used by history.sh to
    # query commands from this shell only, excluding other concurrent shells.
    [[ -n "$ATUIN_SESSION" ]] && \
        _wj_session_set_field "$name" "atuin_session" "$ATUIN_SESSION"

    echo "  started '$name'  $_WJ_SESSION_START${todo_id:+  [$todo_id]}"
    echo "  run your commands, then 'wj stop' when done."

    # Fire hook for other modules (e.g. obsidian.sh)
    _wj_hook_fire "session_start" "$name" "$_WJ_SESSION_START" "$todo_id"
}

# ---------------------------------------------------------------------------
# wj_stop [--pause]
# ---------------------------------------------------------------------------
wj_stop() {
    local pause_flag="${1:-}"

    if [[ -z "$_WJ_SESSION_START" ]]; then
        echo "  No active session. Run 'wj start' first." >&2
        return 1
    fi

    _WJ_SESSION_END=$(date '+%Y-%m-%dT%H:%M:%S')
    _wj_session_save

    local elapsed
    elapsed=$(_wj_session_elapsed_seconds "$_WJ_SESSION_START" "$_WJ_SESSION_END")

    # Notify todo module if this session had a todo attached
    if [[ -n "$_WJ_SESSION_TODO_ID" ]]; then
        if declare -f _wj_todo_on_stop &>/dev/null; then
            _wj_todo_on_stop "$_WJ_SESSION_TODO_ID" "$elapsed" "$pause_flag"
        fi
    fi

    local elapsed_fmt
    elapsed_fmt=$(declare -f _wj_todo_duration_fmt &>/dev/null \
        && _wj_todo_duration_fmt "$elapsed" \
        || printf '%dm' $(( elapsed / 60 )))

    local action="stopped"
    [[ "$pause_flag" == "--pause" ]] && action="paused"

    echo "  $action '$_WJ_SESSION_NAME'  $_WJ_SESSION_START → $_WJ_SESSION_END  ($elapsed_fmt)"

    # Fire hook for other modules
    _wj_hook_fire "session_stop" \
        "$_WJ_SESSION_NAME" "$_WJ_SESSION_START" "$_WJ_SESSION_END" \
        "$elapsed" "$_WJ_SESSION_TODO_ID" "$pause_flag"

    # Clear active state so the guard in wj_start works correctly
    if [[ "$pause_flag" != "--pause" ]]; then
        _WJ_SESSION_NAME=""
        _WJ_SESSION_START=""
        _WJ_SESSION_END=""
        _WJ_SESSION_TODO_ID=""
        rm -f "$_WJ_CURRENT_FILE"
    fi
}

# ---------------------------------------------------------------------------
# wj_load <name> — restore a named session as current
# ---------------------------------------------------------------------------
wj_load() {
    if [[ -z "$1" ]]; then
        echo "Usage: wj load <session-name>" >&2
        wj_ls
        return 1
    fi

    local statefile="$_WJ_SESSION_DIR/$1.state"
    if [[ ! -f "$statefile" ]]; then
        echo "  No saved session '$1' in $_WJ_SESSION_DIR" >&2
        return 1
    fi

    while IFS='=' read -r key val; do
        case "$key" in
            name)     _WJ_SESSION_NAME="$val"    ;;
            start)    _WJ_SESSION_START="$val"   ;;
            end)      _WJ_SESSION_END="$val"     ;;
            todo_id)  _WJ_SESSION_TODO_ID="$val" ;;
        esac
    done < "$statefile"

    cp "$statefile" "$_WJ_CURRENT_FILE"

    echo "  loaded '$_WJ_SESSION_NAME'  ${_WJ_SESSION_START} → ${_WJ_SESSION_END:-ongoing}${_WJ_SESSION_TODO_ID:+  [$_WJ_SESSION_TODO_ID]}"
}

# ---------------------------------------------------------------------------
# wj_ls — list all saved sessions, show active shells, clean up orphans
# ---------------------------------------------------------------------------
wj_ls() {
    # ── Active shells ────────────────────────────────────────────────────
    local current_files=( "$_WJ_SESSION_DIR"/.current.* )
    if [[ -e "${current_files[0]}" ]]; then
        local printed_header=0
        for cf in "${current_files[@]}"; do
            local cf_pid
            cf_pid="${cf##*.}"  # extract PID from .current.<pid>

            # Check if the PID is still alive
            if kill -0 "$cf_pid" 2>/dev/null; then
                local cf_name cf_start cf_todo
                cf_name=$(grep  '^name='    "$cf" | cut -d= -f2)
                cf_start=$(grep '^start='   "$cf" | cut -d= -f2)
                cf_todo=$(grep  '^todo_id=' "$cf" | cut -d= -f2)
                if (( printed_header == 0 )); then
                    echo "  Active shells:"
                    printed_header=1
                fi
                printf '    pid %-7s  %s%s  (since %s)\n' \
                    "$cf_pid" \
                    "$cf_name" \
                    "${cf_todo:+  [$cf_todo]}" \
                    "${cf_start:-?}"
            else
                # PID gone — orphaned file, remove silently
                rm -f "$cf"
            fi
        done
        (( printed_header )) && echo ""
    fi

    # ── Saved sessions ───────────────────────────────────────────────────
    if [[ ! -d "$_WJ_SESSION_DIR" ]] \
        || ! ls "$_WJ_SESSION_DIR"/*.state &>/dev/null; then
        echo "  No saved sessions in $_WJ_SESSION_DIR"
        return
    fi

    printf '  %-36s  %-20s  %-20s  %s\n' "name" "start" "end" "todo"
    printf '  %-36s  %-20s  %-20s  %s\n' \
        "------------------------------------" \
        "--------------------" \
        "--------------------" \
        "--------"

    for f in "$_WJ_SESSION_DIR"/*.state; do
        local name="" start="" end="" todo_id=""
        while IFS='=' read -r key val; do
            case "$key" in
                name)     name="$val"    ;;
                start)    start="$val"   ;;
                end)      end="$val"     ;;
                todo_id)  todo_id="$val" ;;
            esac
        done < "$f"
        printf '  %-36s  %-20s  %-20s  %s\n' \
            "$name" "$start" "${end:-ongoing}" "${todo_id:--}"
    done
}

# ---------------------------------------------------------------------------
# wj_session_resolve [<name>] — echo "name start end" for use by other modules
# Falls back to the active session if no name given.
# ---------------------------------------------------------------------------
wj_session_resolve() {
    local name="$1"

    if [[ -n "$name" ]]; then
        local statefile="$_WJ_SESSION_DIR/${name}.state"
        if [[ ! -f "$statefile" ]]; then
            echo "  No saved session '$name'" >&2
            return 1
        fi
        local r_name="" r_start="" r_end=""
        while IFS='=' read -r key val; do
            case "$key" in
                name)  r_name="$val"  ;;
                start) r_start="$val" ;;
                end)   r_end="$val"   ;;
            esac
        done < "$statefile"
        echo "$r_name $r_start $r_end"
    else
        if [[ -z "$_WJ_SESSION_NAME" ]]; then
            echo "  No active session." >&2
            return 1
        fi
        echo "$_WJ_SESSION_NAME $_WJ_SESSION_START $_WJ_SESSION_END"
    fi
}

# ---------------------------------------------------------------------------
# _wj_session_set_field <name> <key> <value>
# Generic key-value setter on a .state file — used by integrations.
# e.g. _wj_session_set_field fix-auth jira_key AUTH-217
# ---------------------------------------------------------------------------
_wj_session_set_field() {
    local name="$1" key="$2" value="$3"
    local statefile="$_WJ_SESSION_DIR/${name}.state"

    [[ -f "$statefile" ]] || { echo "  Session '$name' not found." >&2; return 1; }

    if grep -q "^${key}=" "$statefile" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${value}|" "$statefile" \
            && rm -f "${statefile}.bak"
    else
        echo "${key}=${value}" >> "$statefile"
    fi

    # Mirror to .current if this is the active session
    if [[ "$name" == "$_WJ_SESSION_NAME" && -f "$_WJ_CURRENT_FILE" ]]; then
        if grep -q "^${key}=" "$_WJ_CURRENT_FILE" 2>/dev/null; then
            sed -i.bak "s|^${key}=.*|${key}=${value}|" "$_WJ_CURRENT_FILE" \
                && rm -f "${_WJ_CURRENT_FILE}.bak"
        else
            echo "${key}=${value}" >> "$_WJ_CURRENT_FILE"
        fi
    fi
}

# ---------------------------------------------------------------------------
# _wj_hook_fire <event> [args...] — call any registered hook functions
# Modules register by defining _wj_hook_<module>_<event>().
# e.g. obsidian.sh defines _wj_hook_obsidian_session_start()
# ---------------------------------------------------------------------------
_wj_hook_fire() {
    local event="$1"; shift
    # Find all functions matching _wj_hook_*_<event>
    local fn
    while IFS= read -r fn; do
        [[ -n "$fn" ]] && "$fn" "$@"
    done < <(declare -F | awk -v ev="_wj_hook_.*_${event}$" '$3 ~ ev {print $3}')
}
