#!/bin/bash
# Mole - History command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/lib/core/history.sh"

HISTORY_JSON=false
HISTORY_LIMIT="$MOLE_HISTORY_DEFAULT_LIMIT"

show_history_help() {
    echo "Uso: mo history [OPÇÕES]"
    echo ""
    echo "Revise a atividade recente de operações e exclusões do Mole."
    echo ""
    echo "Opções:"
    echo "  --json           Exibe o histórico em JSON"
    echo "  --limit N        Mostra as N entradas mais recentes, 1-200"
    echo "  -h, --help       Mostra esta ajuda"
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            "--json")
                HISTORY_JSON=true
                ;;
            "--limit")
                shift
                if [[ $# -eq 0 ]]; then
                    echo "Valor ausente para --limit" >&2
                    exit 1
                fi
                if ! HISTORY_LIMIT=$(history_parse_limit "$1"); then
                    echo "Valor inválido para --limit: $1" >&2
                    exit 1
                fi
                ;;
            "--help" | "-h")
                show_history_help
                exit 0
                ;;
            -*)
                echo "Opção desconhecida para mo history: $1" >&2
                echo "Execute 'mo history --help' para ver o uso." >&2
                exit 1
                ;;
            *)
                echo "Argumento inesperado para mo history: $1" >&2
                echo "Execute 'mo history --help' para ver o uso." >&2
                exit 1
                ;;
        esac
        shift
    done

    history_load_operations "$(history_operations_log_file)"
    history_load_deletions "$(history_deletions_log_file)"

    if [[ "$HISTORY_JSON" == "true" ]]; then
        history_render_json "$HISTORY_LIMIT"
    else
        history_render_text "$HISTORY_LIMIT"
    fi
}

main "$@"
