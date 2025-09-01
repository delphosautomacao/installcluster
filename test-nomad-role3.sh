#!/usr/bin/env bash
# Script de teste para verificar se os arquivos server.hcl e client.hcl são criados corretamente
# quando a opção 3 (ambos) é selecionada

# Diretório do script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Importa bibliotecas
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/nomad.sh"

# Configurações de teste
NOMAD_ROLE="3"  # Ambos (servidor e cliente)
REGION="global"
DC="dc1"
NODE_NAME="test-node"
DATA_DIR="/tmp/test-nomad"
NOMAD_USER="nomad"
NOMAD_GROUP="nomad"
NOMAD_HCL="/tmp/test-nomad.hcl"
NOMAD_HCL_SERVER="/tmp/test-server.hcl"
NOMAD_HCL_CLIENT="/tmp/test-client.hcl"
NOMAD_HCL_DIR="/tmp/test-nomad-config"
NOMAD_JOIN="s"
NOMAD_SERVERS="192.168.1.10,192.168.1.11,192.168.1.12"
NOMAD_BOOTSTRAP_EXPECT="3"

log_info "Testando criação de arquivos Nomad com role 3 (ambos)..."

# Cria diretórios de teste
mkdir -p "$DATA_DIR"
mkdir -p "$NOMAD_HCL_DIR"

# Remove arquivos de teste anteriores se existirem
rm -f "$NOMAD_HCL" "$NOMAD_HCL_SERVER" "$NOMAD_HCL_CLIENT"

# Chama a função setup_nomad com todos os parâmetros
setup_nomad "$NOMAD_ROLE" "$REGION" "$DC" "$NODE_NAME" "$DATA_DIR" \
           "$NOMAD_USER" "$NOMAD_GROUP" "$NOMAD_HCL" "$NOMAD_JOIN" \
           "$NOMAD_SERVERS" "$NOMAD_BOOTSTRAP_EXPECT" "$NOMAD_HCL_DIR" \
           "$NOMAD_HCL_SERVER" "$NOMAD_HCL_CLIENT"

# Verifica se os arquivos foram criados
log_info "Verificando arquivos criados..."

if [[ -f "$NOMAD_HCL" ]]; then
    log_info "✓ Arquivo principal nomad.hcl criado com sucesso"
    echo "Conteúdo do nomad.hcl:"
    cat "$NOMAD_HCL"
    echo "---"
else
    log_error "✗ Arquivo principal nomad.hcl NÃO foi criado"
fi

if [[ -f "$NOMAD_HCL_SERVER" ]]; then
    log_info "✓ Arquivo server.hcl criado com sucesso"
    echo "Conteúdo do server.hcl:"
    cat "$NOMAD_HCL_SERVER"
    echo "---"
else
    log_error "✗ Arquivo server.hcl NÃO foi criado"
fi

if [[ -f "$NOMAD_HCL_CLIENT" ]]; then
    log_info "✓ Arquivo client.hcl criado com sucesso"
    echo "Conteúdo do client.hcl:"
    cat "$NOMAD_HCL_CLIENT"
    echo "---"
else
    log_error "✗ Arquivo client.hcl NÃO foi criado"
fi

# Limpa arquivos de teste
log_info "Limpando arquivos de teste..."
rm -f "$NOMAD_HCL" "$NOMAD_HCL_SERVER" "$NOMAD_HCL_CLIENT"
rmdir "$DATA_DIR" "$NOMAD_HCL_DIR" 2>/dev/null

log_info "Teste concluído!"