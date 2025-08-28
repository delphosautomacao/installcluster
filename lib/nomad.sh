#!/usr/bin/env bash
# ==============================================================================
# Funções para instalação e configuração do Nomad
# ==============================================================================

# Importa funções comuns
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Função para instalar o binário oficial do Nomad
install_nomad_binary() {
  local NOMAD_VERSION="1.7.2"
  local NOMAD_URL="https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip"
  local TEMP_DIR="/tmp/nomad_install"
  
  log_info "Baixando Nomad ${NOMAD_VERSION}..."
  
  # Cria diretório temporário
  mkdir -p "$TEMP_DIR"
  cd "$TEMP_DIR"
  
  # Baixa o Nomad
  if ! wget -q "$NOMAD_URL" -O nomad.zip; then
    log_error "Falha ao baixar Nomad de $NOMAD_URL"
    return 1
  fi
  
  # Instala unzip se necessário
  if ! command -v unzip >/dev/null 2>&1; then
    log_info "Instalando unzip..."
    apt-get update -qq
    apt-get install -yq unzip
  fi
  
  # Extrai o binário
  if ! unzip -q nomad.zip; then
    log_error "Falha ao extrair nomad.zip"
    return 1
  fi
  
  # Move para /usr/bin
  if ! mv nomad /usr/bin/nomad; then
    log_error "Falha ao mover nomad para /usr/bin"
    return 1
  fi
  
  # Define permissões
  chmod +x /usr/bin/nomad
  
  # Limpa arquivos temporários
  cd /
  rm -rf "$TEMP_DIR"
  
  # Verifica instalação
  if nomad version >/dev/null 2>&1; then
    log_info "Nomad instalado com sucesso: $(nomad version | head -n1)"
  else
    log_error "Falha na verificação da instalação do Nomad"
    return 1
  fi
  
  return 0
}

# Função para instalar e configurar o Nomad
setup_nomad() {
  local NOMAD_ROLE="$1"
  local REGION="$2"
  local DC="$3"
  local NODE_NAME="$4"
  local DATA_DIR="$5"
  local NOMAD_USER="$6"
  local NOMAD_GROUP="$7"
  local NOMAD_HCL="$8"
  local NOMAD_JOIN="$9"
  local NOMAD_SERVERS_IN="${10}"
  local NOMAD_BOOTSTRAP_EXPECT="${11}"

  log_info "Instalando Nomad..."
  install_nomad_binary

  # Cria usuário/grupo se não existir
  if ! getent group "${NOMAD_GROUP}" >/dev/null 2>&1; then
    log_info "Criando grupo ${NOMAD_GROUP}..."
    addgroup --system "${NOMAD_GROUP}" || log_warn "Falha ao criar grupo ${NOMAD_GROUP}"
  fi
  if ! id -u "${NOMAD_USER}" >/dev/null 2>&1; then
    log_info "Criando usuário ${NOMAD_USER}..."
    adduser --system --no-create-home --shell /usr/sbin/nologin --ingroup "${NOMAD_GROUP}" "${NOMAD_USER}" || log_warn "Falha ao criar usuário ${NOMAD_USER}"
  fi

  # Dirs base / permissões
  install -d -m 0750 -o root -g "${NOMAD_GROUP}" /etc/nomad.d
  install -d -m 0750 -o "${NOMAD_USER}" -g "${NOMAD_GROUP}" "${DATA_DIR}"
  
  # Diretório para montagens de alocações Nomad
  install -d -m 0750 -o "${NOMAD_USER}" -g "${NOMAD_GROUP}" /opt/alloc_mounts
  log_info "Criado diretório /opt/alloc_mounts para montagens de alocações Nomad"

  # Normaliza lista de Nomad servers para client ("host:4647")
  NOMAD_SERVERS_JSON="[]"
  NOMAD_RETRY_JOIN_ARRAY=""
  
  echo "[DEBUG] NOMAD_JOIN: ${NOMAD_JOIN}"
  echo "[DEBUG] NOMAD_SERVERS_IN: ${NOMAD_SERVERS_IN}"
  
  if [[ "${NOMAD_JOIN,,}" == "s" && -n "${NOMAD_SERVERS_IN// }" ]]; then
    IFS=',' read -ra arr <<<"$NOMAD_SERVERS_IN"
    local s; local first=1; NOMAD_SERVERS_JSON="["
    local first_retry=1; NOMAD_RETRY_JOIN_ARRAY=""
    for s in "${arr[@]}"; do
      s="$(echo "$s" | xargs)"
      [[ -z "$s" ]] && continue
      
      # Para retry_join (apenas IP, sem porta)
      local ip_only="$s"
      if [[ "$s" == *:* ]]; then ip_only="${s%:*}"; fi
      if (( first_retry )); then 
        NOMAD_RETRY_JOIN_ARRAY+="\"$ip_only\""
        first_retry=0
      else 
        NOMAD_RETRY_JOIN_ARRAY+=", \"$ip_only\""
      fi
      
      # Para servers (com porta :4647)
      if [[ "$s" != *:* ]]; then s="${s}:4647"; fi
      if (( first )); then NOMAD_SERVERS_JSON+="\"$s\""; first=0; else NOMAD_SERVERS_JSON+=", \"$s\""; fi
    done
    NOMAD_SERVERS_JSON+="]"
    
    echo "[DEBUG] NOMAD_SERVERS_JSON gerado: $NOMAD_SERVERS_JSON"
    echo "[DEBUG] NOMAD_RETRY_JOIN_ARRAY gerado: $NOMAD_RETRY_JOIN_ARRAY"
  fi

  # ---------- NOMAD HCL - SERVER ou AMBOS ----------
  if [[ "$NOMAD_ROLE" == "1" || "$NOMAD_ROLE" == "3" ]]; then
    cat >"$NOMAD_HCL" <<HCL
bind_addr = "0.0.0.0"
region    = "${REGION}"
datacenter= "${DC}"
name      = "${NODE_NAME}"

data_dir  = "${DATA_DIR}"

# Integração com Consul
consul {
  address = "127.0.0.1:8500"
  server_service_name = "nomad"
  client_service_name = "nomad-client"
  auto_advertise = true
  server_auto_join = true
  client_auto_join = true
}

server {
  enabled          = true
  bootstrap_expect = ${NOMAD_BOOTSTRAP_EXPECT}
}

client {
  enabled = true
  servers = ["127.0.0.1"]
  
  # Configuração para montagens de alocações
  host_volume "alloc_mounts" {
    path = "/opt/alloc_mounts"
    read_only = false
  }
}

# Endurecimento leve (opcional)
acl {
  enabled = false
}
HCL
    
    # Adiciona retry_join se houver servidores configurados
    if [[ -n "$NOMAD_RETRY_JOIN_ARRAY" ]]; then
      echo "[INFO] Aplicando configuração de cluster com servidores: $NOMAD_RETRY_JOIN_ARRAY"
      # Adiciona retry_join na seção server
      sed -i "/bootstrap_expect = ${NOMAD_BOOTSTRAP_EXPECT}/a\  retry_join = [$NOMAD_RETRY_JOIN_ARRAY]" "$NOMAD_HCL"
      
      # Atualiza a lista de servidores na seção client
      sed -i "s/servers = \[\"127.0.0.1\"\]/servers = [$NOMAD_RETRY_JOIN_ARRAY]/" "$NOMAD_HCL"
    else
      echo "[WARNING] NOMAD_RETRY_JOIN_ARRAY está vazio - cluster não será configurado"
    fi
    
    chown root:"${NOMAD_GROUP}" "$NOMAD_HCL"
    chmod 0640 "$NOMAD_HCL"  # Permite leitura pelo grupo nomad

    # systemd do servidor (não-root)
    cat >/etc/systemd/system/nomad.service <<UNIT
[Unit]
Description=HashiCorp Nomad Server
Wants=network-online.target
After=network-online.target

[Service]
User=${NOMAD_USER}
Group=${NOMAD_GROUP}
ExecStart=/usr/bin/nomad agent -config=${NOMAD_HCL}
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
KillSignal=SIGINT
LimitNOFILE=65536
LimitNPROC=infinity
TasksMax=infinity
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ProtectClock=true
ProtectHostname=true
ProtectKernelTunables=true
ProtectControlGroups=true
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
UNIT
  # ---------- NOMAD HCL - APENAS CLIENT ----------
  elif [[ "$NOMAD_ROLE" == "2" ]]; then
    cat >"$NOMAD_HCL" <<HCL
bind_addr = "0.0.0.0"
region    = "${REGION}"
datacenter= "${DC}"
name      = "${NODE_NAME}"

data_dir  = "${DATA_DIR}"

# Integração com Consul
consul {
  address = "127.0.0.1:8500"
  client_service_name = "nomad-client"
  auto_advertise = true
  client_auto_join = true
}

client {
  enabled = true
  servers = ${NOMAD_SERVERS_JSON}
  
  # Configuração para montagens de alocações
  host_volume "alloc_mounts" {
    path = "/opt/alloc_mounts"
    read_only = false
  }
}
HCL
    
    # Atualiza a lista de servidores se houver servidores configurados
    if [[ -n "$NOMAD_RETRY_JOIN_ARRAY" ]]; then
      echo "[INFO] Cliente Nomad: Configurando servidores com $NOMAD_RETRY_JOIN_ARRAY"
      sed -i "s/servers = \${NOMAD_SERVERS_JSON}/servers = [$NOMAD_RETRY_JOIN_ARRAY]/" "$NOMAD_HCL"
    else
      echo "[INFO] Cliente Nomad: Usando configuração padrão de servidores $NOMAD_SERVERS_JSON"
    fi
    
    chown root:"${NOMAD_GROUP}" "$NOMAD_HCL"
    chmod 0640 "$NOMAD_HCL"  # Permite leitura pelo grupo nomad

    # systemd do cliente (root)
    cat >/etc/systemd/system/nomad.service <<UNIT
[Unit]
Description=HashiCorp Nomad Client
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/nomad agent -config=${NOMAD_HCL}
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
KillSignal=SIGINT
LimitNOFILE=65536
LimitNPROC=infinity
TasksMax=infinity
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
  fi

  # Adiciona usuário nomad ao grupo docker para executar containers
  if getent group docker >/dev/null 2>&1; then
    log_info "Adicionando usuário ${NOMAD_USER} ao grupo docker..."
    gpasswd -a "${NOMAD_USER}" docker || log_warn "Falha ao adicionar usuário ao grupo docker"
  else
    log_warn "Grupo docker não encontrado. Usuário ${NOMAD_USER} não foi adicionado ao grupo docker."
  fi
	
  # Habilita conforme papel
  systemctl daemon-reload
  systemctl enable nomad.service
  systemctl restart nomad.service
  
  log_info "Nomad instalado e configurado com sucesso!"
}

# Função para validar a configuração do Nomad
validate_nomad_config() {
  local NOMAD_HCL="$1"
  local INSTALL_CONSUL="$2"
  local errors=0
  
  # Verifica se o diretório de alocações existe
  if [[ ! -d "/opt/alloc_mounts" ]]; then
    log_warn "Diretório /opt/alloc_mounts não foi criado corretamente."
    ((errors++))
  fi
  
  # Verifica integração com Consul
  if [[ "$INSTALL_CONSUL" == "s" ]]; then
    if ! grep -q "consul {" "$NOMAD_HCL"; then
      log_warn "Integração com Consul não configurada no arquivo Nomad HCL."
      ((errors++))
    fi
  fi
  
  return $errors
}