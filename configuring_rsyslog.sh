#!/bin/bash

# Script para configurar ou remover o encaminhamento de logs do RSyslog
# para um servidor SIEM remoto, usando um arquivo de configuração dedicado
# com delimitadores para melhor legibilidade e porta obrigatória.
# Uso:
#   Adicionar: sudo ./configure_rsyslog.sh --port PORTA [--tcp] <ENDEREÇO_IP_DO_SIEM>
#   Remover:   sudo ./configure_rsyslog.sh --remove --port PORTA <ENDEREÇO_IP_DO_SIEM>
#
# Opções:
#   --tcp    : Usa o protocolo TCP para encaminhamento ao adicionar (UDP é o padrão).
#   --port   : Especifica a porta de destino (OBRIGATÓRIO).
#   --remove : Remove o bloco de encaminhamento SIEM (incluindo delimitadores)
#              do arquivo dedicado para o IP e porta especificados.

# --- Variáveis Padrão ---
PROTOCOL_PREFIX="@" # Prefixo para UDP (padrão)
LOG_SERVER_IP=""
LOG_SERVER_PORT="" # Porta agora é obrigatória, sem valor padrão
PROTOCOL_NAME="UDP"
ACTION="ADD" # Ação padrão é adicionar
NEEDS_RESTART=false # Flag para indicar se o serviço precisa ser reiniciado

# --- Logs Recomendados para SIEM ---
SIEM_LOG_SELECTORS=(
    "authpriv.*"
    "kern.*"
    "cron.*"
    "*.err;*.crit;*.alert;*.emerg"
    "*.info;mail.none;authpriv.none;cron.none"
)

# --- Processamento de Argumentos ---
# Usar um loop while para processar argumentos
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --tcp)
        PROTOCOL_PREFIX="@@"
        PROTOCOL_NAME="TCP"
        shift # Remove --tcp
        ;;
        --remove)
        ACTION="REMOVE"
        shift # Remove --remove
        ;;
        --port)
        if [[ -z "$2" || "$2" == --* ]]; then
            echo "Erro: Argumento --port requer um número de porta." >&2
            exit 1
        fi
        LOG_SERVER_PORT="$2"
        # Validação básica da porta
        if ! [[ "$LOG_SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$LOG_SERVER_PORT" -lt 1 ] || [ "$LOG_SERVER_PORT" -gt 65535 ]; then
            echo "Erro: Porta inválida '$LOG_SERVER_PORT'. Deve ser um número entre 1 e 65535." >&2
            exit 1
        fi
        shift # Remove --port
        shift # Remove o valor da porta
        ;;
        *)
        # Assume que o argumento restante é o IP
        LOG_SERVER_IP="$1"
        shift # Remove o IP
        ;;
    esac
done

# --- Validação Inicial ---
# Verifica se o IP foi fornecido
if [ -z "$LOG_SERVER_IP" ]; then
  echo "Erro: Nenhum endereço IP do SIEM fornecido."
  echo "Uso para Adicionar: $0 --port PORTA [--tcp] <ENDEREÇO_IP_DO_SIEM>"
  echo "Uso para Remover:   $0 --remove --port PORTA <ENDEREÇO_IP_DO_SIEM>"
  exit 1
fi
# Verifica se a porta foi fornecida (agora obrigatória)
if [ -z "$LOG_SERVER_PORT" ]; then
  echo "Erro: O parâmetro --port PORTA é obrigatório."
  echo "Uso para Adicionar: $0 --port PORTA [--tcp] <ENDEREÇO_IP_DO_SIEM>"
  echo "Uso para Remover:   $0 --remove --port PORTA <ENDEREÇO_IP_DO_SIEM>"
  exit 1
fi
# Validação simples de IP
if ! [[ "$LOG_SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Erro: Endereço IP '$LOG_SERVER_IP' parece inválido."
    exit 1
fi

# Verifica se é root
if [ "$(id -u)" -ne 0 ]; then
  echo "Erro: Este script precisa ser executado como root (use sudo)." >&2
  exit 1
fi

# --- Variáveis de Configuração ---
# LOG_SERVER_PORT já foi definido e validado no processamento de argumentos
CONFIG_DIR="/etc/rsyslog.d"
CONFIG_FILENAME="60-siem.conf"
CONFIG_FILE="${CONFIG_DIR}/${CONFIG_FILENAME}"
BACKUP_FILE="${CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE"' EXIT # Garante limpeza do arquivo temporário

# Delimitadores - Incluem a porta para unicidade
BEGIN_DELIMITER="# BEGIN SIEM CONFIG FOR ${LOG_SERVER_IP}:${LOG_SERVER_PORT}"
END_DELIMITER="# END SIEM CONFIG FOR ${LOG_SERVER_IP}:${LOG_SERVER_PORT}"

# --- Função para Remover Bloco Existente (usada antes de Adicionar) ---
remove_existing_block() {
    local ip_to_remove=$1
    local port_to_remove=$2
    local begin_marker="# BEGIN SIEM CONFIG FOR ${ip_to_remove}:${port_to_remove}"
    local end_marker="# END SIEM CONFIG FOR ${ip_to_remove}:${port_to_remove}"

    if [ ! -f "$CONFIG_FILE" ]; then return 0; fi

    if grep -q -F "$begin_marker" "$CONFIG_FILE"; then
        echo "Removendo bloco de configuração existente para ${ip_to_remove}:${port_to_remove} antes de adicionar/atualizar..."
        sed -i.bak_sed_remove "/^${begin_marker}$/,/^${end_marker}$/d" "$CONFIG_FILE"
        if [ $? -ne 0 ]; then
            echo "Erro: Falha ao remover bloco existente com sed." >&2
            if [ -f "${CONFIG_FILE}.bak_sed_remove" ]; then mv "${CONFIG_FILE}.bak_sed_remove" "$CONFIG_FILE"; fi
            return 1 # Falha
        fi
        rm -f "${CONFIG_FILE}.bak_sed_remove"
        echo "Bloco existente removido."
        sed -i '/^$/N;/^\n$/D' "$CONFIG_FILE" # Limpa linhas em branco
        return 0 # Sucesso
    fi
    return 0 # Bloco não existia
}

# --- Lógica Principal ---

# --- Ação: Adicionar Configuração ---
if [ "$ACTION" == "ADD" ]; then
    echo "Ação: Adicionar/Atualizar encaminhamento SIEM para ${LOG_SERVER_IP}:${LOG_SERVER_PORT} via ${PROTOCOL_NAME} em '$CONFIG_FILE'..."

    if [ ! -d "$CONFIG_DIR" ]; then echo "Erro: Diretório de configuração '$CONFIG_DIR' não encontrado." >&2; exit 1; fi

    # Cria ou verifica o arquivo de configuração
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Arquivo '$CONFIG_FILE' não encontrado. Criando..."
        touch "$CONFIG_FILE" || { echo "Erro: Falha ao criar o arquivo '$CONFIG_FILE'." >&2; exit 1; }
        chown root:root "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
        echo "Arquivo '$CONFIG_FILE' criado com sucesso."
    else
        echo "Arquivo de configuração '$CONFIG_FILE' encontrado."
        echo "Criando backup de '$CONFIG_FILE' para '$BACKUP_FILE'..."
        cp -p "$CONFIG_FILE" "$BACKUP_FILE" || { echo "Erro: Falha ao criar o arquivo de backup '$BACKUP_FILE'." >&2; exit 1; }
        echo "Backup criado com sucesso em '$BACKUP_FILE'."
    fi

    # Remove qualquer bloco existente para este IP E PORTA
    if ! remove_existing_block "$LOG_SERVER_IP" "$LOG_SERVER_PORT"; then
        echo "Falha ao preparar o arquivo para adição. Restaurando backup (se existir)..."
        if [ -f "$BACKUP_FILE" ]; then cp -p "$BACKUP_FILE" "$CONFIG_FILE"; fi
        exit 1
    fi

    # Adiciona o novo bloco de configuração
    echo "Adicionando novo bloco de configuração SIEM para ${LOG_SERVER_IP}:${LOG_SERVER_PORT}..."
    {
        if [ -s "$CONFIG_FILE" ]; then echo; fi
        echo "$BEGIN_DELIMITER"
        for selector in "${SIEM_LOG_SELECTORS[@]}"; do
            echo "${selector} ${PROTOCOL_PREFIX}${LOG_SERVER_IP}:${LOG_SERVER_PORT}"
        done
        echo "$END_DELIMITER"
        echo
    } >> "$CONFIG_FILE"

    if [ $? -eq 0 ]; then
        echo "Bloco de configuração SIEM adicionado/atualizado com sucesso em '$CONFIG_FILE'."
        NEEDS_RESTART=true
    else
        echo "Erro ao adicionar o bloco de configuração em '$CONFIG_FILE'." >&2
        echo "Tentando restaurar o arquivo original a partir do backup '$BACKUP_FILE' (se existir)..."
        if [ -f "$BACKUP_FILE" ]; then cp -p "$BACKUP_FILE" "$CONFIG_FILE"; fi
        exit 1
    fi

# --- Ação: Remover Configuração ---
elif [ "$ACTION" == "REMOVE" ]; then
    echo "Ação: Remover bloco de encaminhamento SIEM para ${LOG_SERVER_IP}:${LOG_SERVER_PORT} de '$CONFIG_FILE'..."

    if [ ! -f "$CONFIG_FILE" ]; then echo "Informação: Arquivo de configuração '$CONFIG_FILE' não encontrado. Nada a remover."; exit 0; fi
    echo "Arquivo de configuração '$CONFIG_FILE' encontrado."

    if ! grep -q -F "$BEGIN_DELIMITER" "$CONFIG_FILE"; then
         echo "Informação: Bloco de configuração SIEM para ${LOG_SERVER_IP}:${LOG_SERVER_PORT} não encontrado em '$CONFIG_FILE'."
         exit 0
    fi

    echo "Criando backup de '$CONFIG_FILE' para '$BACKUP_FILE'..."
    cp -p "$CONFIG_FILE" "$BACKUP_FILE" || { echo "Erro: Falha ao criar o arquivo de backup '$BACKUP_FILE'." >&2; exit 1; }
    echo "Backup criado com sucesso em '$BACKUP_FILE'."

    echo "Removendo bloco SIEM correspondente de '$CONFIG_FILE'..."
    sed -i "/^${BEGIN_DELIMITER}$/,/^${END_DELIMITER}$/d" "$CONFIG_FILE"
    sed_exit_code=$?

    if [ $sed_exit_code -ne 0 ]; then
        echo "Erro: Falha ao remover o bloco SIEM com sed (exit code: $sed_exit_code)." >&2
        echo "Tentando restaurar o arquivo original a partir do backup '$BACKUP_FILE'..."
        cp -p "$BACKUP_FILE" "$CONFIG_FILE" || { echo "Erro crítico ao restaurar backup."; }
        exit 1
    fi

    # Remove linhas em branco extras
    sed -i '/^$/N;/^\n$/D' "$CONFIG_FILE"
    sed -i '1{/^$/d}' "$CONFIG_FILE"
    sed -i '${/^$/d}' "$CONFIG_FILE"

    echo "Bloco de encaminhamento SIEM removido com sucesso de '$CONFIG_FILE'."
    NEEDS_RESTART=true

    # Opcional: Remover o arquivo se estiver vazio
    if [ ! -s "$CONFIG_FILE" ]; then
       echo "Arquivo '$CONFIG_FILE' está vazio após a remoção. Removendo o arquivo..."
       rm -f "$CONFIG_FILE" || echo "Aviso: Falha ao remover o arquivo vazio '$CONFIG_FILE'."
       echo "Arquivo vazio '$CONFIG_FILE' removido."
    fi
fi

# --- Reiniciar Serviço (se necessário) ---
if [ "$NEEDS_RESTART" = true ]; then
    echo "Reiniciando o serviço rsyslog para aplicar as alterações..."
    RESTART_CMD=""
    if command -v systemctl &> /dev/null; then RESTART_CMD="systemctl restart rsyslog";
    elif command -v service &> /dev/null; then RESTART_CMD="service rsyslog restart"; fi

    if [ -n "$RESTART_CMD" ]; then
        $RESTART_CMD
        if [ $? -ne 0 ]; then echo "Aviso: Falha ao reiniciar o rsyslog via '$RESTART_CMD'. Verifique o status do serviço manualmente." >&2;
        else echo "Serviço rsyslog reiniciado com sucesso."; fi
    else echo "Aviso: Não foi possível encontrar 'systemctl' ou 'service'. Reinicie o serviço rsyslog manualmente." >&2; fi
else
    echo "Nenhuma alteração realizada que necessite reiniciar o serviço rsyslog."
fi

# --- Conclusão ---
echo "-----------------------------------------------------"
if [ "$ACTION" == "ADD" ]; then
    echo "Configuração de encaminhamento SIEM para ${LOG_SERVER_IP}:${LOG_SERVER_PORT} em '$CONFIG_FILE' concluída!"
elif [ "$ACTION" == "REMOVE" ]; then
    echo "Remoção de encaminhamento SIEM para ${LOG_SERVER_IP}:${LOG_SERVER_PORT} de '$CONFIG_FILE' concluída!"
fi
if [ -f "$BACKUP_FILE" ]; then echo "Backup da configuração anterior salvo em: ${BACKUP_FILE}"; fi
echo "-----------------------------------------------------"

exit 0
