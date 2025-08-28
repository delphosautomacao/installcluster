#!/usr/bin/env bash
# ==============================================================================
# Script Rápido para Restringir UI do Nomad/Consul a um IP Específico
# ==============================================================================

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para log
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Verifica se é root
if [[ $EUID -ne 0 ]]; then
   log_error "Este script deve ser executado como root (sudo)"
   exit 1
fi

# Detecta IP público automaticamente
detect_ip() {
    local ip=""
    
    log_info "Detectando seu IP público..."
    
    # Tenta vários serviços
    for service in "https://ipinfo.io/ip" "https://api.ipify.org" "https://checkip.amazonaws.com" "https://icanhazip.com"; do
        ip=$(curl -s --connect-timeout 5 "$service" 2>/dev/null | tr -d '\n\r ')
        if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    return 1
}

# Função principal
main() {
    echo "🔒 RESTRIÇÃO RÁPIDA DE ACESSO UI"
    echo "================================"
    echo ""
    
    # Detecta ou solicita IP
    USER_IP=$(detect_ip)
    
    if [[ -n "$USER_IP" ]]; then
        log_success "IP detectado: $USER_IP"
        read -p "Confirma este IP? (s/n) [s]: " confirm
        confirm=${confirm:-s}
        
        if [[ "${confirm,,}" != "s" ]]; then
            USER_IP=""
        fi
    fi
    
    # Se não detectou ou usuário não confirmou
    if [[ -z "$USER_IP" ]]; then
        echo ""
        log_info "Digite seu IP público (descubra em: https://whatismyipaddress.com/)"
        read -p "IP: " USER_IP
        
        # Valida IP
        if [[ ! $USER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            log_error "IP inválido: $USER_IP"
            exit 1
        fi
    fi
    
    echo ""
    log_info "Configurando acesso restrito para: $USER_IP"
    echo ""
    
    # 1. Configura Firewall
    log_info "[1/4] Configurando firewall..."
    
    # Remove regras existentes das portas UI
    ufw --force delete allow 8500 2>/dev/null || true
    ufw --force delete allow 8501 2>/dev/null || true
    ufw --force delete allow 4646 2>/dev/null || true
    
    # Adiciona regras específicas
    ufw allow from "$USER_IP" to any port 8500 comment "Consul UI - Authorized IP"
    ufw allow from "$USER_IP" to any port 8501 comment "Consul UI HTTPS - Authorized IP"
    ufw allow from "$USER_IP" to any port 4646 comment "Nomad UI - Authorized IP"
    
    # Permite localhost
    ufw allow from 127.0.0.1 to any port 8500,8501,4646 comment "UI - Localhost"
    
    ufw reload
    log_success "Firewall configurado"
    
    # 2. Configura Consul client_addr
    log_info "[2/4] Configurando Consul..."
    
    CONSUL_CONFIG="/etc/consul.d/consul.hcl"
    if [[ -f "$CONSUL_CONFIG" ]]; then
        # Backup
        cp "$CONSUL_CONFIG" "${CONSUL_CONFIG}.backup-$(date +%Y%m%d-%H%M%S)"
        
        # Remove client_addr existente
        sed -i '/^client_addr/d' "$CONSUL_CONFIG"
        
        # Adiciona nova configuração
        SERVER_IP=$(hostname -I | awk '{print $1}')
        CLIENT_ADDR="127.0.0.1 ${SERVER_IP} ${USER_IP}"
        
        # Adiciona após datacenter
        sed -i "/^datacenter/a client_addr = \"${CLIENT_ADDR}\"" "$CONSUL_CONFIG"
        
        log_success "Consul configurado para IPs: $CLIENT_ADDR"
    else
        log_warn "Arquivo de configuração do Consul não encontrado"
    fi
    
    # 3. Verifica Nomad (geralmente não precisa alteração)
    log_info "[3/4] Verificando Nomad..."
    log_success "Nomad configurado (usando bind_addr padrão)"
    
    # 4. Reinicia serviços
    log_info "[4/4] Reiniciando serviços..."
    
    systemctl restart consul 2>/dev/null && log_success "Consul reiniciado" || log_warn "Erro ao reiniciar Consul"
    sleep 2
    systemctl restart nomad 2>/dev/null && log_success "Nomad reiniciado" || log_warn "Erro ao reiniciar Nomad"
    sleep 2
    
    # Resultado final
    echo ""
    echo "🎉 CONFIGURAÇÃO CONCLUÍDA!"
    echo "========================="
    echo ""
    echo "🔒 Acesso UI restrito ao IP: $USER_IP"
    echo ""
    echo "📱 URLs de Acesso:"
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo "   Consul: http://${SERVER_IP}:8500/ui/"
    echo "   Nomad:  http://${SERVER_IP}:4646/ui/"
    echo ""
    echo "🔧 Regras de Firewall Ativas:"
    ufw status | grep -E '(8500|8501|4646)' | head -10
    echo ""
    echo "⚠️  IMPORTANTE:"
    echo "   • Apenas seu IP ($USER_IP) pode acessar as UIs"
    echo "   • Se seu IP mudar, execute este script novamente"
    echo "   • Para adicionar outro IP: ufw allow from NOVO_IP to any port 8500,8501,4646"
    echo ""
    
    # Pergunta sobre IP adicional
    read -p "Deseja adicionar outro IP autorizado? (s/n) [n]: " add_more
    if [[ "${add_more,,}" == "s" ]]; then
        read -p "Digite o IP adicional: " EXTRA_IP
        if [[ $EXTRA_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            ufw allow from "$EXTRA_IP" to any port 8500,8501,4646 comment "UI - Additional IP"
            
            # Atualiza Consul client_addr
            if [[ -f "$CONSUL_CONFIG" ]]; then
                sed -i "s/client_addr = \".*\"/client_addr = \"${CLIENT_ADDR} ${EXTRA_IP}\"/" "$CONSUL_CONFIG"
                systemctl restart consul
            fi
            
            log_success "IP adicional configurado: $EXTRA_IP"
        else
            log_error "IP inválido: $EXTRA_IP"
        fi
    fi
    
    echo ""
    log_success "✅ Configuração finalizada! Teste o acesso às UIs."
}

# Executa
main "$@"