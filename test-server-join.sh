#!/usr/bin/env bash
# ==============================================================================
# Script de Teste para Verificar Configuração server_join do Nomad
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

echo "🧪 TESTE DE CONFIGURAÇÃO SERVER_JOIN DO NOMAD"
echo "============================================="
echo ""

# Simula variáveis de ambiente
export NOMAD_BOOTSTRAP_EXPECT=3
export NOMAD_RETRY_JOIN_ARRAY='"10.0.1.10", "10.0.1.11", "10.0.1.12"'
export BIND_IP="10.0.1.10"
export REGION="global"
export DC="dc1"
export NODE_NAME="nomad-server-1"
export DATA_DIR="/opt/nomad/data"

log_info "Variáveis de teste configuradas:"
echo "  NOMAD_BOOTSTRAP_EXPECT: $NOMAD_BOOTSTRAP_EXPECT"
echo "  NOMAD_RETRY_JOIN_ARRAY: $NOMAD_RETRY_JOIN_ARRAY"
echo "  BIND_IP: $BIND_IP"
echo ""

# Cria arquivo de configuração de teste
TEST_HCL="/tmp/nomad-test.hcl"

log_info "Gerando configuração de teste..."

# Gera configuração base
cat >"$TEST_HCL" <<HCL
bind_addr = "$BIND_IP"
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

# Aplica a modificação usando o mesmo comando do script
if [[ -n "$NOMAD_RETRY_JOIN_ARRAY" ]]; then
  log_info "Aplicando configuração server_join..."
  # Adiciona server_join usando múltiplos comandos sed
  sed -i "/bootstrap_expect = ${NOMAD_BOOTSTRAP_EXPECT}/a\\\n  server_join {" "$TEST_HCL"
  sed -i "/server_join {/a\\\n    retry_join     = [$NOMAD_RETRY_JOIN_ARRAY]" "$TEST_HCL"
  sed -i "/retry_join.*=/a\\\n    retry_max      = 3" "$TEST_HCL"
  sed -i "/retry_max.*=/a\\\n    retry_interval = \"15s\"" "$TEST_HCL"
  sed -i "/retry_interval.*=/a\\\n  }" "$TEST_HCL"
  
  # Atualiza a lista de servidores na seção client
  sed -i "s/servers = \[\"127.0.0.1\"\]/servers = [$NOMAD_RETRY_JOIN_ARRAY]/" "$TEST_HCL"
fi

echo ""
log_success "Configuração gerada! Conteúdo do arquivo:"
echo "==========================================="
cat "$TEST_HCL"
echo "==========================================="
echo ""

# Verifica se a configuração está correta
log_info "Verificando formato da configuração..."

# Verifica se server_join existe
if grep -q "server_join {" "$TEST_HCL"; then
    log_success "✅ Bloco server_join encontrado"
else
    log_error "❌ Bloco server_join NÃO encontrado"
fi

# Verifica retry_join dentro de server_join
if grep -A 5 "server_join {" "$TEST_HCL" | grep -q "retry_join"; then
    log_success "✅ retry_join encontrado dentro de server_join"
else
    log_error "❌ retry_join NÃO encontrado dentro de server_join"
fi

# Verifica retry_max
if grep -A 5 "server_join {" "$TEST_HCL" | grep -q "retry_max.*= 3"; then
    log_success "✅ retry_max = 3 configurado"
else
    log_error "❌ retry_max NÃO configurado corretamente"
fi

# Verifica retry_interval
if grep -A 5 "server_join {" "$TEST_HCL" | grep -q 'retry_interval.*= "15s"'; then
    log_success "✅ retry_interval = \"15s\" configurado"
else
    log_error "❌ retry_interval NÃO configurado corretamente"
fi

# Verifica se os IPs estão corretos
if grep -A 5 "server_join {" "$TEST_HCL" | grep -q "10.0.1.10.*10.0.1.11.*10.0.1.12"; then
    log_success "✅ IPs dos servidores configurados corretamente"
else
    log_error "❌ IPs dos servidores NÃO configurados corretamente"
fi

# Verifica se client servers foi atualizado
if grep "servers = " "$TEST_HCL" | grep -q "10.0.1.10.*10.0.1.11.*10.0.1.12"; then
    log_success "✅ Lista de servidores do cliente atualizada"
else
    log_error "❌ Lista de servidores do cliente NÃO atualizada"
fi

echo ""
log_info "Testando validação da configuração com Nomad..."

# Testa se a configuração é válida (se nomad estiver instalado)
if command -v nomad >/dev/null 2>&1; then
    if nomad config validate "$TEST_HCL" >/dev/null 2>&1; then
        log_success "✅ Configuração é válida segundo o Nomad"
    else
        log_error "❌ Configuração é INVÁLIDA segundo o Nomad"
        echo "Erro de validação:"
        nomad config validate "$TEST_HCL"
    fi
else
    log_warn "⚠️  Nomad não está instalado - não foi possível validar a configuração"
fi

echo ""
log_info "Extraindo apenas a seção server_join para verificação:"
echo "---------------------------------------------------"
grep -A 5 "server_join {" "$TEST_HCL" | head -6
echo "---------------------------------------------------"

echo ""
log_info "Comparação com formato esperado:"
echo "server_join {"
echo "  retry_join     = [ \"10.0.1.10\", \"10.0.1.11\", \"10.0.1.12\" ]"
echo "  retry_max      = 3"
echo "  retry_interval = \"15s\""
echo "}"

echo ""
log_success "🎉 Teste concluído! Arquivo de teste salvo em: $TEST_HCL"
log_info "Para limpar: rm $TEST_HCL"

# Cleanup opcional
read -p "Deseja remover o arquivo de teste? (s/n) [n]: " cleanup
if [[ "${cleanup,,}" == "s" ]]; then
    rm -f "$TEST_HCL"
    log_info "Arquivo de teste removido."
fi