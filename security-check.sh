#!/usr/bin/env bash
# ==============================================================================
# Script de Verificação de Segurança para Nomad e Consul
# ==============================================================================

# Importa funções comuns
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Contadores
PASSED=0
FAILED=0
WARNINGS=0

# Função para imprimir resultado de teste
print_result() {
    local test_name="$1"
    local status="$2"
    local message="$3"
    
    case "$status" in
        "PASS")
            echo -e "[${GREEN}✓${NC}] $test_name: $message"
            ((PASSED++))
            ;;
        "FAIL")
            echo -e "[${RED}✗${NC}] $test_name: $message"
            ((FAILED++))
            ;;
        "WARN")
            echo -e "[${YELLOW}!${NC}] $test_name: $message"
            ((WARNINGS++))
            ;;
        "INFO")
            echo -e "[${BLUE}i${NC}] $test_name: $message"
            ;;
    esac
}

# Função para verificar se serviços estão rodando
check_services_running() {
    echo -e "\n${BLUE}=== VERIFICAÇÃO DE SERVIÇOS ===${NC}"
    
    if systemctl is-active --quiet consul; then
        print_result "Consul Service" "PASS" "Serviço está rodando"
    else
        print_result "Consul Service" "FAIL" "Serviço não está rodando"
        return 1
    fi
    
    if systemctl is-active --quiet nomad; then
        print_result "Nomad Service" "PASS" "Serviço está rodando"
    else
        print_result "Nomad Service" "FAIL" "Serviço não está rodando"
        return 1
    fi
}

# Função para verificar configurações TLS
check_tls_config() {
    echo -e "\n${BLUE}=== VERIFICAÇÃO TLS ===${NC}"
    
    # Consul TLS
    if grep -q "tls {" /etc/consul.d/consul.hcl 2>/dev/null; then
        print_result "Consul TLS Config" "PASS" "Configuração TLS encontrada"
        
        # Verifica certificados
        if [[ -f "/etc/consul.d/certs/consul-agent-ca.pem" ]]; then
            print_result "Consul CA Certificate" "PASS" "Certificado CA encontrado"
        else
            print_result "Consul CA Certificate" "FAIL" "Certificado CA não encontrado"
        fi
        
        if [[ -f "/etc/consul.d/certs/dc1-server-consul-0.pem" ]]; then
            print_result "Consul Server Certificate" "PASS" "Certificado do servidor encontrado"
        else
            print_result "Consul Server Certificate" "FAIL" "Certificado do servidor não encontrado"
        fi
        
        # Verifica se HTTP está desabilitado
        if grep -q "http = -1" /etc/consul.d/consul.hcl 2>/dev/null; then
            print_result "Consul HTTP Disabled" "PASS" "HTTP não criptografado desabilitado"
        else
            print_result "Consul HTTP Disabled" "WARN" "HTTP não criptografado ainda habilitado"
        fi
    else
        print_result "Consul TLS Config" "FAIL" "Configuração TLS não encontrada"
    fi
    
    # Nomad TLS
    if grep -q "tls {" /etc/nomad.d/nomad.hcl 2>/dev/null; then
        print_result "Nomad TLS Config" "PASS" "Configuração TLS encontrada"
        
        # Verifica certificados
        if [[ -f "/etc/nomad.d/certs/nomad-ca.pem" ]]; then
            print_result "Nomad CA Certificate" "PASS" "Certificado CA encontrado"
        else
            print_result "Nomad CA Certificate" "FAIL" "Certificado CA não encontrado"
        fi
        
        if [[ -f "/etc/nomad.d/certs/server.pem" ]]; then
            print_result "Nomad Server Certificate" "PASS" "Certificado do servidor encontrado"
        else
            print_result "Nomad Server Certificate" "FAIL" "Certificado do servidor não encontrado"
        fi
    else
        print_result "Nomad TLS Config" "FAIL" "Configuração TLS não encontrada"
    fi
}

# Função para verificar ACLs
check_acl_config() {
    echo -e "\n${BLUE}=== VERIFICAÇÃO ACLs ===${NC}"
    
    # Consul ACLs
    if grep -q "acl = {" /etc/consul.d/consul.hcl 2>/dev/null; then
        print_result "Consul ACL Config" "PASS" "Configuração ACL encontrada"
        
        if grep -q "enabled = true" /etc/consul.d/consul.hcl 2>/dev/null; then
            print_result "Consul ACL Enabled" "PASS" "ACLs habilitados"
        else
            print_result "Consul ACL Enabled" "FAIL" "ACLs não habilitados"
        fi
        
        if grep -q "default_policy = \"deny\"" /etc/consul.d/consul.hcl 2>/dev/null; then
            print_result "Consul Default Policy" "PASS" "Política padrão é 'deny'"
        else
            print_result "Consul Default Policy" "WARN" "Política padrão não é 'deny'"
        fi
    else
        print_result "Consul ACL Config" "FAIL" "Configuração ACL não encontrada"
    fi
    
    # Nomad ACLs
    if grep -q "acl {" /etc/nomad.d/nomad.hcl 2>/dev/null; then
        print_result "Nomad ACL Config" "PASS" "Configuração ACL encontrada"
        
        if grep -q "enabled = true" /etc/nomad.d/nomad.hcl 2>/dev/null; then
            print_result "Nomad ACL Enabled" "PASS" "ACLs habilitados"
        else
            print_result "Nomad ACL Enabled" "FAIL" "ACLs não habilitados"
        fi
    else
        print_result "Nomad ACL Config" "FAIL" "Configuração ACL não encontrada"
    fi
}

# Função para verificar criptografia Gossip
check_gossip_encryption() {
    echo -e "\n${BLUE}=== VERIFICAÇÃO GOSSIP ENCRYPTION ===${NC}"
    
    if grep -q "encrypt =" /etc/consul.d/consul.hcl 2>/dev/null; then
        local encrypt_key=$(grep "encrypt =" /etc/consul.d/consul.hcl | cut -d'"' -f2)
        if [[ -n "$encrypt_key" && "$encrypt_key" != "GENERATE_AFTER_INSTALL" ]]; then
            print_result "Consul Gossip Encryption" "PASS" "Chave de criptografia configurada"
        else
            print_result "Consul Gossip Encryption" "FAIL" "Chave de criptografia não configurada"
        fi
    else
        print_result "Consul Gossip Encryption" "FAIL" "Criptografia Gossip não configurada"
    fi
}

# Função para verificar firewall
check_firewall() {
    echo -e "\n${BLUE}=== VERIFICAÇÃO FIREWALL ===${NC}"
    
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            print_result "UFW Firewall" "PASS" "Firewall está ativo"
            
            # Verifica regras específicas
            if ufw status | grep -q "8300\|8301\|8500\|8501"; then
                print_result "Consul Firewall Rules" "PASS" "Regras do Consul encontradas"
            else
                print_result "Consul Firewall Rules" "WARN" "Regras específicas do Consul não encontradas"
            fi
            
            if ufw status | grep -q "4646\|4647\|4648"; then
                print_result "Nomad Firewall Rules" "PASS" "Regras do Nomad encontradas"
            else
                print_result "Nomad Firewall Rules" "WARN" "Regras específicas do Nomad não encontradas"
            fi
        else
            print_result "UFW Firewall" "WARN" "Firewall não está ativo"
        fi
    else
        print_result "UFW Firewall" "WARN" "UFW não está instalado"
    fi
}

# Função para verificar permissões de arquivos
check_file_permissions() {
    echo -e "\n${BLUE}=== VERIFICAÇÃO PERMISSÕES ===${NC}"
    
    # Consul
    if [[ -f "/etc/consul.d/consul.hcl" ]]; then
        local consul_perms=$(stat -c "%a" /etc/consul.d/consul.hcl)
        if [[ "$consul_perms" == "600" || "$consul_perms" == "640" ]]; then
            print_result "Consul Config Permissions" "PASS" "Permissões seguras ($consul_perms)"
        else
            print_result "Consul Config Permissions" "WARN" "Permissões podem ser inseguras ($consul_perms)"
        fi
    fi
    
    # Nomad
    if [[ -f "/etc/nomad.d/nomad.hcl" ]]; then
        local nomad_perms=$(stat -c "%a" /etc/nomad.d/nomad.hcl)
        if [[ "$nomad_perms" == "600" || "$nomad_perms" == "640" ]]; then
            print_result "Nomad Config Permissions" "PASS" "Permissões seguras ($nomad_perms)"
        else
            print_result "Nomad Config Permissions" "WARN" "Permissões podem ser inseguras ($nomad_perms)"
        fi
    fi
    
    # Certificados
    if [[ -d "/etc/consul.d/certs" ]]; then
        local cert_dir_perms=$(stat -c "%a" /etc/consul.d/certs)
        if [[ "$cert_dir_perms" == "750" ]]; then
            print_result "Consul Certs Directory" "PASS" "Permissões seguras ($cert_dir_perms)"
        else
            print_result "Consul Certs Directory" "WARN" "Permissões podem ser inseguras ($cert_dir_perms)"
        fi
    fi
    
    if [[ -d "/etc/nomad.d/certs" ]]; then
        local cert_dir_perms=$(stat -c "%a" /etc/nomad.d/certs)
        if [[ "$cert_dir_perms" == "750" ]]; then
            print_result "Nomad Certs Directory" "PASS" "Permissões seguras ($cert_dir_perms)"
        else
            print_result "Nomad Certs Directory" "WARN" "Permissões podem ser inseguras ($cert_dir_perms)"
        fi
    fi
}

# Função para verificar logs de auditoria
check_audit_logs() {
    echo -e "\n${BLUE}=== VERIFICAÇÃO LOGS DE AUDITORIA ===${NC}"
    
    # Consul logs
    if grep -q "log_file" /etc/consul.d/consul.hcl 2>/dev/null; then
        print_result "Consul Audit Logs" "PASS" "Configuração de logs encontrada"
        
        if [[ -d "/var/log/consul" ]]; then
            print_result "Consul Log Directory" "PASS" "Diretório de logs existe"
        else
            print_result "Consul Log Directory" "WARN" "Diretório de logs não existe"
        fi
    else
        print_result "Consul Audit Logs" "WARN" "Configuração de logs não encontrada"
    fi
    
    # Nomad logs
    if grep -q "log_file" /etc/nomad.d/nomad.hcl 2>/dev/null; then
        print_result "Nomad Audit Logs" "PASS" "Configuração de logs encontrada"
        
        if [[ -d "/var/log/nomad" ]]; then
            print_result "Nomad Log Directory" "PASS" "Diretório de logs existe"
        else
            print_result "Nomad Log Directory" "WARN" "Diretório de logs não existe"
        fi
    else
        print_result "Nomad Audit Logs" "WARN" "Configuração de logs não encontrada"
    fi
}

# Função para verificar conectividade segura
check_secure_connectivity() {
    echo -e "\n${BLUE}=== VERIFICAÇÃO CONECTIVIDADE SEGURA ===${NC}"
    
    # Testa HTTPS Consul
    local consul_ip=$(hostname -I | awk '{print $1}')
    if curl -k -s "https://${consul_ip}:8501/v1/status/leader" >/dev/null 2>&1; then
        print_result "Consul HTTPS" "PASS" "Endpoint HTTPS acessível"
    else
        print_result "Consul HTTPS" "WARN" "Endpoint HTTPS não acessível (pode ser normal se ACLs estão ativos)"
    fi
    
    # Testa HTTPS Nomad
    if curl -k -s "https://${consul_ip}:4646/v1/status/leader" >/dev/null 2>&1; then
        print_result "Nomad HTTPS" "PASS" "Endpoint HTTPS acessível"
    else
        print_result "Nomad HTTPS" "WARN" "Endpoint HTTPS não acessível (pode ser normal se ACLs estão ativos)"
    fi
    
    # Verifica se HTTP está desabilitado
    if curl -s "http://${consul_ip}:8500/v1/status/leader" >/dev/null 2>&1; then
        print_result "Consul HTTP Disabled" "FAIL" "HTTP ainda está acessível (inseguro)"
    else
        print_result "Consul HTTP Disabled" "PASS" "HTTP não está acessível (seguro)"
    fi
}

# Função para verificar tokens
check_tokens() {
    echo -e "\n${BLUE}=== VERIFICAÇÃO TOKENS ===${NC}"
    
    if [[ -d "/root/cluster-tokens" ]]; then
        print_result "Tokens Directory" "PASS" "Diretório de tokens existe"
        
        local token_count=$(ls -1 /root/cluster-tokens/*.token 2>/dev/null | wc -l)
        if [[ $token_count -gt 0 ]]; then
            print_result "Token Files" "PASS" "$token_count arquivos de token encontrados"
        else
            print_result "Token Files" "WARN" "Nenhum arquivo de token encontrado"
        fi
        
        # Verifica permissões do diretório
        local tokens_perms=$(stat -c "%a" /root/cluster-tokens)
        if [[ "$tokens_perms" == "700" ]]; then
            print_result "Tokens Directory Permissions" "PASS" "Permissões seguras ($tokens_perms)"
        else
            print_result "Tokens Directory Permissions" "WARN" "Permissões podem ser inseguras ($tokens_perms)"
        fi
    else
        print_result "Tokens Directory" "WARN" "Diretório de tokens não existe"
    fi
}

# Função para verificar configurações de rede
check_network_config() {
    echo -e "\n${BLUE}=== VERIFICAÇÃO CONFIGURAÇÕES DE REDE ===${NC}"
    
    # Verifica bind_addr
    local consul_bind=$(grep "bind_addr" /etc/consul.d/consul.hcl 2>/dev/null | cut -d'"' -f2)
    if [[ "$consul_bind" == "0.0.0.0" ]]; then
        print_result "Consul Bind Address" "WARN" "Bind em todas as interfaces (0.0.0.0)"
    elif [[ -n "$consul_bind" ]]; then
        print_result "Consul Bind Address" "PASS" "Bind específico: $consul_bind"
    fi
    
    local nomad_bind=$(grep "bind_addr" /etc/nomad.d/nomad.hcl 2>/dev/null | cut -d'"' -f2)
    if [[ "$nomad_bind" == "0.0.0.0" ]]; then
        print_result "Nomad Bind Address" "WARN" "Bind em todas as interfaces (0.0.0.0)"
    elif [[ -n "$nomad_bind" ]]; then
        print_result "Nomad Bind Address" "PASS" "Bind específico: $nomad_bind"
    fi
    
    # Verifica client_addr
    local consul_client=$(grep "client_addr" /etc/consul.d/consul.hcl 2>/dev/null | cut -d'"' -f2)
    if [[ "$consul_client" == "0.0.0.0" ]]; then
        print_result "Consul Client Address" "WARN" "Cliente em todas as interfaces (0.0.0.0)"
    elif [[ -n "$consul_client" ]]; then
        print_result "Consul Client Address" "PASS" "Cliente específico: $consul_client"
    fi
}

# Função para verificar UI
check_ui_security() {
    echo -e "\n${BLUE}=== VERIFICAÇÃO SEGURANÇA UI ===${NC}"
    
    # Consul UI
    if grep -q "ui_config { enabled = true }" /etc/consul.d/consul.hcl 2>/dev/null; then
        print_result "Consul UI" "WARN" "UI está habilitada (considere desabilitar em produção)"
    elif grep -q "ui_config { enabled = false }" /etc/consul.d/consul.hcl 2>/dev/null; then
        print_result "Consul UI" "PASS" "UI está desabilitada"
    else
        print_result "Consul UI" "INFO" "Configuração UI não encontrada"
    fi
}

# Função para gerar relatório final
generate_report() {
    echo -e "\n${BLUE}=== RELATÓRIO FINAL ===${NC}"
    
    local total=$((PASSED + FAILED + WARNINGS))
    
    echo -e "Total de verificações: $total"
    echo -e "${GREEN}Passou: $PASSED${NC}"
    echo -e "${RED}Falhou: $FAILED${NC}"
    echo -e "${YELLOW}Avisos: $WARNINGS${NC}"
    
    if [[ $FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}✅ Configuração de segurança está em bom estado!${NC}"
        if [[ $WARNINGS -gt 0 ]]; then
            echo -e "${YELLOW}⚠️  Considere revisar os avisos para melhorar a segurança.${NC}"
        fi
    else
        echo -e "\n${RED}❌ Problemas de segurança encontrados!${NC}"
        echo -e "${RED}Por favor, corrija os itens que falharam antes de usar em produção.${NC}"
    fi
    
    # Recomendações
    echo -e "\n${BLUE}=== RECOMENDAÇÕES ===${NC}"
    
    if [[ $FAILED -gt 0 ]]; then
        echo "1. Execute o script security-hardening.sh para corrigir problemas básicos"
        echo "2. Execute o script setup-acl-policies.sh para configurar ACLs"
    fi
    
    if [[ $WARNINGS -gt 0 ]]; then
        echo "3. Revise as configurações que geraram avisos"
        echo "4. Considere restringir bind_addr e client_addr para IPs específicos"
        echo "5. Desabilite a UI em ambiente de produção"
    fi
    
    echo "6. Monitore logs regularmente: /var/log/consul/ e /var/log/nomad/"
    echo "7. Rotacione chaves e certificados periodicamente"
    echo "8. Mantenha backups atualizados dos tokens e configurações"
}

# Função principal
main() {
    echo -e "${BLUE}🔐 VERIFICAÇÃO DE SEGURANÇA DO CLUSTER NOMAD/CONSUL${NC}"
    echo -e "${BLUE}=================================================${NC}"
    
    check_services_running || {
        echo -e "\n${RED}❌ Serviços não estão rodando. Verifique a instalação.${NC}"
        exit 1
    }
    
    check_tls_config
    check_acl_config
    check_gossip_encryption
    check_firewall
    check_file_permissions
    check_audit_logs
    check_secure_connectivity
    check_tokens
    check_network_config
    check_ui_security
    
    generate_report
}

# Executa apenas se chamado diretamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi