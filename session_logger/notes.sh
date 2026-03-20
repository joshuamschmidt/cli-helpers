#!/usr/bin/env bash
# =============================================================================
# notes.sh — session notes for the work journal
#
# Part of wj (work journal). Source this file; do not execute directly.
#
# Exposes:
#   wj_note   ["text"]         Add a timestamped note to the current session
#   wj_dump   [<n>]            Print notes + command history for a session
#
# Internal helpers (used by other modules):
#   _wj_notes_desc_file <n>    Echo path to the .desc file for a session
#   _wj_notes_cmd_count <n>    Echo number of commands captured (for obsidian.sh)
#
# .desc file format:
#   Plain markdown. Each wj_note call appends a timestamped block:
#
#   <!-- note: 2026-03-20T09:22:14 -->
#   root cause: mutex not held across async boundary
#
#   Multiple calls accumulate — the file is a running log, not a single blob.
#   The first note written before wj start captures intent; subsequent notes
#   capture discoveries, pivots, and conclusions mid-session.
# =============================================================================

# ---------------------------------------------------------------------------
# _wj_notes_desc_file <n> — path to the .desc file for a named session
# ---------------------------------------------------------------------------
_wj_notes_desc_file() {
    local name="${1:-$_WJ_SESSION_NAME}"
    echo "${_WJ_SESSION_DIR:-${WJ_DIR:-$HOME/.wj}/sessions}/${name}.desc"
}

# ---------------------------------------------------------------------------
# _wj_notes_cmd_count <n> — number of commands in a session (for other modules)
# Delegates to history module if loaded; returns empty string if not.
# ---------------------------------------------------------------------------
_wj_notes_cmd_count() {
    local name="${1:-$_WJ_SESSION_NAME}"
    if declare -f _wj_history_count &>/dev/null; then
        _wj_history_count "$name"
    fi
}

# ---------------------------------------------------------------------------
# wj_note ["text"]
#
# With argument   — appends that text as a note immediately
# Without argument — opens a multiline stdin prompt (Ctrl-D to save)
#
# Both modes prepend a timestamp comment so notes stay ordered and
# distinguishable in wj dump output.
# ---------------------------------------------------------------------------
wj_note() {
    local name="${_WJ_SESSION_NAME}"

    if [[ -z "$name" ]]; then
        echo "  No active session. Run 'wj start' first." >&2
        echo "  (You can still pre-stage a note: wj note \"text\" before wj start)" >&2
        return 1
    fi

    local descfile
    descfile=$(_wj_notes_desc_file "$name")
    mkdir -p "$(dirname "$descfile")"

    local content
    if [[ $# -gt 0 ]]; then
        # Inline mode — argument is the note
        content="$*"
    else
        # Interactive multiline mode
        if [[ -f "$descfile" && -s "$descfile" ]]; then
            echo "  Notes so far for '$name':"
            echo "  ────────────────────────────"
            sed 's/^/  /' "$descfile"
            echo "  ────────────────────────────"
        fi
        echo "  Adding note to '$name' — Ctrl-D to save, Ctrl-C to cancel:"
        if ! content=$(cat); then
            echo "  Cancelled." >&2
            return 1
        fi
    fi

    if [[ -z "${content// }" ]]; then
        echo "  Empty note — nothing saved." >&2
        return 1
    fi

    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S')

    printf '<!-- note: %s -->\n%s\n\n' "$ts" "$content" >> "$descfile"
    echo "  note saved  [$ts]"

    # Fire Obsidian hook if available
    if declare -f _wj_obs_note_add &>/dev/null; then
        _wj_obs_note_add "$name" "$ts" "$content"
    fi
}

# ---------------------------------------------------------------------------
# wj_dump [<n>]
#
# Prints a formatted view of a session:
#   - Session metadata (name, times, todo link)
#   - All notes in order
#   - Command history (via history module if loaded)
#
# Output is valid markdown — can be piped to a file or to wj export.
# ---------------------------------------------------------------------------
wj_dump() {
    local name="${1:-$_WJ_SESSION_NAME}"

    if [[ -z "$name" ]]; then
        echo "  No session specified and no active session." >&2
        echo "  Usage: wj dump [<session-name>]" >&2
        return 1
    fi

    # Resolve metadata from .state file
    local resolved start end todo_id
    resolved=$(wj_session_resolve "$name" 2>/dev/null) || {
        echo "  Session '$name' not found." >&2
        return 1
    }
    read -r _ start end <<< "$resolved"

    # Read todo_id directly from .state file
    local statefile="${_WJ_SESSION_DIR:-${WJ_DIR:-$HOME/.wj}/sessions}/${name}.state"
    todo_id=$(grep '^todo_id=' "$statefile" 2>/dev/null | cut -d= -f2)

    # Compute duration if both timestamps present
    local duration_str=""
    if [[ -n "$start" && -n "$end" ]]; then
        local secs
        secs=$(_wj_session_elapsed_seconds "$start" "$end")
        duration_str=$(declare -f _wj_todo_duration_fmt &>/dev/null \
            && _wj_todo_duration_fmt "$secs" \
            || printf '%dm' $(( secs / 60 )))
    fi

    # ── Header ────────────────────────────────────────────────────────────
    echo "# ${name}"
    echo ""
    printf '**Start:** %s\n' "${start:-(unknown)}"
    printf '**End:**   %s%s\n' "${end:-(ongoing)}" \
        "${duration_str:+  ·  $duration_str}"
    [[ -n "$todo_id" ]] && printf '**Todo:**  %s\n' "$todo_id"
    echo ""

    # ── Notes ─────────────────────────────────────────────────────────────
    local descfile
    descfile=$(_wj_notes_desc_file "$name")

    if [[ -f "$descfile" && -s "$descfile" ]]; then
        echo "## Notes"
        echo ""
        cat "$descfile"
        echo ""
    else
        echo "## Notes"
        echo ""
        echo "_No notes recorded for this session._"
        echo ""
    fi

    # ── Commands ──────────────────────────────────────────────────────────
    if declare -f _wj_history_dump &>/dev/null; then
        echo "## Commands"
        echo ""
        _wj_history_dump "$name" "$start" "$end"
        echo ""
    else
        echo "## Commands"
        echo ""
        echo "_history.sh not loaded — command history unavailable._"
        echo ""
    fi
}
