#!/usr/bin/env bash
# ==============================================================================
# Script de Endurecimento de Segurança para Nomad e Consul
# ==============================================================================

# Importa funções comuns
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Verifica se está rodando como root
check_root

# Configurações
CONSUL_CONFIG_DIR="/etc/consul.d"
NOMAD_CONFIG_DIR="/etc/nomad.d"
CONSUL_CERTS_DIR="${CONSUL_CONFIG_DIR}/certs"
NOMAD_CERTS_DIR="${NOMAD_CONFIG_DIR}/certs"
BACKUP_DIR="/root/cluster-backup-$(date +%Y%m%d-%H%M%S)"

# Função para fazer backup das configurações atuais
backup_configs() {
    log_info "Criando backup das configurações atuais..."
    
    mkdir -p "$BACKUP_DIR"
    
    if [[ -f "${CONSUL_CONFIG_DIR}/consul.hcl" ]]; then
        cp "${CONSUL_CONFIG_DIR}/consul.hcl" "${BACKUP_DIR}/consul.hcl.backup"
        log_info "Backup do Consul criado: ${BACKUP_DIR}/consul.hcl.backup"
    fi
    
    if [[ -f "${NOMAD_CONFIG_DIR}/nomad.hcl" ]]; then
        cp "${NOMAD_CONFIG_DIR}/nomad.hcl" "${BACKUP_DIR}/nomad.hcl.backup"
        log_info "Backup do Nomad criado: ${BACKUP_DIR}/nomad.hcl.backup"
    fi
}

# Função para configurar TLS para Consul
setup_consul_tls() {
    log_info "Configurando TLS para Consul..."
    
    # Cria diretório para certificados
    mkdir -p "$CONSUL_CERTS_DIR"
    chown consul:consul "$CONSUL_CERTS_DIR"
    chmod 750 "$CONSUL_CERTS_DIR"
    
    # Gera CA se não existir
    if [[ ! -f "${CONSUL_CERTS_DIR}/consul-agent-ca.pem" ]]; then
        log_info "Gerando CA para Consul..."
        cd "$CONSUL_CERTS_DIR"
        consul tls ca create
        chown consul:consul consul-agent-ca*
    fi
    
    # Gera certificado do servidor se não existir
    if [[ ! -f "${CONSUL_CERTS_DIR}/dc1-server-consul-0.pem" ]]; then
        log_info "Gerando certificado do servidor Consul..."
        cd "$CONSUL_CERTS_DIR"
        consul tls cert create -server -dc dc1
        chown consul:consul dc1-server-consul-0*
    fi
    
    # Adiciona configuração TLS ao consul.hcl
    if ! grep -q "tls {" "${CONSUL_CONFIG_DIR}/consul.hcl"; then
        log_info "Adicionando configuração TLS ao Consul..."
        cat >> "${CONSUL_CONFIG_DIR}/consul.hcl" << 'EOF'

# Configuração TLS
tls {
  defaults {
    verify_incoming = true
    verify_outgoing = true
    verify_server_hostname = true
  }
  internal_rpc {
    ca_file = "/etc/consul.d/certs/consul-agent-ca.pem"
    cert_file = "/etc/consul.d/certs/dc1-server-consul-0.pem"
    key_file = "/etc/consul.d/certs/dc1-server-consul-0-key.pem"
  }
  https {
    ca_file = "/etc/consul.d/certs/consul-agent-ca.pem"
    cert_file = "/etc/consul.d/certs/dc1-server-consul-0.pem"
    key_file = "/etc/consul.d/certs/dc1-server-consul-0-key.pem"
  }
}

# Configuração de portas seguras
ports {
  https = 8501
  http = -1  # Desabilita HTTP não criptografado
}
EOF
    fi
}

# Função para configurar ACLs do Consul
setup_consul_acls() {
    log_info "Configurando ACLs para Consul..."
    
    # Adiciona configuração ACL ao consul.hcl
    if ! grep -q "acl = {" "${CONSUL_CONFIG_DIR}/consul.hcl"; then
        log_info "Adicionando configuração ACL ao Consul..."
        cat >> "${CONSUL_CONFIG_DIR}/consul.hcl" << 'EOF'

# Configuração ACL
acl = {
  enabled = true
  default_policy = "deny"
  enable_token_persistence = true
}
EOF
    fi
    
    # Cria política para agentes
    cat > "${CONSUL_CONFIG_DIR}/agent-policy.hcl" << 'EOF'
node_prefix "" {
  policy = "write"
}
service_prefix "" {
  policy = "read"
}
key_prefix "" {
  policy = "read"
}
session_prefix "" {
  policy = "write"
}
EOF
    
    # Cria política para Nomad
    cat > "${CONSUL_CONFIG_DIR}/nomad-policy.hcl" << 'EOF'
key_prefix "nomad/" {
  policy = "write"
}
node_prefix "" {
  policy = "read"
}
service_prefix "" {
  policy = "write"
}
session_prefix "" {
  policy = "write"
}
EOF
    
    chown consul:consul "${CONSUL_CONFIG_DIR}"/*.hcl
}

# Função para configurar TLS para Nomad
setup_nomad_tls() {
    log_info "Configurando TLS para Nomad..."
    
    # Cria diretório para certificados
    mkdir -p "$NOMAD_CERTS_DIR"
    chown nomad:nomad "$NOMAD_CERTS_DIR"
    chmod 750 "$NOMAD_CERTS_DIR"
    
    # Gera certificados para Nomad (usando openssl como alternativa)
    if [[ ! -f "${NOMAD_CERTS_DIR}/nomad-ca.pem" ]]; then
        log_info "Gerando certificados para Nomad..."
        cd "$NOMAD_CERTS_DIR"
        
        # Gera CA
        openssl genrsa -out nomad-ca-key.pem 4096
        openssl req -new -x509 -days 365 -key nomad-ca-key.pem -sha256 -out nomad-ca.pem -subj "/C=BR/ST=State/L=City/O=Organization/CN=Nomad CA"
        
        # Gera certificado do servidor
        openssl genrsa -out server-key.pem 4096
        openssl req -subj "/CN=server" -sha256 -new -key server-key.pem -out server.csr
        openssl x509 -req -days 365 -sha256 -in server.csr -CA nomad-ca.pem -CAkey nomad-ca-key.pem -out server.pem -CAcreateserial
        
        # Remove CSR
        rm server.csr
        
        # Define permissões
        chown nomad:nomad *
        chmod 600 *-key.pem
    fi
    
    # Adiciona configuração TLS ao nomad.hcl
    if ! grep -q "tls {" "${NOMAD_CONFIG_DIR}/nomad.hcl"; then
        log_info "Adicionando configuração TLS ao Nomad..."
        cat >> "${NOMAD_CONFIG_DIR}/nomad.hcl" << 'EOF'

# Configuração TLS
tls {
  http = true
  rpc  = true

  ca_file   = "/etc/nomad.d/certs/nomad-ca.pem"
  cert_file = "/etc/nomad.d/certs/server.pem"
  key_file  = "/etc/nomad.d/certs/server-key.pem"

  verify_server_hostname = true
  verify_https_client    = true
}
EOF
    fi
}

# Função para configurar ACLs do Nomad
setup_nomad_acls() {
    log_info "Configurando ACLs para Nomad..."
    
    # Adiciona configuração ACL ao nomad.hcl
    if ! grep -q "acl {" "${NOMAD_CONFIG_DIR}/nomad.hcl"; then
        log_info "Adicionando configuração ACL ao Nomad..."
        cat >> "${NOMAD_CONFIG_DIR}/nomad.hcl" << 'EOF'

# Configuração ACL
acl {
  enabled = true
}
EOF
    fi
}

# Função para configurar logs de auditoria
setup_audit_logs() {
    log_info "Configurando logs de auditoria..."
    
    # Cria diretórios de logs
    mkdir -p /var/log/consul /var/log/nomad
    chown consul:consul /var/log/consul
    chown nomad:nomad /var/log/nomad
    
    # Adiciona configuração de logs ao Consul
    if ! grep -q "log_file" "${CONSUL_CONFIG_DIR}/consul.hcl"; then
        cat >> "${CONSUL_CONFIG_DIR}/consul.hcl" << 'EOF'

# Configuração de logs
log_level = "INFO"
log_file = "/var/log/consul/"
log_rotate_duration = "24h"
log_rotate_max_files = 30
EOF
    fi
    
    # Adiciona configuração de logs ao Nomad
    if ! grep -q "log_file" "${NOMAD_CONFIG_DIR}/nomad.hcl"; then
        cat >> "${NOMAD_CONFIG_DIR}/nomad.hcl" << 'EOF'

# Configuração de logs
log_level = "INFO"
log_file = "/var/log/nomad/"
log_rotate_duration = "24h"
log_rotate_max_files = 30
EOF
    fi
}

# Função para configurar firewall básico
setup_firewall() {
    log_info "Configurando firewall básico..."
    
    # Instala UFW se não estiver instalado
    if ! command -v ufw >/dev/null 2>&1; then
        log_info "Instalando UFW..."
        apt-get update -qq
        apt-get install -yq ufw
    fi
    
    # Configurações básicas do UFW
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    
    # Permite SSH
    ufw allow ssh
    
    # Permite acesso local
    ufw allow from 127.0.0.1
    
    # Detecta rede local e permite acesso do cluster
    local_network=$(ip route | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | grep -v '127.0.0.1' | head -1 | awk '{print $1}')
    if [[ -n "$local_network" ]]; then
        log_info "Permitindo acesso da rede local: $local_network"
        ufw allow from "$local_network" to any port 8300,8301,8302,8500,8501
        ufw allow from "$local_network" to any port 4646,4647,4648
    fi
    
    # Ativa o firewall
    ufw --force enable
    
    log_info "Firewall configurado. Status:"
    ufw status
}

# Função para reiniciar serviços
restart_services() {
    log_info "Reiniciando serviços..."
    
    systemctl restart consul
    sleep 5
    systemctl restart nomad
    sleep 5
    
    # Verifica status
    if systemctl is-active --quiet consul; then
        log_info "✅ Consul está rodando"
    else
        log_error "❌ Consul falhou ao iniciar"
    fi
    
    if systemctl is-active --quiet nomad; then
        log_info "✅ Nomad está rodando"
    else
        log_error "❌ Nomad falhou ao iniciar"
    fi
}

# Função para exibir instruções pós-instalação
show_post_install_instructions() {
    log_info "\n=== INSTRUÇÕES PÓS-INSTALAÇÃO ==="
    
    echo "1. BOOTSTRAP ACLs (execute após todos os nós estarem online):"
    echo "   consul acl bootstrap"
    echo "   nomad acl bootstrap"
    echo ""
    echo "2. SALVE OS TOKENS GERADOS em local seguro!"
    echo ""
    echo "3. ACESSO SEGURO:"
    echo "   Consul HTTPS: https://$(hostname -I | awk '{print $1}'):8501"
    echo "   Nomad HTTPS:  https://$(hostname -I | awk '{print $1}'):4646"
    echo ""
    echo "4. CONFIGURAR CLIENTES:"
    echo "   export CONSUL_HTTP_SSL=true"
    echo "   export CONSUL_CACERT=/etc/consul.d/certs/consul-agent-ca.pem"
    echo "   export NOMAD_CACERT=/etc/nomad.d/certs/nomad-ca.pem"
    echo ""
    echo "5. BACKUP CRIADO EM: $BACKUP_DIR"
    echo ""
    log_warn "IMPORTANTE: Teste todas as funcionalidades antes de usar em produção!"
}

# Função principal
main() {
    log_info "Iniciando endurecimento de segurança do cluster..."
    
    # Verifica se os serviços estão instalados
    if ! command -v consul >/dev/null 2>&1; then
        log_error "Consul não está instalado. Execute o script de instalação primeiro."
        exit 1
    fi
    
    if ! command -v nomad >/dev/null 2>&1; then
        log_error "Nomad não está instalado. Execute o script de instalação primeiro."
        exit 1
    fi
    
    # Executa configurações de segurança
    backup_configs
    setup_consul_tls
    setup_consul_acls
    setup_nomad_tls
    setup_nomad_acls
    setup_audit_logs
    setup_firewall
    restart_services
    show_post_install_instructions
    
    log_info "✅ Endurecimento de segurança concluído!"
}

# Executa apenas se chamado diretamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi