#!/usr/bin/env bash
# ==============================================================================
# Funções para instalação e configuração do Consul
# ==============================================================================

# Importa funções comuns
source "$(dirname "$0")/common.sh"

# Função para instalar e configurar o Consul
setup_consul() {
  local DC="$1"
  local NODE_NAME="$2"
  local CONSUL_BOOTSTRAP_EXPECT="$3"
  local CONSUL_ADVERTISE_ADDR="$4"
  local CONSUL_ENCRYPT_KEY="$5"
  local CONSUL_JOIN_IN="$6"

  log_info "Instalando Consul..."
  apt-get install -yq --no-install-recommends consul

  # Dirs e permissões mínimas
  install -d -m 0750 -o consul -g consul /etc/consul.d
  install -d -m 0750 -o consul -g consul /var/lib/consul

  # Monta retry_join se informado
  local RJ=$(montar_retry_join "$CONSUL_JOIN_IN")

  # Configuração completa para Consul (baseada nas melhores práticas)
  cat >/etc/consul.d/consul.hcl <<HCL
datacenter          = "${DC}"
primary_datacenter  = "${DC}"
node_name           = "${NODE_NAME}"
server              = true
bootstrap_expect    = ${CONSUL_BOOTSTRAP_EXPECT}

bind_addr           = "0.0.0.0"
client_addr         = "127.0.0.1"        # segurança: UI/API só local (ajuste se necessário)
advertise_addr      = "${CONSUL_ADVERTISE_ADDR}"      # IP PRIVADO deste nó

ui_config { enabled = true }      # UI disponível via 127.0.0.1:8500

retry_join = ${RJ}
data_dir  = "/var/lib/consul"

encrypt = "${CONSUL_ENCRYPT_KEY}"
HCL
  chown consul:consul /etc/consul.d/consul.hcl
  chmod 0640 /etc/consul.d/consul.hcl

  # systemd
  cat >/etc/systemd/system/consul.service <<'UNIT'
[Unit]
Description=HashiCorp Consul Agent
Wants=network-online.target
After=network-online.target

[Service]
User=consul
Group=consul
ExecStart=/usr/bin/consul agent -config-dir=/etc/consul.d
ExecReload=/bin/kill -HUP $MAINPID
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
  log_info "Gerando nova chave de criptografia para Consul..."
  local key=$(consul keygen 2>/dev/null || echo "")
  
  if [[ -z "$key" ]]; then
    log_info "Consul não está disponível para gerar chave. Instalando temporariamente..."
    apt-get install -yq --no-install-recommends consul >/dev/null 2>&1
    key=$(consul keygen)
    log_info "Chave gerada: $key"
    log_warn "IMPORTANTE: Guarde esta chave para usar em outros nós do cluster!"
  else
    log_info "Chave gerada: $key"
    log_warn "IMPORTANTE: Guarde esta chave para usar em outros nós do cluster!"
  fi
  
  echo "$key"
}

# Função para validar a configuração do Consul
validate_consul_config() {
  local CONSUL_BOOTSTRAP_EXPECT="$1"
  local CONSUL_JOIN_IN="$2"
  local CONSUL_ENCRYPT_KEY="$3"
  local CONSUL_WANTS_JOIN="$4"
  local errors=0
  
  # Verifica se bootstrap_expect é consistente com o número de servidores em retry_join
  if [[ "$CONSUL_WANTS_JOIN" == "s" && -n "${CONSUL_JOIN_IN// }" ]]; then
    local num_servers=$(echo "$CONSUL_JOIN_IN" | tr ',' '\n' | wc -l)
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