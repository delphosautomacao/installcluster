#!/usr/bin/env bash
# Script de teste para verificar se as permissões dos diretórios estão sendo aplicadas corretamente

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
DATA_DIR="/tmp/test-nomad-data"
NOMAD_USER="test-nomad"
NOMAD_GROUP="test-nomad"
NOMAD_HCL="/tmp/test-nomad.hcl"
NOMAD_HCL_SERVER="/tmp/test-server.hcl"
NOMAD_HCL_CLIENT="/tmp/test-client.hcl"
NOMAD_HCL_DIR="/tmp/test-nomad-config"
NOMAD_JOIN="n"
NOMAD_SERVERS=""
NOMAD_BOOTSTRAP_EXPECT="1"

log_info "Testando criação de usuário/grupo e aplicação de permissões..."

# Remove usuário/grupo de teste se existir
if id -u "$NOMAD_USER" >/dev/null 2>&1; then
    log_info "Removendo usuário de teste existente: $NOMAD_USER"
    userdel "$NOMAD_USER" 2>/dev/null || true
fi

if getent group "$NOMAD_GROUP" >/dev/null 2>&1; then
    log_info "Removendo grupo de teste existente: $NOMAD_GROUP"
    groupdel "$NOMAD_GROUP" 2>/dev/null || true
fi

# Remove diretórios de teste se existirem
rm -rf "$DATA_DIR" "$NOMAD_HCL_DIR" "/tmp/test-alloc_mounts"
rm -f "$NOMAD_HCL" "$NOMAD_HCL_SERVER" "$NOMAD_HCL_CLIENT"

# Simula apenas a parte de criação de usuário/grupo e permissões
log_info "Criando usuário/grupo de teste..."

# Cria grupo se não existir
if ! getent group "${NOMAD_GROUP}" >/dev/null 2>&1; then
    log_info "Criando grupo ${NOMAD_GROUP}..."
    addgroup --system "${NOMAD_GROUP}" || log_warn "Falha ao criar grupo ${NOMAD_GROUP}"
fi

# Cria usuário se não existir
if ! id -u "${NOMAD_USER}" >/dev/null 2>&1; then
    log_info "Criando usuário ${NOMAD_USER}..."
    useradd --system --home /etc/nomad.d --shell /bin/false --gid "${NOMAD_GROUP}" "$NOMAD_USER" 
fi

# Cria diretórios
mkdir -p "$DATA_DIR"
mkdir -p "$NOMAD_HCL_DIR"
mkdir -p "/tmp/test-alloc_mounts"
log_info "Criado diretórios de teste"

# Aplica permissões
chown -R "$NOMAD_USER:$NOMAD_GROUP" "$NOMAD_HCL_DIR"
chown -R "$NOMAD_USER:$NOMAD_GROUP" "$DATA_DIR"
chown -R "$NOMAD_USER:$NOMAD_GROUP" "/tmp/test-alloc_mounts"

chmod 700 "$NOMAD_HCL_DIR"
chmod 755 "$DATA_DIR"
chmod 755 "/tmp/test-alloc_mounts"
log_info "Aplicado permissões de teste"

# Verifica as permissões
log_info "Verificando permissões aplicadas..."

echo "=== Verificação de Permissões ==="
echo "Diretório de configuração ($NOMAD_HCL_DIR):"
ls -ld "$NOMAD_HCL_DIR"

echo "Diretório de dados ($DATA_DIR):"
ls -ld "$DATA_DIR"

echo "Diretório de montagens (/tmp/test-alloc_mounts):"
ls -ld "/tmp/test-alloc_mounts"

echo "Usuário $NOMAD_USER:"
id "$NOMAD_USER"

echo "Grupo $NOMAD_GROUP:"
getent group "$NOMAD_GROUP"

# Limpa recursos de teste
log_info "Limpando recursos de teste..."
rm -rf "$DATA_DIR" "$NOMAD_HCL_DIR" "/tmp/test-alloc_mounts"
userdel "$NOMAD_USER" 2>/dev/null || true
groupdel "$NOMAD_GROUP" 2>/dev/null || true

log_info "Teste de permissões concluído!"