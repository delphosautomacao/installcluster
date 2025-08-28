#!/usr/bin/env bash
# ==============================================================================
# Script para configurar políticas ACL e tokens para Nomad e Consul
# ==============================================================================

# Importa funções comuns
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Configurações
CONSUL_CONFIG_DIR="/etc/consul.d"
NOMAD_CONFIG_DIR="/etc/nomad.d"
TOKENS_DIR="/root/cluster-tokens"

# Função para verificar se ACLs estão habilitados
check_acl_status() {
    log_info "Verificando status dos ACLs..."
    
    # Verifica Consul
    if consul info 2>/dev/null | grep -q "acl.*enabled.*true"; then
        log_info "✅ ACLs do Consul estão habilitados"
    else
        log_error "❌ ACLs do Consul não estão habilitados"
        log_info "Execute o script security-hardening.sh primeiro"
        exit 1
    fi
    
    # Verifica Nomad
    if nomad server members 2>/dev/null | grep -q "alive"; then
        log_info "✅ Nomad está rodando"
    else
        log_error "❌ Nomad não está acessível"
        exit 1
    fi
}

# Função para fazer bootstrap dos ACLs
bootstrap_acls() {
    log_info "Fazendo bootstrap dos ACLs..."
    
    mkdir -p "$TOKENS_DIR"
    chmod 700 "$TOKENS_DIR"
    
    # Bootstrap Consul ACL
    if [[ ! -f "${TOKENS_DIR}/consul-bootstrap.token" ]]; then
        log_info "Bootstrap do Consul ACL..."
        if consul acl bootstrap > "${TOKENS_DIR}/consul-bootstrap.token" 2>/dev/null; then
            log_info "✅ Bootstrap do Consul ACL realizado com sucesso"
            CONSUL_TOKEN=$(grep "SecretID" "${TOKENS_DIR}/consul-bootstrap.token" | awk '{print $2}')
            export CONSUL_HTTP_TOKEN="$CONSUL_TOKEN"
        else
            log_warn "Bootstrap do Consul ACL já foi realizado ou falhou"
            log_info "Se já foi realizado, defina CONSUL_HTTP_TOKEN manualmente"
        fi
    else
        log_info "Token de bootstrap do Consul já existe"
        CONSUL_TOKEN=$(grep "SecretID" "${TOKENS_DIR}/consul-bootstrap.token" | awk '{print $2}')
        export CONSUL_HTTP_TOKEN="$CONSUL_TOKEN"
    fi
    
    # Bootstrap Nomad ACL
    if [[ ! -f "${TOKENS_DIR}/nomad-bootstrap.token" ]]; then
        log_info "Bootstrap do Nomad ACL..."
        if nomad acl bootstrap > "${TOKENS_DIR}/nomad-bootstrap.token" 2>/dev/null; then
            log_info "✅ Bootstrap do Nomad ACL realizado com sucesso"
            NOMAD_TOKEN=$(grep "Secret ID" "${TOKENS_DIR}/nomad-bootstrap.token" | awk '{print $4}')
            export NOMAD_TOKEN="$NOMAD_TOKEN"
        else
            log_warn "Bootstrap do Nomad ACL já foi realizado ou falhou"
            log_info "Se já foi realizado, defina NOMAD_TOKEN manualmente"
        fi
    else
        log_info "Token de bootstrap do Nomad já existe"
        NOMAD_TOKEN=$(grep "Secret ID" "${TOKENS_DIR}/nomad-bootstrap.token" | awk '{print $4}')
        export NOMAD_TOKEN="$NOMAD_TOKEN"
    fi
}

# Função para criar políticas do Consul
create_consul_policies() {
    log_info "Criando políticas do Consul..."
    
    # Política para agentes Consul
    cat > "${TOKENS_DIR}/consul-agent-policy.hcl" << 'EOF'
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
    
    # Política para Nomad
    cat > "${TOKENS_DIR}/consul-nomad-policy.hcl" << 'EOF'
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
    
    # Política para operadores (leitura)
    cat > "${TOKENS_DIR}/consul-operator-read-policy.hcl" << 'EOF'
node_prefix "" {
  policy = "read"
}
service_prefix "" {
  policy = "read"
}
key_prefix "" {
  policy = "read"
}
session_prefix "" {
  policy = "read"
}
operator = "read"
EOF
    
    # Política para operadores (escrita)
    cat > "${TOKENS_DIR}/consul-operator-write-policy.hcl" << 'EOF'
node_prefix "" {
  policy = "write"
}
service_prefix "" {
  policy = "write"
}
key_prefix "" {
  policy = "write"
}
session_prefix "" {
  policy = "write"
}
operator = "write"
EOF
    
    # Cria as políticas no Consul
    consul acl policy create \
        -name "agent-policy" \
        -description "Policy for Consul agents" \
        -rules @"${TOKENS_DIR}/consul-agent-policy.hcl" 2>/dev/null || log_warn "Política agent-policy já existe"
    
    consul acl policy create \
        -name "nomad-policy" \
        -description "Policy for Nomad integration" \
        -rules @"${TOKENS_DIR}/consul-nomad-policy.hcl" 2>/dev/null || log_warn "Política nomad-policy já existe"
    
    consul acl policy create \
        -name "operator-read-policy" \
        -description "Read-only policy for operators" \
        -rules @"${TOKENS_DIR}/consul-operator-read-policy.hcl" 2>/dev/null || log_warn "Política operator-read-policy já existe"
    
    consul acl policy create \
        -name "operator-write-policy" \
        -description "Write policy for operators" \
        -rules @"${TOKENS_DIR}/consul-operator-write-policy.hcl" 2>/dev/null || log_warn "Política operator-write-policy já existe"
    
    log_info "✅ Políticas do Consul criadas"
}

# Função para criar políticas do Nomad
create_nomad_policies() {
    log_info "Criando políticas do Nomad..."
    
    # Política para operadores (leitura)
    cat > "${TOKENS_DIR}/nomad-operator-read-policy.hcl" << 'EOF'
namespace "*" {
  policy = "read"
  capabilities = ["read-job", "read-logs"]
}

node {
  policy = "read"
}

operator {
  policy = "read"
}
EOF
    
    # Política para operadores (escrita)
    cat > "${TOKENS_DIR}/nomad-operator-write-policy.hcl" << 'EOF'
namespace "*" {
  policy = "write"
  capabilities = ["submit-job", "dispatch-job", "read-logs", "alloc-exec", "alloc-node-exec"]
}

node {
  policy = "write"
}

operator {
  policy = "write"
}
EOF
    
    # Política para desenvolvedores
    cat > "${TOKENS_DIR}/nomad-developer-policy.hcl" << 'EOF'
namespace "default" {
  policy = "write"
  capabilities = ["submit-job", "dispatch-job", "read-logs", "alloc-exec"]
}

namespace "dev" {
  policy = "write"
  capabilities = ["submit-job", "dispatch-job", "read-logs", "alloc-exec"]
}

node {
  policy = "read"
}
EOF
    
    # Cria as políticas no Nomad
    nomad acl policy apply \
        -description "Read-only policy for operators" \
        operator-read "${TOKENS_DIR}/nomad-operator-read-policy.hcl" 2>/dev/null || log_warn "Política operator-read já existe"
    
    nomad acl policy apply \
        -description "Write policy for operators" \
        operator-write "${TOKENS_DIR}/nomad-operator-write-policy.hcl" 2>/dev/null || log_warn "Política operator-write já existe"
    
    nomad acl policy apply \
        -description "Policy for developers" \
        developer "${TOKENS_DIR}/nomad-developer-policy.hcl" 2>/dev/null || log_warn "Política developer já existe"
    
    log_info "✅ Políticas do Nomad criadas"
}

# Função para criar tokens
create_tokens() {
    log_info "Criando tokens de acesso..."
    
    # Tokens do Consul
    log_info "Criando tokens do Consul..."
    
    # Token para agentes Consul
    consul acl token create \
        -description "Token for Consul agents" \
        -policy-name "agent-policy" > "${TOKENS_DIR}/consul-agent.token" 2>/dev/null || log_warn "Token consul-agent já existe"
    
    # Token para Nomad
    consul acl token create \
        -description "Token for Nomad integration" \
        -policy-name "nomad-policy" > "${TOKENS_DIR}/consul-nomad.token" 2>/dev/null || log_warn "Token consul-nomad já existe"
    
    # Token para operadores (leitura)
    consul acl token create \
        -description "Read-only token for operators" \
        -policy-name "operator-read-policy" > "${TOKENS_DIR}/consul-operator-read.token" 2>/dev/null || log_warn "Token consul-operator-read já existe"
    
    # Token para operadores (escrita)
    consul acl token create \
        -description "Write token for operators" \
        -policy-name "operator-write-policy" > "${TOKENS_DIR}/consul-operator-write.token" 2>/dev/null || log_warn "Token consul-operator-write já existe"
    
    # Tokens do Nomad
    log_info "Criando tokens do Nomad..."
    
    # Token para operadores (leitura)
    nomad acl token create \
        -name="operator-read-token" \
        -policy="operator-read" > "${TOKENS_DIR}/nomad-operator-read.token" 2>/dev/null || log_warn "Token nomad-operator-read já existe"
    
    # Token para operadores (escrita)
    nomad acl token create \
        -name="operator-write-token" \
        -policy="operator-write" > "${TOKENS_DIR}/nomad-operator-write.token" 2>/dev/null || log_warn "Token nomad-operator-write já existe"
    
    # Token para desenvolvedores
    nomad acl token create \
        -name="developer-token" \
        -policy="developer" > "${TOKENS_DIR}/nomad-developer.token" 2>/dev/null || log_warn "Token nomad-developer já existe"
    
    log_info "✅ Tokens criados"
}

# Função para configurar tokens nos serviços
configure_service_tokens() {
    log_info "Configurando tokens nos serviços..."
    
    # Configura token do Nomad no Consul
    if [[ -f "${TOKENS_DIR}/consul-nomad.token" ]]; then
        NOMAD_CONSUL_TOKEN=$(grep "SecretID" "${TOKENS_DIR}/consul-nomad.token" | awk '{print $2}')
        
        # Adiciona token ao arquivo de configuração do Nomad
        if ! grep -q "token =" "${NOMAD_CONFIG_DIR}/nomad.hcl"; then
            sed -i '/consul {/a\  token = "'"$NOMAD_CONSUL_TOKEN"'"' "${NOMAD_CONFIG_DIR}/nomad.hcl"
            log_info "Token do Consul adicionado ao Nomad"
        fi
    fi
    
    # Configura token do agente no Consul
    if [[ -f "${TOKENS_DIR}/consul-agent.token" ]]; then
        CONSUL_AGENT_TOKEN=$(grep "SecretID" "${TOKENS_DIR}/consul-agent.token" | awk '{print $2}')
        
        # Adiciona token ao arquivo de configuração do Consul
        if ! grep -q "default =" "${CONSUL_CONFIG_DIR}/consul.hcl"; then
            cat >> "${CONSUL_CONFIG_DIR}/consul.hcl" << EOF

# Token do agente
acl = {
  tokens = {
    default = "$CONSUL_AGENT_TOKEN"
  }
}
EOF
            log_info "Token do agente adicionado ao Consul"
        fi
    fi
}

# Função para gerar script de configuração de cliente
generate_client_config() {
    log_info "Gerando script de configuração para clientes..."
    
    cat > "${TOKENS_DIR}/setup-client.sh" << 'EOF'
#!/bin/bash
# Script para configurar cliente para acessar cluster seguro

# Configurações do Consul
export CONSUL_HTTP_SSL=true
export CONSUL_HTTP_ADDR="https://$(hostname -I | awk '{print $1}'):8501"
export CONSUL_CACERT="/etc/consul.d/certs/consul-agent-ca.pem"

# Configurações do Nomad
export NOMAD_ADDR="https://$(hostname -I | awk '{print $1}'):4646"
export NOMAD_CACERT="/etc/nomad.d/certs/nomad-ca.pem"

# Tokens (defina conforme necessário)
# export CONSUL_HTTP_TOKEN="seu-token-consul"
# export NOMAD_TOKEN="seu-token-nomad"

echo "Configurações de cliente aplicadas!"
echo "Para usar tokens, descomente e defina as variáveis CONSUL_HTTP_TOKEN e NOMAD_TOKEN"
EOF
    
    chmod +x "${TOKENS_DIR}/setup-client.sh"
    log_info "✅ Script de cliente criado: ${TOKENS_DIR}/setup-client.sh"
}

# Função para exibir resumo dos tokens
show_tokens_summary() {
    log_info "\n=== RESUMO DOS TOKENS CRIADOS ==="
    
    echo "Diretório dos tokens: $TOKENS_DIR"
    echo ""
    echo "CONSUL TOKENS:"
    echo "- Bootstrap: $(grep "SecretID" "${TOKENS_DIR}/consul-bootstrap.token" 2>/dev/null | awk '{print $2}' || echo 'N/A')"
    echo "- Agent: $(grep "SecretID" "${TOKENS_DIR}/consul-agent.token" 2>/dev/null | awk '{print $2}' || echo 'N/A')"
    echo "- Nomad Integration: $(grep "SecretID" "${TOKENS_DIR}/consul-nomad.token" 2>/dev/null | awk '{print $2}' || echo 'N/A')"
    echo "- Operator Read: $(grep "SecretID" "${TOKENS_DIR}/consul-operator-read.token" 2>/dev/null | awk '{print $2}' || echo 'N/A')"
    echo "- Operator Write: $(grep "SecretID" "${TOKENS_DIR}/consul-operator-write.token" 2>/dev/null | awk '{print $2}' || echo 'N/A')"
    echo ""
    echo "NOMAD TOKENS:"
    echo "- Bootstrap: $(grep "Secret ID" "${TOKENS_DIR}/nomad-bootstrap.token" 2>/dev/null | awk '{print $4}' || echo 'N/A')"
    echo "- Operator Read: $(grep "Secret ID" "${TOKENS_DIR}/nomad-operator-read.token" 2>/dev/null | awk '{print $4}' || echo 'N/A')"
    echo "- Operator Write: $(grep "Secret ID" "${TOKENS_DIR}/nomad-operator-write.token" 2>/dev/null | awk '{print $4}' || echo 'N/A')"
    echo "- Developer: $(grep "Secret ID" "${TOKENS_DIR}/nomad-developer.token" 2>/dev/null | awk '{print $4}' || echo 'N/A')"
    echo ""
    log_warn "IMPORTANTE: Guarde estes tokens em local seguro!"
    log_warn "IMPORTANTE: Distribua apenas os tokens necessários para cada usuário/serviço!"
}

# Função principal
main() {
    log_info "Configurando políticas ACL e tokens..."
    
    check_acl_status
    bootstrap_acls
    create_consul_policies
    create_nomad_policies
    create_tokens
    configure_service_tokens
    generate_client_config
    
    # Reinicia serviços para aplicar tokens
    log_info "Reiniciando serviços para aplicar tokens..."
    systemctl restart consul
    sleep 5
    systemctl restart nomad
    sleep 5
    
    show_tokens_summary
    
    log_info "✅ Configuração de ACLs e tokens concluída!"
}

# Executa apenas se chamado diretamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi