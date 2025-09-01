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

  log_info "Instalando Nomad..."
  install_nomad_binary
  # Dirs base / permissões
  #install -d -m 0750 -o root -g "${NOMAD_GROUP}" /etc/nomad.d
  #install -d -m 0750 -o "${NOMAD_USER}" -g "${NOMAD_GROUP}" "${DATA_DIR}"
  mkdir -p "$DATA_DIR"
  mkdir -p "$NOMAD_HCL_DIR"
  mkdir -p /opt/alloc_mounts
  log_info "Criado diretórios"

  chown -R "$NOMAD_USER:$NOMAD_GROUP" "$NOMAD_HCL_DIR"
  chown -R "$NOMAD_USER:$NOMAD_GROUP" "$DATA_DIR"
  chown -R "$NOMAD_USER:$NOMAD_GROUP" "/opt/alloc_mounts"

  chmod 700 "$NOMAD_HCL_DIR"
  chmod 700 "$DATA_DIR"
  chmod 755 /opt/alloc_mounts

  useradd --system --home /etc/nomad.d --shell /bin/false "$NOMAD_USER"
  sudo usermod -G docker -a "$NOMAD_USER" || log_warn "Falha ao adicionar usuário ${NOMAD_USER} ao grupo docker"

  log_info "Aplicado Permissoes"

  # Diretório para montagens de alocações Nomad
  #install -d -m 0750 -o "${NOMAD_USER}" -g "${NOMAD_GROUP}" /opt/alloc_mounts
  #log_info "Criado diretório /opt/alloc_mounts para montagens de alocações Nomad"

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
  
  # ---------- CRIAÇÃO DO ARQUIVO PRINCIPAL NOMAD.HCL (SEMPRE) ----------
  cat >"$NOMAD_HCL" <<HCL
bind_addr = "$BIND_IP"
region    = "${REGION}"
datacenter= "${DC}"
name      = "${NODE_NAME}"
data_dir  = "${DATA_DIR}"

# Configuração de portas
ports {
  http = 4646
  rpc  = 4647
  serf = 4648
}
HCL

  # ---------- CRIAÇÃO DO ARQUIVO SERVER.HCL (ROLES 1 e 3) ----------
  if [[ "$NOMAD_ROLE" == "1" || "$NOMAD_ROLE" == "3" ]]; then
    cat >"$NOMAD_HCL_SERVER" <<HCL
server {
  enabled          = true
  bootstrap_expect = ${NOMAD_BOOTSTRAP_EXPECT}
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
client {
  enabled = true
  servers = ["127.0.0.1:4647"]
  
  # Configuração para montagens de alocações
  host_volume "alloc_mounts" {
    path = "/opt/alloc_mounts"
    read_only = false
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
    allow_caps = ["chown", "net_raw"]
    
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

# systemd do servidor (não-root)
    cat >/etc/systemd/system/nomad.service <<UNIT
[Unit]
Description=Nomad
Documentation=https://www.nomadproject.io/docs/
Wants=network-online.target
After=network-online.target

# When using Nomad with Consul it is not necessary to start Consul first. These
# lines start Consul before Nomad as an optimization to avoid Nomad logging
# that Consul is unavailable at startup.
#Wants=consul.service
#After=consul.service

[Service]

# Nomad server should be run as the nomad user. Nomad clients
# should be run as root
User=nomad
Group=nomad

ExecReload=/bin/kill -HUP $MAINPID
ExecStart=/usr/bin/nomad agent -config /etc/nomad.d
KillMode=process
KillSignal=SIGINT
LimitNOFILE=65536
LimitNPROC=infinity
Restart=on-failure
RestartSec=2

## Configure unit start rate limiting. Units which are started more than
## *burst* times within an *interval* time span are not permitted to start any
## more. Use StartLimitIntervalSec or StartLimitInterval (depending on
## systemd version) to configure the checking interval and StartLimitBurst
## to configure how many starts per interval are allowed. The values in the
## commented lines are defaults.

# StartLimitBurst = 5

## StartLimitIntervalSec is used for systemd versions >= 230
# StartLimitIntervalSec = 10s

## StartLimitInterval is used for systemd versions < 230
# StartLimitInterval = 10s

TasksMax=infinity
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target

UNIT

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