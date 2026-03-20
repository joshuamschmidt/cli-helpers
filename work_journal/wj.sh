#!/usr/bin/env bash
# =============================================================================
# wj.sh — work journal entry point
#
# USAGE:
#   source ~/.wj/wj.sh        # add to .zshrc / .bashrc
#
# COMMANDS:
#   wj start  [<todo-id> | <n>]       Begin a named or todo-linked session
#   wj stop   [--pause]               End the current session
#   wj load   <n>                     Restore a past session
#   wj ls                             List all saved sessions
#   wj note   [text]                  Add a note to current session (Ctrl-D multiline)
#   wj dump   [<n>]                   Print notes + command history for a session
#
#   wj todo add  "desc" [--tag <t>]   Create a new todo item
#   wj todo ls   [--pending|--done…]  List today's todos
#   wj todo done <id>                 Mark a todo done manually
#   wj todo rollover                  Copy pending/paused items from yesterday
#
#   wj obs status                     Check Obsidian API connection
#   wj help                           Show this help
#
# ENVIRONMENT:
#   WJ_DIR               Storage root (default: ~/.wj)
#   OBSIDIAN_API_KEY     Enables Obsidian integration
#   OBSIDIAN_VAULT_URL   Obsidian API base URL (default: https://127.0.0.1:27124)
#   OBSIDIAN_DAILY_DIR   Vault-relative path to daily notes (default: Daily)
# =============================================================================

_WJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Source core modules
# ---------------------------------------------------------------------------
# shellcheck source=lib/todo.sh
source "${_WJ_ROOT}/lib/todo.sh"
# shellcheck source=lib/session.sh
source "${_WJ_ROOT}/lib/session.sh"

# Source notes + history modules if present (written separately)
[[ -f "${_WJ_ROOT}/lib/notes.sh"   ]] && source "${_WJ_ROOT}/lib/notes.sh"
[[ -f "${_WJ_ROOT}/lib/history.sh" ]] && source "${_WJ_ROOT}/lib/history.sh"

# ---------------------------------------------------------------------------
# Source optional integrations
# ---------------------------------------------------------------------------
if [[ -n "$OBSIDIAN_API_KEY" ]]; then
    [[ -f "${_WJ_ROOT}/integrations/obsidian.sh" ]] \
        && source "${_WJ_ROOT}/integrations/obsidian.sh"
fi

[[ -f "${_WJ_ROOT}/integrations/jira.sh"   ]] \
    && source "${_WJ_ROOT}/integrations/jira.sh"
[[ -f "${_WJ_ROOT}/integrations/ai.sh"     ]] \
    && source "${_WJ_ROOT}/integrations/ai.sh"
[[ -f "${_WJ_ROOT}/integrations/export.sh" ]] \
    && source "${_WJ_ROOT}/integrations/export.sh"

# ---------------------------------------------------------------------------
# Auto-discover user plugins
# ---------------------------------------------------------------------------
_wj_plugin_dir="${WJ_DIR:-$HOME/.wj}/plugins"
if [[ -d "$_wj_plugin_dir" ]]; then
    for _wj_plugin in "${_wj_plugin_dir}"/*.sh; do
        [[ -f "$_wj_plugin" ]] && source "$_wj_plugin"
    done
    unset _wj_plugin
fi
unset _wj_plugin_dir

# ---------------------------------------------------------------------------
# Auto-rollover check — on first wj command of the day
# ---------------------------------------------------------------------------
_wj_rollover_check() {
    local stamp_file="${WJ_DIR:-$HOME/.wj}/.last_rollover"
    local today
    today=$(date '+%Y-%m-%d')
    if [[ ! -f "$stamp_file" ]] || [[ "$(cat "$stamp_file")" != "$today" ]]; then
        echo "$today" > "$stamp_file"
        if declare -f wj_todo_rollover &>/dev/null; then
            wj_todo_rollover
        fi
    fi
}

# ---------------------------------------------------------------------------
# wj — main dispatcher
# ---------------------------------------------------------------------------
wj() {
    _wj_rollover_check

    local cmd="${1:-help}"
    shift || true

    case "$cmd" in

        start)      wj_start "$@" ;;
        stop)       wj_stop "$@" ;;
        load)       wj_load "$@" ;;
        ls|list)    wj_ls "$@" ;;

        note)
            if declare -f wj_note &>/dev/null; then
                wj_note "$@"
            else
                echo "  notes.sh not loaded." >&2
            fi
            ;;

        dump)
            if declare -f wj_dump &>/dev/null; then
                wj_dump "$@"
            else
                echo "  history.sh not loaded." >&2
            fi
            ;;

        todo)
            local sub="${1:-ls}"
            shift || true
            case "$sub" in
                add)      wj_todo_add "$@" ;;
                ls|list)  wj_todo_ls "$@" ;;
                done)     wj_todo_done "$@" ;;
                rollover) wj_todo_rollover "$@" ;;
                *)
                    echo "  Unknown todo subcommand: $sub" >&2
                    echo "  Usage: wj todo [add|ls|done|rollover]" >&2
                    return 1
                    ;;
            esac
            ;;

        obs)
            local sub="${1:-status}"
            shift || true
            case "$sub" in
                status)
                    if declare -f wj_obs_status &>/dev/null; then
                        wj_obs_status
                    else
                        echo "  Obsidian integration not loaded (OBSIDIAN_API_KEY not set?)."
                    fi
                    ;;
                *)
                    echo "  Unknown obs subcommand: $sub" >&2
                    return 1
                    ;;
            esac
            ;;

        summarise|summarize)
            if declare -f wj_summarise &>/dev/null; then
                wj_summarise "$@"
            else
                echo "  ai.sh not loaded." >&2
            fi
            ;;

        push)
            if declare -f wj_push &>/dev/null; then
                wj_push "$@"
            else
                echo "  jira.sh not loaded." >&2
            fi
            ;;

        export)
            if declare -f wj_export &>/dev/null; then
                wj_export "$@"
            else
                echo "  export.sh not loaded." >&2
            fi
            ;;

        help|--help|-h)
            _wj_help
            ;;

        *)
            echo "  Unknown command: $cmd" >&2
            _wj_help
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# _wj_help
# ---------------------------------------------------------------------------
_wj_help() {
    cat <<'EOF'
wj — work journal

  wj start  [<todo-id> | <name>]       Begin a session (links to todo if ID given)
  wj stop   [--pause]                  End or pause the current session
  wj load   <name>                     Restore a past session as current
  wj ls                                List all saved sessions
  wj note   ["text"]                   Add a note (inline or Ctrl-D multiline)
  wj dump   [<name>]                   Print notes + command history

  wj todo add  "description" [--tag t] Create a new todo item
  wj todo ls   [--pending|--active|--paused|--done|--all]
  wj todo done <id>                    Mark done without an active session
  wj todo rollover                     Copy yesterday's unfinished items to today

  wj obs status                        Check Obsidian API connection
  wj summarise [<name>]                Generate AI summary via Claude
  wj push      [<name>] [--type T]     Push summary to Jira
  wj export    [<name>] [--format md]  Export session to file

  wj help                              Show this help

Environment
  WJ_DIR               Storage root           (default: ~/.wj)
  OBSIDIAN_API_KEY     Enables Obsidian sync
  OBSIDIAN_DAILY_DIR   Daily notes path        (default: Daily)
  ANTHROPIC_API_KEY    Enables wj summarise
  JIRA_BASE_URL        Enables wj push

Typical flow
  wj todo add "fix token refresh race condition"   # → todo-a3f2
  wj start todo-a3f2
  wj note "root cause: mutex not held across async boundary"
  wj stop
  wj summarise && wj push
EOF
}

# ---------------------------------------------------------------------------
# Tab completion (bash)
# ---------------------------------------------------------------------------
if [[ -n "$BASH_VERSION" ]]; then
    _wj_complete() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        local prev="${COMP_WORDS[COMP_CWORD-1]}"

        case "$prev" in
            wj)
                COMPREPLY=( $(compgen -W \
                    "start stop load ls note dump todo obs summarise push export help" \
                    -- "$cur") )
                ;;
            todo)
                COMPREPLY=( $(compgen -W "add ls done rollover" -- "$cur") )
                ;;
            load)
                local sessions
                sessions=$(ls "${WJ_DIR:-$HOME/.wj}/sessions/"*.state 2>/dev/null \
                    | xargs -I{} basename {} .state 2>/dev/null)
                COMPREPLY=( $(compgen -W "$sessions" -- "$cur") )
                ;;
            done)
                # Complete todo IDs
                local ids
                ids=$(cut -d'|' -f1 \
                    "${WJ_DIR:-$HOME/.wj}/todos/$(date '+%Y-%m-%d').todo" 2>/dev/null)
                COMPREPLY=( $(compgen -W "$ids" -- "$cur") )
                ;;
        esac
    }
    complete -F _wj_complete wj
fi
