#!/bin/bash
# Purge paths management functionality
# Opens config file for editing and shows current status

set -euo pipefail

# Get script directory and source dependencies
_MOLE_MANAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_MOLE_MANAGE_DIR/../core/common.sh"
# Only source project.sh if not already loaded (has readonly vars)
if [[ -z "${PURGE_TARGETS:-}" ]]; then
    source "$_MOLE_MANAGE_DIR/../clean/project.sh"
fi

# Config file path (prefer the shared project constant when available)
PURGE_PATHS_CONFIG="${PURGE_PATHS_CONFIG:-${PURGE_CONFIG_FILE:-$HOME/.config/mole/purge_paths}}"

# Ensure config file exists with helpful template
ensure_config_template() {
    if [[ ! -f "$PURGE_PATHS_CONFIG" ]]; then
        if ! write_purge_config "# Mole Purge Paths - Directories to scan for project artifacts
# Add one path per line (supports ~ for home directory)
# Delete all paths or this file to use defaults
#
# Example:
# ~/Documents/MyProjects
# ~/Work/ClientA
# ~/Work/ClientB
"; then
            echo -e "${YELLOW}${ICON_WARNING}${NC} Não foi possível inicializar ${PURGE_PATHS_CONFIG/#$HOME/~}" >&2
        fi
    fi
}

# Main management function
manage_purge_paths() {
    ensure_config_template

    local display_config="${PURGE_PATHS_CONFIG/#$HOME/~}"

    # Clear screen
    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi

    echo -e "${PURPLE_BOLD}Configuração dos caminhos de purga${NC}"
    echo ""

    # Show current status
    echo -e "${YELLOW}Caminhos de análise atuais:${NC}"

    # Reload config
    load_purge_config

    if [[ ${#PURGE_SEARCH_PATHS[@]} -gt 0 ]]; then
        for path in "${PURGE_SEARCH_PATHS[@]}"; do
            local display_path="${path/#$HOME/~}"
            if [[ -d "$path" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $display_path"
            else
                echo -e "  ${GRAY}${ICON_EMPTY}${NC} $display_path${GRAY}, não encontrado${NC}"
            fi
        done
    fi

    # Check if using custom config
    local custom_count=0
    if [[ -f "$PURGE_PATHS_CONFIG" ]]; then
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" || "$line" =~ ^# ]] && continue
            custom_count=$((custom_count + 1))
        done < "$PURGE_PATHS_CONFIG"
    fi

    echo ""
    if [[ $custom_count -gt 0 ]]; then
        echo -e "${GRAY}Usando configuração personalizada com $custom_count caminhos${NC}"
    else
        echo -e "${GRAY}Usando ${#DEFAULT_PURGE_SEARCH_PATHS[@]} caminhos padrão${NC}"
    fi

    echo ""
    echo -e "${YELLOW}Caminhos padrão:${NC}"
    for path in "${DEFAULT_PURGE_SEARCH_PATHS[@]}"; do
        echo -e "  ${GRAY}-${NC} ${path/#$HOME/~}"
    done

    echo ""
    echo -e "${YELLOW}Arquivo de configuração:${NC} $display_config"
    echo ""

    # Open in editor
    local editor="${EDITOR:-${VISUAL:-vim}}"
    echo -e "Abrindo no ${CYAN}$editor${NC}..."
    echo -e "${GRAY}Salve e saia para aplicar as mudanças. Deixe vazio para usar os padrões.${NC}"
    echo ""

    # Wait for user to read
    sleep 1

    # Open editor
    "$editor" "$PURGE_PATHS_CONFIG"

    # Reload and show updated status
    load_purge_config

    echo ""
    echo -e "${GREEN}${ICON_SUCCESS}${NC} Configuração atualizada"
    echo -e "${GRAY}Execute 'mo purge' para limpar com os novos caminhos${NC}"
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    manage_purge_paths
fi
