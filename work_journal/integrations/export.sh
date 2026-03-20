#!/usr/bin/env bash
# =============================================================================
# export.sh — session export for wj
#
# Part of wj (work journal). Source via wj.sh.
#
# Exposes:
#   wj_export [<n>] [--format md|json] [--out <path>]
#
# Default format is markdown. Output goes to stdout unless --out is given.
# =============================================================================

wj_export() {
    local name_arg="" format="md" outpath=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format) format="$2"; shift 2 ;;
            --out)    outpath="$2"; shift 2 ;;
            *)        name_arg="$1"; shift ;;
        esac
    done

    local name="${name_arg:-$_WJ_SESSION_NAME}"
    if [[ -z "$name" ]]; then
        echo "  No session specified and no active session." >&2
        return 1
    fi

    case "$format" in
        md|markdown) _wj_export_md "$name" "$outpath" ;;
        json)        _wj_export_json "$name" "$outpath" ;;
        *)
            echo "  Unknown format '$format'. Use md or json." >&2
            return 1
            ;;
    esac
}

_wj_export_md() {
    local name="$1" outpath="$2"
    local content
    content=$(wj_dump "$name")

    if [[ -n "$outpath" ]]; then
        echo "$content" > "$outpath"
        echo "  Exported to $outpath"
    else
        echo "$content"
    fi
}

_wj_export_json() {
    local name="$1" outpath="$2"
    local session_dir="${_WJ_SESSION_DIR:-${WJ_DIR:-$HOME/.wj}/sessions}"

    local start="" end="" todo_id=""
    local statefile="${session_dir}/${name}.state"
    if [[ -f "$statefile" ]]; then
        start=$(grep '^start='   "$statefile" | cut -d= -f2)
        end=$(grep '^end='     "$statefile" | cut -d= -f2)
        todo_id=$(grep '^todo_id=' "$statefile" | cut -d= -f2)
    fi

    local notes=""
    local descfile="${session_dir}/${name}.desc"
    [[ -f "$descfile" ]] && notes=$(cat "$descfile")

    local cmd_count=0
    declare -f _wj_notes_cmd_count &>/dev/null \
        && cmd_count=$(_wj_notes_cmd_count "$name")

    local json
    json=$(python3 -c "
import json, sys
print(json.dumps({
    'session':   sys.argv[1],
    'start':     sys.argv[2],
    'end':       sys.argv[3],
    'todo_id':   sys.argv[4],
    'notes':     sys.argv[5],
    'cmd_count': int(sys.argv[6])
}, indent=2))
" "$name" "$start" "$end" "$todo_id" "$notes" "$cmd_count")

    if [[ -n "$outpath" ]]; then
        echo "$json" > "$outpath"
        echo "  Exported to $outpath"
    else
        echo "$json"
    fi
}
