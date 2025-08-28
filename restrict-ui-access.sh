#!/usr/bin/env bash
# ==============================================================================
# Script para Restringir Acesso UI do Nomad e Consul a IP Específico
# ==============================================================================

# Importa funções comuns
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Verifica se está rodando como root
check_root

# Configurações
CONSUL_CONFIG_DIR="/etc/consul.d"
NOMAD_CONFIG_DIR="/etc/nomad.d"
BACKUP_DIR="/root/ui-access-backup-$(date +%Y%m%d-%H%M%S)"

# Função para detectar IP público do usuário
detect_user_ip() {
    local user_ip=""
    
    # Tenta detectar IP através de diferentes métodos
    log_info "Detectando seu IP público..."
    
    # Método 1: curl
    if command -v curl >/dev/null 2>&1; then
        user_ip=$(curl -s https://ipinfo.io/ip 2>/dev/null || curl -s https://api.ipify.org 2>/dev/null || curl -s https://checkip.amazonaws.com 2>/dev/null)
    fi
    
    # Método 2: wget como fallback
    if [[ -z "$user_ip" ]] && command -v wget >/dev/null 2>&1; then
        user_ip=$(wget -qO- https://ipinfo.io/ip 2>/dev/null || wget -qO- https://api.ipify.org 2>/dev/null)
    fi
    
    # Remove quebras de linha e espaços
    user_ip=$(echo "$user_ip" | tr -d '\n\r ' | head -1)
    
    # Valida se é um IP válido
    if [[ $user_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$user_ip"
    else
        echo ""
    fi
}

# Função para solicitar IP do usuário
get_user_ip() {
    local detected_ip=$(detect_user_ip)
    local user_ip=""
    
    if [[ -n "$detected_ip" ]]; then
        log_info "IP público detectado: $detected_ip"
        read -p "Este é seu IP correto? (s/n) [s]: " confirm
        confirm=${confirm:-s}
        
        if [[ "${confirm,,}" == "s" || "${confirm,,}" == "sim" ]]; then
            user_ip="$detected_ip"
        fi
    fi
    
    # Se não foi detectado ou usuário não confirmou, solicita manualmente
    if [[ -z "$user_ip" ]]; then
        echo ""
        log_info "Por favor, informe seu IP público."
        log_info "Você pode descobrir seu IP em: https://whatismyipaddress.com/"
        echo ""
        
        while [[ -z "$user_ip" ]]; do
            read -p "Digite seu IP público: " input_ip
            
            # Valida formato do IP
            if [[ $input_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                # Valida ranges válidos
                IFS='.' read -ra ADDR <<< "$input_ip"
                valid=true
                for i in "${ADDR[@]}"; do
                    if [[ $i -gt 255 ]]; then
                        valid=false
                        break
                    fi
                done
                
                if [[ "$valid" == "true" ]]; then
                    user_ip="$input_ip"
                else
                    log_error "IP inválido. Por favor, digite um IP válido."
                fi
            else
                log_error "Formato de IP inválido. Use o formato: xxx.xxx.xxx.xxx"
            fi
        done
    fi
    
    echo "$user_ip"
}

# Função para fazer backup das configurações
backup_configs() {
    log_info "Criando backup das configurações atuais..."
    
    mkdir -p "$BACKUP_DIR"
    
    if [[ -f "${CONSUL_CONFIG_DIR}/consul.hcl" ]]; then
        cp "${CONSUL_CONFIG_DIR}/consul.hcl" "${BACKUP_DIR}/consul.hcl.backup"
    fi
    
    if [[ -f "${NOMAD_CONFIG_DIR}/nomad.hcl" ]]; then
        cp "${NOMAD_CONFIG_DIR}/nomad.hcl" "${BACKUP_DIR}/nomad.hcl.backup"
    fi
    
    # Backup das regras de firewall atuais
    ufw status numbered > "${BACKUP_DIR}/ufw-rules.backup" 2>/dev/null || true
    
    log_info "Backup criado em: $BACKUP_DIR"
}

# Função para configurar firewall para UI restrita
setup_restricted_firewall() {
    local user_ip="$1"
    
    log_info "Configurando firewall para restringir acesso UI..."
    
    # Remove regras existentes para as portas UI se existirem
    log_info "Removendo regras existentes para portas UI..."
    
    # Remove regras específicas das portas UI (pode gerar erros se não existirem, mas é normal)
    ufw --force delete allow 8500 2>/dev/null || true
    ufw --force delete allow 8501 2>/dev/null || true
    ufw --force delete allow 4646 2>/dev/null || true
    
    # Remove regras que permitem acesso geral às portas UI
    ufw status numbered | grep -E '(8500|8501|4646)' | awk '{print $1}' | sed 's/\[//g' | sed 's/\]//g' | sort -nr | while read rule_num; do
        if [[ -n "$rule_num" && "$rule_num" =~ ^[0-9]+$ ]]; then
            ufw --force delete "$rule_num" 2>/dev/null || true
        fi
    done
    
    # Adiciona regras específicas para o IP do usuário
    log_info "Adicionando regras para seu IP: $user_ip"
    
    # Consul UI (HTTP e HTTPS)
    ufw allow from "$user_ip" to any port 8500 comment "Consul HTTP UI - User IP"
    ufw allow from "$user_ip" to any port 8501 comment "Consul HTTPS UI - User IP"
    
    # Nomad UI
    ufw allow from "$user_ip" to any port 4646 comment "Nomad UI - User IP"
    
    # Permite acesso local (localhost)
    ufw allow from 127.0.0.1 to any port 8500 comment "Consul HTTP UI - Localhost"
    ufw allow from 127.0.0.1 to any port 8501 comment "Consul HTTPS UI - Localhost"
    ufw allow from 127.0.0.1 to any port 4646 comment "Nomad UI - Localhost"
    
    # Recarrega firewall
    ufw reload
    
    log_info "✅ Firewall configurado para restringir UI ao IP: $user_ip"
}

# Função para configurar client_addr do Consul
setup_consul_client_addr() {
    local user_ip="$1"
    local server_ip=$(hostname -I | awk '{print $1}')
    
    log_info "Configurando client_addr do Consul..."
    
    # Remove configuração client_addr existente
    sed -i '/^client_addr/d' "${CONSUL_CONFIG_DIR}/consul.hcl"
    
    # Adiciona nova configuração client_addr restrita
    # Permite localhost, IP do servidor e IP do usuário
    local client_addr="127.0.0.1 ${server_ip} ${user_ip}"
    
    # Adiciona a configuração após a linha datacenter
    sed -i "/^datacenter/a client_addr = \"${client_addr}\"" "${CONSUL_CONFIG_DIR}/consul.hcl"
    
    log_info "✅ Consul configurado para aceitar conexões de: $client_addr"
}

# Função para configurar bind_addr do Nomad (se necessário)
setup_nomad_addresses() {
    local user_ip="$1"
    local server_ip=$(hostname -I | awk '{print $1}')
    
    log_info "Verificando configuração de endereços do Nomad..."
    
    # O Nomad por padrão escuta em todas as interfaces quando bind_addr = "0.0.0.0"
    # Mas podemos adicionar configurações específicas se necessário
    
    # Verifica se há configuração específica de addresses
    if ! grep -q "addresses {" "${NOMAD_CONFIG_DIR}/nomad.hcl"; then
        log_info "Adicionando configuração de endereços ao Nomad..."
        
        # Adiciona configuração de addresses após bind_addr
        sed -i "/^bind_addr/a \\naddresses {\\n  http = \"${server_ip}\"\\n  rpc  = \"${server_ip}\"\\n  serf = \"${server_ip}\"\\n}" "${NOMAD_CONFIG_DIR}/nomad.hcl"
    fi
    
    log_info "✅ Configuração de endereços do Nomad verificada"
}

# Função para criar configuração de proxy reverso (opcional)
create_nginx_config() {
    local user_ip="$1"
    local server_ip=$(hostname -I | awk '{print $1}')
    
    log_info "Criando configuração de exemplo para proxy reverso..."
    
    mkdir -p "${BACKUP_DIR}/nginx-configs"
    
    # Configuração Nginx para Consul
    cat > "${BACKUP_DIR}/nginx-configs/consul-ui.conf" << EOF
# Configuração Nginx para Consul UI
# Copie para /etc/nginx/sites-available/ e ative com nginx

server {
    listen 80;
    server_name consul.$(hostname -f);
    
    # Redireciona HTTP para HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name consul.$(hostname -f);
    
    # Configurações SSL (configure seus certificados)
    # ssl_certificate /path/to/your/cert.pem;
    # ssl_certificate_key /path/to/your/key.pem;
    
    # Restringe acesso por IP
    allow ${user_ip};
    allow 127.0.0.1;
    deny all;
    
    location / {
        proxy_pass http://127.0.0.1:8500;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    
    # Configuração Nginx para Nomad
    cat > "${BACKUP_DIR}/nginx-configs/nomad-ui.conf" << EOF
# Configuração Nginx para Nomad UI
# Copie para /etc/nginx/sites-available/ e ative com nginx

server {
    listen 80;
    server_name nomad.$(hostname -f);
    
    # Redireciona HTTP para HTTPS
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name nomad.$(hostname -f);
    
    # Configurações SSL (configure seus certificados)
    # ssl_certificate /path/to/your/cert.pem;
    # ssl_certificate_key /path/to/your/key.pem;
    
    # Restringe acesso por IP
    allow ${user_ip};
    allow 127.0.0.1;
    deny all;
    
    location / {
        proxy_pass http://127.0.0.1:4646;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support para Nomad UI
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
    }
}
EOF
    
    log_info "✅ Configurações de proxy reverso criadas em: ${BACKUP_DIR}/nginx-configs/"
}

# Função para reiniciar serviços
restart_services() {
    log_info "Reiniciando serviços..."
    
    systemctl restart consul
    sleep 3
    systemctl restart nomad
    sleep 3
    
    # Verifica status
    if systemctl is-active --quiet consul; then
        log_info "✅ Consul reiniciado com sucesso"
    else
        log_error "❌ Erro ao reiniciar Consul"
    fi
    
    if systemctl is-active --quiet nomad; then
        log_info "✅ Nomad reiniciado com sucesso"
    else
        log_error "❌ Erro ao reiniciar Nomad"
    fi
}

# Função para testar acesso
test_ui_access() {
    local user_ip="$1"
    local server_ip=$(hostname -I | awk '{print $1}')
    
    log_info "Testando acesso às UIs..."
    
    # Testa Consul
    if curl -s "http://${server_ip}:8500/ui/" >/dev/null 2>&1; then
        log_info "✅ Consul UI acessível em: http://${server_ip}:8500/ui/"
    else
        log_warn "⚠️  Consul UI pode não estar acessível (normal se ACLs estão ativos)"
    fi
    
    # Testa Nomad
    if curl -s "http://${server_ip}:4646/ui/" >/dev/null 2>&1; then
        log_info "✅ Nomad UI acessível em: http://${server_ip}:4646/ui/"
    else
        log_warn "⚠️  Nomad UI pode não estar acessível (normal se ACLs estão ativos)"
    fi
}

# Função para exibir instruções finais
show_final_instructions() {
    local user_ip="$1"
    local server_ip=$(hostname -I | awk '{print $1}')
    
    echo ""
    log_info "=== CONFIGURAÇÃO CONCLUÍDA ==="
    echo ""
    echo "🔒 Acesso UI restrito ao IP: $user_ip"
    echo ""
    echo "📱 URLs de Acesso:"
    echo "   Consul UI: http://${server_ip}:8500/ui/"
    echo "   Consul UI (HTTPS): https://${server_ip}:8501/ui/"
    echo "   Nomad UI:  http://${server_ip}:4646/ui/"
    echo ""
    echo "🔧 Configurações Aplicadas:"
    echo "   ✅ Firewall configurado para seu IP"
    echo "   ✅ Consul client_addr restrito"
    echo "   ✅ Configurações de endereço do Nomad verificadas"
    echo ""
    echo "📋 Regras de Firewall Ativas:"
    ufw status | grep -E '(8500|8501|4646)'
    echo ""
    echo "💾 Backup criado em: $BACKUP_DIR"
    echo ""
    echo "🔄 Para reverter as mudanças:"
    echo "   sudo cp ${BACKUP_DIR}/consul.hcl.backup ${CONSUL_CONFIG_DIR}/consul.hcl"
    echo "   sudo cp ${BACKUP_DIR}/nomad.hcl.backup ${NOMAD_CONFIG_DIR}/nomad.hcl"
    echo "   # Restaurar regras de firewall manualmente"
    echo ""
    echo "⚠️  IMPORTANTE:"
    echo "   - Apenas seu IP ($user_ip) pode acessar as UIs"
    echo "   - Acesso local (127.0.0.1) também é permitido"
    echo "   - Se seu IP mudar, execute este script novamente"
    echo "   - Para permitir outros IPs, use: ufw allow from IP to any port 8500,8501,4646"
    echo ""
    
    if [[ -f "${BACKUP_DIR}/nginx-configs/consul-ui.conf" ]]; then
        echo "🌐 Configurações de proxy reverso disponíveis em:"
        echo "   ${BACKUP_DIR}/nginx-configs/"
        echo ""
    fi
}

# Função para adicionar IP adicional
add_additional_ip() {
    echo ""
    read -p "Deseja permitir acesso de outro IP? (s/n) [n]: " add_ip
    add_ip=${add_ip:-n}
    
    if [[ "${add_ip,,}" == "s" || "${add_ip,,}" == "sim" ]]; then
        read -p "Digite o IP adicional: " additional_ip
        
        # Valida IP
        if [[ $additional_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            log_info "Adicionando regras para IP adicional: $additional_ip"
            
            ufw allow from "$additional_ip" to any port 8500 comment "Consul HTTP UI - Additional IP"
            ufw allow from "$additional_ip" to any port 8501 comment "Consul HTTPS UI - Additional IP"
            ufw allow from "$additional_ip" to any port 4646 comment "Nomad UI - Additional IP"
            
            # Atualiza client_addr do Consul
            local current_client_addr=$(grep "client_addr" "${CONSUL_CONFIG_DIR}/consul.hcl" | cut -d'"' -f2)
            local new_client_addr="${current_client_addr} ${additional_ip}"
            sed -i "s/client_addr = \".*\"/client_addr = \"${new_client_addr}\"/" "${CONSUL_CONFIG_DIR}/consul.hcl"
            
            log_info "✅ IP adicional configurado: $additional_ip"
        else
            log_error "IP inválido: $additional_ip"
        fi
    fi
}

# Função principal
main() {
    echo "🔒 RESTRIÇÃO DE ACESSO UI - NOMAD E CONSUL"
    echo "==========================================="
    echo ""
    
    # Verifica se os serviços estão instalados
    if ! command -v consul >/dev/null 2>&1; then
        log_error "Consul não está instalado. Execute o script de instalação primeiro."
        exit 1
    fi
    
    if ! command -v nomad >/dev/null 2>&1; then
        log_error "Nomad não está instalado. Execute o script de instalação primeiro."
        exit 1
    fi
    
    # Obtém IP do usuário
    local user_ip=$(get_user_ip)
    
    if [[ -z "$user_ip" ]]; then
        log_error "Não foi possível obter o IP do usuário."
        exit 1
    fi
    
    log_info "Configurando acesso restrito para o IP: $user_ip"
    echo ""
    
    # Executa configurações
    backup_configs
    setup_restricted_firewall "$user_ip"
    setup_consul_client_addr "$user_ip"
    setup_nomad_addresses "$user_ip"
    create_nginx_config "$user_ip"
    
    # Pergunta sobre IP adicional
    add_additional_ip
    
    # Reinicia serviços
    restart_services
    
    # Testa acesso
    test_ui_access "$user_ip"
    
    # Exibe instruções finais
    show_final_instructions "$user_ip"
    
    log_info "✅ Configuração de acesso restrito concluída!"
}

# Executa apenas se chamado diretamente
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi