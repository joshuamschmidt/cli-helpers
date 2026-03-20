#!/usr/bin/env bash
# =============================================================================
# history.sh — shell history backend adapter for wj
#
# Part of wj (work journal). Source this file; do not execute directly.
#
# Exposes (called by notes.sh and ai.sh):
#   _wj_history_dump  <n> <start_iso> <end_iso>
#   _wj_history_count <n>                          → echoes integer
#
# Backend selection (set WJ_HISTORY_BACKEND to override autodetect):
#   atuin      — preferred; queries via `atuin search`
#   zsh        — reads $HISTFILE with timestamps (setopt EXTENDED_HISTORY)
#   bash       — reads $HISTFILE (no timestamps)
#   plain      — reads a plain text file at WJ_HISTORY_FILE
#
# Atuin is used automatically if the `atuin` binary is on PATH.
# Falls back to zsh/bash HISTFILE parsing otherwise.
# =============================================================================

# ---------------------------------------------------------------------------
# _wj_history_backend — detect or honour override
# ---------------------------------------------------------------------------
_wj_history_backend() {
    if [[ -n "$WJ_HISTORY_BACKEND" ]]; then
        echo "$WJ_HISTORY_BACKEND"
        return
    fi
    if command -v atuin &>/dev/null; then
        echo "atuin"
    elif [[ -n "$ZSH_VERSION" ]]; then
        echo "zsh"
    else
        echo "bash"
    fi
}

# ---------------------------------------------------------------------------
# _wj_history_dump <n> <start_iso> <end_iso>
#
# Prints timestamped commands between start and end.
# Output format:
#   HH:MM  command
# One command per line, sorted chronologically.
# ---------------------------------------------------------------------------
_wj_history_dump() {
    local name="$1" start="$2" end="${3:-$(date '+%Y-%m-%dT%H:%M:%S')}"
    local backend
    backend=$(_wj_history_backend)

    # Read atuin_session from .state if present — used by atuin backend
    # to filter to this shell only, excluding concurrent shells.
    local atuin_session=""
    local statefile="${_WJ_SESSION_DIR:-${WJ_DIR:-$HOME/.wj}/sessions}/${name}.state"
    [[ -f "$statefile" ]] && \
        atuin_session=$(grep '^atuin_session=' "$statefile" 2>/dev/null \
            | cut -d= -f2)

    case "$backend" in
        atuin) _wj_history_dump_atuin "$start" "$end" "$atuin_session" ;;
        zsh)   _wj_history_dump_zsh   "$start" "$end" ;;
        bash)  _wj_history_dump_bash  "$start" "$end" ;;
        plain) _wj_history_dump_plain "$start" "$end" ;;
        *)
            echo "_Unknown history backend: $backend_" >&2
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# _wj_history_count <n> — returns number of commands in session
# ---------------------------------------------------------------------------
_wj_history_count() {
    local name="$1"
    local statefile="${_WJ_SESSION_DIR:-${WJ_DIR:-$HOME/.wj}/sessions}/${name}.state"
    local start="" end=""
    if [[ -f "$statefile" ]]; then
        start=$(grep '^start=' "$statefile" | cut -d= -f2)
        end=$(grep '^end='   "$statefile" | cut -d= -f2)
    fi
    [[ -z "$start" ]] && { echo 0; return; }

    _wj_history_dump "$name" "$start" "$end" 2>/dev/null | grep -c '.'
}

# ---------------------------------------------------------------------------
# ── Atuin backend ──────────────────────────────────────────────────────────
# ---------------------------------------------------------------------------
_wj_history_dump_atuin() {
    local start="$1" end="$2" atuin_session="${3:-}"

    # Prefer --session filter when available: this queries only commands from
    # the exact shell that ran wj_start, excluding any other concurrent shells.
    # Falls back to time-range query when atuin_session is not stored (e.g.
    # sessions started before this fix, or non-Atuin setups).
    local session_args=()
    if [[ -n "$atuin_session" ]]; then
        session_args=( --session "$atuin_session" )
    else
        session_args=( --after "$start" --before "$end" )
    fi

    atuin search \
        "${session_args[@]}" \
        --format "{time} {command}" \
        --no-exit-code \
        2>/dev/null \
    | grep -v '^\s*$' \
    | grep -v ' wj ' \
    | grep -v ' wj$' \
    | while IFS= read -r line; do
        local ts cmd
        ts=$(echo "$line" | awk '{print $1}')
        cmd=$(echo "$line" | cut -d' ' -f2-)
        local hhmm
        hhmm=$(echo "$ts" | grep -oP '\d{2}:\d{2}' | head -1)
        printf '%s  %s\n' "${hhmm:-??:??}" "$cmd"
    done
}

# ---------------------------------------------------------------------------
# ── Zsh backend (EXTENDED_HISTORY format) ──────────────────────────────────
# : <epoch>:<duration>;<command>
# ---------------------------------------------------------------------------
_wj_history_dump_zsh() {
    local start="$1" end="$2"
    local histfile="${HISTFILE:-$HOME/.zsh_history}"
    [[ -f "$histfile" ]] || { echo "_zsh HISTFILE not found: $histfile_"; return; }

    # Convert ISO to epoch for comparison
    local start_epoch end_epoch
    start_epoch=$(date -d "$start" '+%s' 2>/dev/null) \
        || start_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$start" '+%s' 2>/dev/null)
    end_epoch=$(date -d "$end" '+%s' 2>/dev/null) \
        || end_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$end" '+%s' 2>/dev/null)

    [[ -z "$start_epoch" || -z "$end_epoch" ]] && {
        echo "_Could not parse timestamps for zsh history query_"
        return
    }

    while IFS= read -r line; do
        # Extended history line: ": 1711000000:0;some command"
        if [[ "$line" =~ ^:\ ([0-9]+):[0-9]+\;(.+)$ ]]; then
            local epoch="${BASH_REMATCH[1]}" cmd="${BASH_REMATCH[2]}"
            if (( epoch >= start_epoch && epoch <= end_epoch )); then
                local hhmm
                hhmm=$(date -d "@$epoch" '+%H:%M' 2>/dev/null) \
                    || hhmm=$(date -r "$epoch" '+%H:%M' 2>/dev/null) \
                    || hhmm="??:??"
                [[ "$cmd" =~ ^wj\  || "$cmd" == "wj" ]] && continue
                printf '%s  %s\n' "$hhmm" "$cmd"
            fi
        fi
    done < "$histfile"
}

# ---------------------------------------------------------------------------
# ── Bash backend (no timestamps — best effort) ─────────────────────────────
# Without HISTTIMEFORMAT we can't filter by time precisely.
# We grab the last N commands written since session start as a heuristic.
# Users who want accurate history should switch to atuin.
# ---------------------------------------------------------------------------
_wj_history_dump_bash() {
    local start="$1" end="$2"
    local histfile="${HISTFILE:-$HOME/.bash_history}"
    [[ -f "$histfile" ]] || { echo "_bash HISTFILE not found: $histfile_"; return; }

    echo "_Note: bash history has no timestamps — showing last 50 commands._"
    echo ""

    tail -50 "$histfile" \
    | grep -v '^\s*$' \
    | grep -v '^wj ' \
    | grep -v '^wj$' \
    | while IFS= read -r cmd; do
        printf '??:??  %s\n' "$cmd"
    done
}

# ---------------------------------------------------------------------------
# ── Plain text backend ─────────────────────────────────────────────────────
# Reads WJ_HISTORY_FILE — one command per line, no timestamps.
# ---------------------------------------------------------------------------
_wj_history_dump_plain() {
    local histfile="${WJ_HISTORY_FILE:-}"
    [[ -z "$histfile" ]] && {
        echo "_WJ_HISTORY_FILE not set_"
        return
    }
    [[ -f "$histfile" ]] || {
        echo "_History file not found: $histfile_"
        return
    }

    grep -v '^\s*$' "$histfile" | while IFS= read -r cmd; do
        printf '??:??  %s\n' "$cmd"
    done
}
