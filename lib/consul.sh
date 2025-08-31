#!/usr/bin/env bash
# ==============================================================================
# Funções para instalação e configuração do Consul
# ==============================================================================

# Importa funções comuns
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Função para instalar o binário oficial do Consul
install_consul_binary() {
  local CONSUL_VERSION="1.17.0"
  local CONSUL_URL="https://releases.hashicorp.com/consul/${CONSUL_VERSION}/consul_${CONSUL_VERSION}_linux_amd64.zip"
  local TEMP_DIR="/tmp/consul_install"
  
  log_info "Baixando Consul ${CONSUL_VERSION}..."
  
  # Cria diretório temporário
  mkdir -p "$TEMP_DIR"
  cd "$TEMP_DIR"
  
  # Baixa o Consul
  if ! wget -q "$CONSUL_URL" -O consul.zip; then
    log_error "Falha ao baixar Consul de $CONSUL_URL"
    return 1
  fi
  
  # Instala unzip se necessário
  if ! command -v unzip >/dev/null 2>&1; then
    log_info "Instalando unzip..."
    apt-get update -qq
    apt-get install -yq unzip
  fi
  
  # Extrai o binário
  if ! unzip -q consul.zip; then
    log_error "Falha ao extrair consul.zip"
    return 1
  fi
  
  # Move para /usr/bin
  if ! mv consul /usr/bin/consul; then
    log_error "Falha ao mover consul para /usr/bin"
    return 1
  fi
  
  # Define permissões
  chmod +x /usr/bin/consul
  
  # Limpa arquivos temporários
  cd /
  rm -rf "$TEMP_DIR"
  
  # Verifica instalação
  if consul version >/dev/null 2>&1; then
    log_info "Consul instalado com sucesso: $(consul version | head -n1)"
  else
    log_error "Falha na verificação da instalação do Consul"
    return 1
  fi
  
  return 0
}

# Função para instalar e configurar o Consul
setup_consul() {
  local CONSUL_USER="$1"
  local CONSUL_GROUP="$2"
  local CONSUL_DATA_DIR="$3"
  local CONSUL_HCL="$4"
  local CONSUL_JOIN="$5"
  local CONSUL_SERVERS="$6"
  local CONSUL_BOOTSTRAP_EXPECT="$7"
  local CONSUL_ENCRYPT_KEY="$8"
  local CONSUL_ADVERTISE_ADDR="$9"
  local DC="${10}"
  local NODE_NAME="${11}"

  log_info "Instalando Consul..."
  install_consul_binary

  # Cria usuário/grupo se não existir
  if ! getent group "${CONSUL_GROUP}" >/dev/null 2>&1; then
    log_info "Criando grupo ${CONSUL_GROUP}..."
    addgroup --system "${CONSUL_GROUP}" || log_warn "Falha ao criar grupo ${CONSUL_GROUP}"
  fi
  if ! id -u "${CONSUL_USER}" >/dev/null 2>&1; then
    log_info "Criando usuário ${CONSUL_USER}..."
    adduser --system --no-create-home --shell /usr/sbin/nologin --ingroup "${CONSUL_GROUP}" "${CONSUL_USER}" || log_warn "Falha ao criar usuário ${CONSUL_USER}"
  fi

  # Dirs e permissões mínimas
  install -d -m 0750 -o "${CONSUL_USER}" -g "${CONSUL_GROUP}" /etc/consul.d
  install -d -m 0750 -o "${CONSUL_USER}" -g "${CONSUL_GROUP}" "${CONSUL_DATA_DIR}"

  # Monta retry_join se informado
  local RJ="[]"
  if [[ "${CONSUL_JOIN,,}" == "s" && -n "${CONSUL_SERVERS// }" ]]; then
    RJ=$(montar_retry_join "$CONSUL_SERVERS")
  fi

  # Configuração completa para Consul (baseada nas melhores práticas)
  cat >"${CONSUL_HCL}" <<HCL
datacenter          = "${DC}"
node_name           = "${NODE_NAME}"
server              = true
bootstrap_expect    = ${CONSUL_BOOTSTRAP_EXPECT}

bind_addr           = "0.0.0.0"
client_addr         = "0.0.0.0"        # Permite acesso externo (ajuste conforme necessário)
advertise_addr      = "${CONSUL_ADVERTISE_ADDR}"      # IP PRIVADO deste nó

ui_config { enabled = false }      # UI disponível

retry_join = ${RJ}
data_dir  = "${CONSUL_DATA_DIR}"

encrypt = "${CONSUL_ENCRYPT_KEY}"
HCL
  chown "${CONSUL_USER}":"${CONSUL_GROUP}" "${CONSUL_HCL}"
  chmod 0600 "${CONSUL_HCL}"  # Mais seguro para arquivos com chaves

  # systemd
  cat >/etc/systemd/system/consul.service <<UNIT
[Unit]
Description=HashiCorp Consul Agent
Wants=network-online.target
After=network-online.target

[Service]
User=${CONSUL_USER}
Group=${CONSUL_GROUP}
ExecStart=/usr/bin/consul agent -config-dir=/etc/consul.d
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
KillSignal=SIGINT
LimitNOFILE=65536
LimitNPROC=infinity
TasksMax=infinity
Restart=on-failure
RestartSec=2
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable consul
  systemctl restart consul
  
  log_info "Consul instalado e configurado com sucesso!"
}

# Função para gerar uma chave de criptografia para o Consul
generate_consul_key() {
  # Tenta usar consul se já estiver disponível
  local key=$(consul keygen 2>/dev/null || echo "")
  
  if [[ -z "$key" ]]; then
    # Gera chave usando openssl como alternativa
    key=$(openssl rand -base64 32 2>/dev/null || echo "")
    
    if [[ -z "$key" ]]; then
      # Fallback para /dev/urandom
      key=$(head -c 32 /dev/urandom | base64 -w 0 2>/dev/null || echo "")
    fi
    
    if [[ -z "$key" ]]; then
      key="GENERATE_AFTER_INSTALL"
    fi
  fi
  
  # Retorna apenas a chave, sem logs
  printf "%s" "$key"
}

# Função para gerar chave com logs
generate_consul_key_with_logs() {
  log_info "Gerando nova chave de criptografia para Consul..." >&2
  
  local key=$(generate_consul_key)
  
  if [[ "$key" == "GENERATE_AFTER_INSTALL" ]]; then
    log_warn "Não foi possível gerar chave automaticamente. Use 'consul keygen' após a instalação." >&2
  else
    log_info "Chave gerada: $key" >&2
    log_warn "IMPORTANTE: Guarde esta chave para usar em outros nós do cluster!" >&2
  fi
  
  printf "%s" "$key"
}

# Função para validar a configuração do Consul
validate_consul_config() {
  local CONSUL_HCL="$1"
  local CONSUL_JOIN="$2"
  local CONSUL_SERVERS="$3"
  local CONSUL_BOOTSTRAP_EXPECT="$4"
  local CONSUL_ENCRYPT_KEY="$5"
  local errors=0
  
  # Verifica se o arquivo de configuração existe
  if [[ ! -f "$CONSUL_HCL" ]]; then
    log_warn "Arquivo de configuração do Consul não encontrado: $CONSUL_HCL"
    ((errors++))
    return $errors
  fi
  
  # Verifica se bootstrap_expect é consistente com o número de servidores em retry_join
  if [[ "${CONSUL_JOIN,,}" == "s" && -n "${CONSUL_SERVERS// }" ]]; then
    local num_servers=$(echo "$CONSUL_SERVERS" | tr ',' '\n' | wc -l)
    if [[ $CONSUL_BOOTSTRAP_EXPECT -gt $num_servers ]]; then
      log_warn "bootstrap_expect ($CONSUL_BOOTSTRAP_EXPECT) é maior que o número de servidores em retry_join ($num_servers)"
      log_warn "Isso pode impedir que o cluster forme quorum. Considere ajustar."
      ((errors++))
    fi
  fi
  
  # Verifica se a chave encrypt está definida
  if [[ -z "${CONSUL_ENCRYPT_KEY// }" ]]; then
    log_warn "Chave de criptografia não definida. A comunicação entre agentes não será criptografada."
    ((errors++))
  fi
  
  return $errors
}