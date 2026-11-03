#!/bin/bash

show_clean_help() {
    echo "Uso: mo clean [OPÇÕES]"
    echo ""
    echo "Libera espaço em disco removendo caches, logs, arquivos temporários e restos de apps já desinstalados."
    echo ""
    echo "Opções:"
    echo "  --dry-run, -n     Simula a limpeza, sem alterar nada"
    echo "  --external PATH   Limpa metadados do sistema em um volume externo montado"
    echo "  --whitelist       Gerencia os caminhos protegidos"
    echo "  --debug           Mostra logs detalhados das operações"
    echo "  -h, --help        Mostra esta ajuda"
}

show_installer_help() {
    echo "Uso: mo installer [OPÇÕES]"
    echo ""
    echo "Encontra e remove arquivos de instalação (.dmg, .pkg, .iso, .xip, .zip)."
    echo ""
    echo "Opções:"
    echo "  --dry-run         Simula a limpeza de instaladores, sem alterar nada"
    echo "  --debug           Mostra logs detalhados das operações"
    echo "  -h, --help        Mostra esta ajuda"
}

show_optimize_help() {
    echo "Uso: mo optimize [OPÇÕES]"
    echo ""
    echo "Renova caches e serviços do sistema e corrige problemas de manutenção seguros."
    echo ""
    echo "Opções:"
    echo "  --dry-run, -n     Simula a otimização, sem alterar nada"
    echo "  --whitelist       Gerencia os itens protegidos"
    echo "  --debug           Mostra logs detalhados das operações"
    echo "  -h, --help        Mostra esta ajuda"
}

show_touchid_help() {
    echo "Uso: mo touchid [COMANDO]"
    echo ""
    echo "Configura o Touch ID para a autenticação do sudo."
    echo ""
    echo "Comandos:"
    echo "  enable            Ativa o Touch ID para o sudo"
    echo "  disable           Desativa o Touch ID para o sudo"
    echo "  status            Mostra o estado atual do Touch ID"
    echo ""
    echo "Opções:"
    echo "  --dry-run         Simula as mudanças do Touch ID, sem alterar a configuração do sudo"
    echo "  -h, --help        Mostra esta ajuda"
    echo ""
    echo "Sem nenhum comando, um menu interativo é exibido."
}

show_uninstall_help() {
    echo "Uso: mo uninstall [OPÇÕES] [NOME_DO_APP ...]"
    echo ""
    echo "Remove aplicativos e seus arquivos restantes de forma interativa."
    echo "Opcionalmente, informe um ou mais nomes de apps para desinstalar direto."
    echo "Para restos de apps que já foram removidos, use mo clean."
    echo ""
    echo "Exemplos:"
    echo "  mo uninstall                   Abre o seletor interativo de apps"
    echo "  mo uninstall slack             Desinstala o Slack"
    echo "  mo uninstall slack zoom        Desinstala o Slack e o Zoom"
    echo "  mo uninstall --dry-run slack   Simula a desinstalação do Slack"
    echo "  mo uninstall --with-data slack Desinstala o Slack com seus dados já selecionados"
    echo "  mo uninstall --list            Lista os apps instalados e os nomes que mo uninstall aceita"
    echo ""
    echo "Opções:"
    echo "  --list            Lista os apps instalados com o nome exato que mo uninstall aceita"
    echo "  --dry-run         Simula a desinstalação do app, sem alterar nada"
    echo "  --permanent       Ignora a Lixeira do macOS e remove na hora (rm -rf)"
    echo "  --with-data       Começa com os dados pessoais selecionados; pressione D para manter algum"
    echo "  --whitelist       Não suportado na desinstalação (use clean/optimize)"
    echo "  --debug           Mostra logs detalhados das operações"
    echo "  -h, --help        Mostra esta ajuda"
    echo ""
    echo "Por padrão, os arquivos desinstalados vão para a Lixeira do macOS e podem"
    echo "ser recuperados. Use --permanent para pular a etapa da Lixeira."
}
