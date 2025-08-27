#!/usr/bin/env bash
# ==============================================================================
# Funções para instalação e configuração do Nomad
# ==============================================================================

# Importa funções comuns
source "$(dirname "$0")/common.sh"

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
  local CONSUL_BOOTSTRAP_EXPECT="${11}"

  log_info "Instalando Nomad..."
  apt-get install -yq --no-install-recommends nomad

  # Usuário/grupo para servidor (mínimo privilégio)
  if ! getent group "${NOMAD_GROUP}" >/dev/null; then
    groupadd --system "${NOMAD_GROUP}"
  fi
  if ! id -u "${NOMAD_USER}" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin --gid "${NOMAD_GROUP}" "${NOMAD_USER}"
  fi

  # Dirs base / permissões
  install -d -m 0750 -o root -g "${NOMAD_GROUP}" /etc/nomad.d
  install -d -m 0750 -o "${NOMAD_USER}" -g "${NOMAD_GROUP}" "${DATA_DIR}"
  
  # Diretório para montagens de alocações Nomad
  install -d -m 0750 -o "${NOMAD_USER}" -g "${NOMAD_GROUP}" /opt/alloc_mounts
  log_info "Criado diretório /opt/alloc_mounts para montagens de alocações Nomad"

  # Normaliza lista de Nomad servers para client ("host:4647")
  local NOMAD_SERVERS_JSON="[]"
  if [[ "${NOMAD_JOIN,,}" == "s" && -n "${NOMAD_SERVERS_IN// }" ]]; then
    local arr=() IFS=',' read -ra arr <<<"$NOMAD_SERVERS_IN"
    local s; local first=1; NOMAD_SERVERS_JSON="["
    for s in "${arr[@]}"; do
      s="$(echo "$s" | xargs)"
      [[ -z "$s" ]] && continue
      # adiciona :4647 se faltou porta
      if [[ "$s" != *:* ]]; then s="${s}:4647"; fi
      if (( first )); then NOMAD_SERVERS_JSON+="\"$s\""; first=0; else NOMAD_SERVERS_JSON+=", \"$s\""; fi
    done
    NOMAD_SERVERS_JSON+="]"
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
  bootstrap_expect = ${CONSUL_BOOTSTRAP_EXPECT}
  # retry_join pode ser configurado aqui para formar cluster de servers (opcional)
  # retry_join = ["10.0.0.10","10.0.0.11"]
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
    chown root:"${NOMAD_GROUP}" "$NOMAD_HCL"
    chmod 0640 "$NOMAD_HCL"

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
    chown root:"${NOMAD_GROUP}" "$NOMAD_HCL"
    chmod 0640 "$NOMAD_HCL"

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
  usermod -aG docker nomad
	
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