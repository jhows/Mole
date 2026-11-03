#!/bin/bash
# Canonical optimization task metadata and handler ownership.

set -euo pipefail

if [[ -n "${MOLE_OPTIMIZE_CATALOG_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_OPTIMIZE_CATALOG_LOADED=1

# The catalog uses aligned arrays instead of serialized records. This keeps
# field boundaries explicit on Bash 3.2 and lets each consumer read only the
# projection it owns. Every registered task is safe for automatic execution.
MOLE_OPTIMIZE_ACTIONS=()
MOLE_OPTIMIZE_HANDLERS=()
MOLE_OPTIMIZE_HEALTH_NAMES=()
MOLE_OPTIMIZE_WHITELIST_NAMES=()
MOLE_OPTIMIZE_DESCRIPTIONS=()
MOLE_OPTIMIZE_SAFE_VALUES=()

_optimize_catalog_register() {
    local index=${#MOLE_OPTIMIZE_ACTIONS[@]}
    MOLE_OPTIMIZE_ACTIONS[index]="$1"
    MOLE_OPTIMIZE_HANDLERS[index]="$2"
    MOLE_OPTIMIZE_HEALTH_NAMES[index]="$3"
    MOLE_OPTIMIZE_WHITELIST_NAMES[index]="$4"
    MOLE_OPTIMIZE_DESCRIPTIONS[index]="$5"
    MOLE_OPTIMIZE_SAFE_VALUES[index]="$6"
}

_optimize_catalog_register cache_refresh opt_cache_refresh \
    "Renovação do cache do Finder" "Renovação do cache do Finder" \
    "Renova as miniaturas do QuickLook e o cache dos serviços de ícones" true
_optimize_catalog_register saved_state_cleanup opt_saved_state_cleanup \
    "Limpeza de estados de apps" "Limpeza de estados de apps" \
    "Remove estados salvos antigos de aplicativos (mais de 30 dias)" true
_optimize_catalog_register fix_broken_configs opt_fix_broken_configs \
    "Reparo de configurações quebradas" "Reparo de configurações quebradas" \
    "Corrige arquivos de preferências corrompidos" true
_optimize_catalog_register network_optimization opt_network_optimization \
    "Renovação do cache de rede" "Renovação do cache de rede" \
    "Renova o cache de DNS" true
_optimize_catalog_register sqlite_vacuum opt_sqlite_vacuum \
    "Otimização de bancos de dados" "Otimização de bancos de dados" \
    "Compacta os bancos SQLite do Mail, Safari e Mensagens (ignora se os apps estiverem abertos)" true
_optimize_catalog_register prevent_network_dsstore opt_prevent_network_dsstore \
    "Evitar .DS_Store do Finder" "Evitar .DS_Store do Finder" \
    "Define uma preferência permanente do Finder para parar de gravar .DS_Store em volumes SMB/AFP/NFS e USB" true
_optimize_catalog_register legacy_overrides_audit opt_legacy_overrides_audit \
    "Ajustes legados" "Ajustes legados" \
    "Remove ajustes ocultos de App Nap e de verificação de imagens de disco deixados por ferramentas antigas" true
_optimize_catalog_register network_stack_optimize opt_network_stack_optimize \
    "Renovação da pilha de rede" "Renovação da pilha de rede" \
    "Limpa a tabela de rotas e o cache ARP para resolver problemas de rede" true
_optimize_catalog_register disk_permissions_repair opt_disk_permissions_repair \
    "Reparo de permissões" "Reparo de permissões" \
    "Corrige problemas de permissão no diretório do usuário" true
_optimize_catalog_register spotlight_index_optimize opt_spotlight_index_optimize \
    "Otimização do Spotlight" "Otimização do Spotlight" \
    "Reconstrói o índice se a busca estiver lenta (detecção inteligente)" true
_optimize_catalog_register spotlight_orphan_rules_cleanup opt_prune_spotlight_orphan_rules \
    "Regras órfãs do Spotlight" "Regras órfãs do Spotlight" \
    "Remove regras de busca do Spotlight de apps que não estão mais instalados" true
_optimize_catalog_register periodic_maintenance opt_periodic_maintenance \
    "Manutenção periódica" "Manutenção periódica" \
    "Executa os scripts diários/semanais/mensais de manutenção do macOS se estiverem atrasados" true
_optimize_catalog_register shared_file_list_repair opt_shared_file_list_repair \
    "Listas de arquivos compartilhados" "Listas de arquivos compartilhados" \
    "Repara favoritos do Finder e documentos recentes corrompidos" true
_optimize_catalog_register disk_verify opt_disk_verify \
    "Saúde do disco" "Saúde do disco" \
    "Verifica a integridade do sistema de arquivos" true
_optimize_catalog_register login_items_audit opt_login_items_audit \
    "Itens de login" "Auditoria de itens de login" \
    "Audita os itens de login em busca de entradas quebradas" true
_optimize_catalog_register quarantine_cleanup opt_quarantine_cleanup \
    "Limpeza do banco de quarentena" "Limpeza do banco de quarentena" \
    "Limpa o histórico de rastreamento de downloads do Gatekeeper" true
_optimize_catalog_register launch_agents_cleanup opt_launch_agents_cleanup \
    "Limpeza de Launch Agents" "Limpeza de Launch Agents" \
    "Informa LaunchAgents cujos binários não existem mais" true
_optimize_catalog_register notification_cleanup opt_notification_cleanup \
    "Notificações" "Notificações" \
    "Limpa notificações antigas já entregues para reduzir o tamanho do banco" true
_optimize_catalog_register coreduet_cleanup opt_coreduet_cleanup \
    "Dados de uso" "Dados de uso" \
    "Limpa dados antigos de rastreamento de uso" true

optimize_catalog_index_for() {
    local requested_action="$1"
    local index
    for ((index = 0; index < ${#MOLE_OPTIMIZE_ACTIONS[@]}; index++)); do
        if [[ "${MOLE_OPTIMIZE_ACTIONS[$index]}" == "$requested_action" ]]; then
            printf '%s\n' "$index"
            return 0
        fi
    done
    return 1
}

optimize_catalog_handler_for() {
    local index
    index=$(optimize_catalog_index_for "$1") || return 1
    printf '%s\n' "${MOLE_OPTIMIZE_HANDLERS[$index]}"
}

optimize_catalog_health_name_for() {
    local index
    index=$(optimize_catalog_index_for "$1") || return 1
    printf '%s\n' "${MOLE_OPTIMIZE_HEALTH_NAMES[$index]}"
}

optimize_catalog_validate() {
    local count=${#MOLE_OPTIMIZE_ACTIONS[@]}
    if [[ $count -eq 0 ]]; then
        echo "O catálogo de tarefas de otimização está vazio" >&2
        return 1
    fi
    if [[ ${#MOLE_OPTIMIZE_HANDLERS[@]} -ne $count ||
        ${#MOLE_OPTIMIZE_HEALTH_NAMES[@]} -ne $count ||
        ${#MOLE_OPTIMIZE_WHITELIST_NAMES[@]} -ne $count ||
        ${#MOLE_OPTIMIZE_DESCRIPTIONS[@]} -ne $count ||
        ${#MOLE_OPTIMIZE_SAFE_VALUES[@]} -ne $count ]]; then
        echo "Os campos do catálogo de tarefas de otimização estão desalinhados" >&2
        return 1
    fi

    local seen_actions="|"
    local seen_handlers="|"
    local index action handler
    for ((index = 0; index < count; index++)); do
        action=${MOLE_OPTIMIZE_ACTIONS[$index]}
        handler=${MOLE_OPTIMIZE_HANDLERS[$index]}
        if [[ ! "$action" =~ ^[a-z0-9_]+$ || ! "$handler" =~ ^opt_[a-z0-9_]+$ ]]; then
            echo "Identidade de tarefa de otimização inválida: $action|$handler" >&2
            return 1
        fi
        if [[ -z "${MOLE_OPTIMIZE_HEALTH_NAMES[$index]}" ||
            -z "${MOLE_OPTIMIZE_WHITELIST_NAMES[$index]}" ||
            -z "${MOLE_OPTIMIZE_DESCRIPTIONS[$index]}" ]]; then
            echo "Os metadados da tarefa de otimização estão incompletos: $action" >&2
            return 1
        fi
        if [[ "${MOLE_OPTIMIZE_SAFE_VALUES[$index]}" != "true" ]]; then
            echo "A tarefa de otimização não é segura para execução automática: $action" >&2
            return 1
        fi
        if [[ "$seen_actions" == *"|$action|"* ]]; then
            echo "Ação de tarefa de otimização duplicada: $action" >&2
            return 1
        fi
        if [[ "$seen_handlers" == *"|$handler|"* ]]; then
            echo "Handler de tarefa de otimização duplicado: $handler" >&2
            return 1
        fi
        seen_actions+="$action|"
        seen_handlers+="$handler|"
    done
}

optimize_catalog_validate
readonly -a MOLE_OPTIMIZE_ACTIONS
readonly -a MOLE_OPTIMIZE_HANDLERS
readonly -a MOLE_OPTIMIZE_HEALTH_NAMES
readonly -a MOLE_OPTIMIZE_WHITELIST_NAMES
readonly -a MOLE_OPTIMIZE_DESCRIPTIONS
readonly -a MOLE_OPTIMIZE_SAFE_VALUES
unset -f _optimize_catalog_register
