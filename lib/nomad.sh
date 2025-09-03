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
  local NOMAD_HCL_DIR="${12}"
  local NOMAD_HCL_SERVER="${13}"
  local NOMAD_HCL_CLIENT="${14}"

  # Validação de parâmetros obrigatórios
  if [[ -z "$NOMAD_ROLE" || -z "$REGION" || -z "$DC" || -z "$NODE_NAME" || -z "$DATA_DIR" ]]; then
    log_error "Parâmetros obrigatórios faltando: NOMAD_ROLE, REGION, DC, NODE_NAME, DATA_DIR"
    return 1
  fi

  if [[ -z "$NOMAD_USER" || -z "$NOMAD_GROUP" || -z "$NOMAD_HCL_DIR" ]]; then
    log_error "Parâmetros obrigatórios faltando: NOMAD_USER, NOMAD_GROUP, NOMAD_HCL_DIR"
    return 1
  fi

  if [[ ! "$NOMAD_ROLE" =~ ^[1-3]$ ]]; then
    log_error "NOMAD_ROLE deve ser 1 (servidor), 2 (cliente) ou 3 (ambos)"
    return 1
  fi

  log_info "Instalando Nomad..."
  if ! install_nomad_binary; then
    log_error "Falha na instalação do binário do Nomad"
    return 1
  fi

  # Cria usuário/grupo se não existir
  if ! getent group "$NOMAD_GROUP" >/dev/null 2>&1; then
    log_info "Criando grupo $NOMAD_GROUP..."
    addgroup --system "$NOMAD_GROUP" || log_warn "Falha ao criar grupo $NOMAD_GROUP"
  fi
  if ! id -u "$NOMAD_USER" >/dev/null 2>&1; then
    log_info "Criando usuário $NOMAD_USER..."
    useradd --system --home /etc/nomad.d --shell /bin/false --gid "$NOMAD_GROUP" "$NOMAD_USER"
    usermod -G docker -a "$NOMAD_USER" || log_warn "Falha ao adicionar usuário $NOMAD_USER ao grupo docker"
  fi

  # Cria diretórios
  log_info "Criando diretórios necessários..."
  if ! mkdir -p "$DATA_DIR" "$NOMAD_HCL_DIR" /opt/alloc_mounts; then
    log_error "Falha ao criar diretórios necessários"
    return 1
  fi
  log_info "Diretórios criados com sucesso"

  # Aplica permissões
  chown -R "$NOMAD_USER:$NOMAD_GROUP" "$NOMAD_HCL_DIR"
  chown -R "$NOMAD_USER:$NOMAD_GROUP" "$DATA_DIR"
  chown -R "$NOMAD_USER:$NOMAD_GROUP" "/opt/alloc_mounts"

  chmod 700 "$NOMAD_HCL_DIR"
  chmod 755 "$DATA_DIR"
  chmod 755 /opt/alloc_mounts
  log_info "Aplicado permissões"

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

  # Detecta o IP da interface de rede principal
  BIND_IP="0.0.0.0"
  if command -v ip >/dev/null 2>&1; then
    # Tenta detectar o IP da interface principal (não loopback)
    DETECTED_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    if [[ -n "$DETECTED_IP" && "$DETECTED_IP" != "127.0.0.1" ]]; then
      BIND_IP="$DETECTED_IP"
      echo "[INFO] IP detectado automaticamente: $BIND_IP"
    fi
  fi
  
  # ---------- CRIAÇÃO DO ARQUIVO SERVER.HCL (ROLES 1 e 3) ----------
  if [[ "$NOMAD_ROLE" == "1" || "$NOMAD_ROLE" == "3" ]]; then
    cat >"$NOMAD_HCL_SERVER" <<HCL

  bind_addr = "$BIND_IP"
  region    = "${REGION}"
  datacenter= "${DC}"
  name      = "${NODE_NAME}-server"
  data_dir  = "${DATA_DIR}/server"

  ports {
    http = 4646
    rpc  = 4647
    serf = 4648
  }

  advertise {
    http = "$BIND_IP"
    rpc  = "$BIND_IP"
    serf = "$BIND_IP"
  }
  
  server {
    enabled          = true
    bootstrap_expect = ${NOMAD_BOOTSTRAP_EXPECT}
  }
  

  # Integração com Consul
  consul {
    address = "127.0.0.1:8500"
    server_service_name = "nomad"
    client_service_name = "nomad-client"
    auto_advertise = true
    server_auto_join = true
    client_auto_join = true
  }  
HCL

    # Adiciona server_join se houver servidores configurados
    if [[ -n "$NOMAD_RETRY_JOIN_ARRAY" ]]; then
      echo "[INFO] Aplicando configuração de cluster com servidores: $NOMAD_RETRY_JOIN_ARRAY"
      # Adiciona server_join na seção server do arquivo server.hcl
      sed -i "/bootstrap_expect = ${NOMAD_BOOTSTRAP_EXPECT}/a\\  server_join {" "$NOMAD_HCL_SERVER"
      sed -i "/server_join {/a\\    retry_join     = [$NOMAD_RETRY_JOIN_ARRAY]" "$NOMAD_HCL_SERVER"
      sed -i "/retry_join.*=/a\\    retry_max      = 3" "$NOMAD_HCL_SERVER"
      sed -i "/retry_max.*=/a\\    retry_interval = \"15s\"" "$NOMAD_HCL_SERVER"
      sed -i "/retry_interval.*=/a\\  }" "$NOMAD_HCL_SERVER"
    else
      echo "[WARNING] NOMAD_RETRY_JOIN_ARRAY está vazio - cluster não será configurado"
    fi
  fi

  # ---------- CRIAÇÃO DO ARQUIVO CLIENT.HCL (ROLES 2 e 3) ----------
  if [[ "$NOMAD_ROLE" == "2" || "$NOMAD_ROLE" == "3" ]]; then
    cat >"$NOMAD_HCL_CLIENT" <<HCL
  bind_addr = "$BIND_IP"
  region    = "${REGION}"
  datacenter= "${DC}"
  name      = "${NODE_NAME}-client"
  data_dir  = "${DATA_DIR}/client"

  ports {
    http = 46461
    rpc  = 46471
    serf = 46481
  }  

  client {
  enabled = true
  servers = ["127.0.0.1:4647"] 
  # Configuração para montagens de alocações
  host_volume "alloc_mounts" {
    path = "/opt/alloc_mounts"
    read_only = false
  }
  meta {
    node = "${NODE_NAME}"
  }

}

  # Plugin Docker
  plugin "docker" {
  config {
    endpoint = "unix:///var/run/docker.sock"
    
    volumes {
      enabled = true
    }
    
    allow_privileged = false
    allow_caps = ["chown", "net_raw", "net_bind_service"]
    
    gc {
      image = true
      image_delay = "3m"
      container = true
    }
  }
}
HCL

    # Atualiza a lista de servidores se houver servidores configurados
    if [[ -n "$NOMAD_SERVERS_JSON" && "$NOMAD_SERVERS_JSON" != "[]" ]]; then
      echo "[INFO] Cliente Nomad: Configurando servidores com $NOMAD_SERVERS_JSON"
      sed -i "s/servers = \[\"127.0.0.1:4647\"\]/servers = $NOMAD_SERVERS_JSON/" "$NOMAD_HCL_CLIENT"
    else
      echo "[INFO] Cliente Nomad: Usando configuração padrão de servidores"
    fi
  fi


# systemd do servidor
if [[ "$NOMAD_ROLE" == "1" || "$NOMAD_ROLE" == "3" ]]; then
    cat >/etc/systemd/system/nomad-server.service <<UNIT
[Unit]
Description=Nomad Server
Documentation=https://www.nomadproject.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
User=nomad
Group=nomad

ExecReload=/bin/kill -HUP $MAINPID
ExecStart=/usr/bin/nomad agent -config /etc/nomad.d/server.hcl
KillMode=process
KillSignal=SIGINT
LimitNOFILE=65536
LimitNPROC=infinity
Restart=on-failure
RestartSec=2

TasksMax=infinity
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target

UNIT
fi


# systemd do client
if [[ "$NOMAD_ROLE" == "2" || "$NOMAD_ROLE" == "3" ]]; then
    cat >/etc/systemd/system/nomad-client.service <<UNIT
[Unit]
Description=Nomad Client
Documentation=https://www.nomadproject.io/docs/
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root

ExecReload=/bin/kill -HUP $MAINPID
ExecStart=/usr/bin/nomad agent -config /etc/nomad.d/client.hcl
KillMode=process
KillSignal=SIGINT
LimitNOFILE=65536
LimitNPROC=infinity
Restart=on-failure
RestartSec=2

TasksMax=infinity
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target

UNIT
fi

  # Adiciona usuário nomad ao grupo docker para executar containers
  if getent group docker >/dev/null 2>&1; then
    log_info "Adicionando usuário nomad ao grupo docker..."
    gpasswd -a nomad docker || log_warn "Falha ao adicionar usuário ao grupo docker"
  else
    log_warn "Grupo docker não encontrado. Usuário nomad não foi adicionado ao grupo docker."
  fi
	
  # Habilita conforme papel
  systemctl daemon-reload
if [[ "$NOMAD_ROLE" == "1" || "$NOMAD_ROLE" == "3" ]]; then  
  systemctl enable nomad-server.service
  systemctl restart nomad-server.service
fi
if [[ "$NOMAD_ROLE" == "2" || "$NOMAD_ROLE" == "3" ]]; then
  systemctl enable nomad-client.service
  systemctl restart nomad-client.service
fi
  
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