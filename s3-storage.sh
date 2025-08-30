#!/bin/bash

# Função para solicitar entrada do usuário
read_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    
    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " input
        if [ -z "$input" ]; then
            input="$default"
        fi
    else
        read -p "$prompt: " input
        while [ -z "$input" ]; do
            echo "Este campo é obrigatório!"
            read -p "$prompt: " input
        done
    fi
    
    eval "$var_name='$input'"
}

echo "🔧 Configuração do S3 Storage"
echo "============================="
echo ""

# Solicita as configurações do usuário
read_input "Nome do bucket S3" "meu-bucket" "S3_BUCKET"
read_input "Caminho de montagem" "/mnt/s3" "S3_MOUNT_PATH"
read_input "Arquivo de credenciais" "/root/.passwd-s3fs" "PASSWD_S3FS"
read_input "Access Key" "" "ACCESS_KEY"
read_input "Secret Key" "" "SECRET_KEY"
read_input "Endpoint S3" "https://s3.sa-east-1.amazonaws.com" "S3_ENDPOINT"

echo ""
echo "📋 Resumo das configurações:"
echo "Bucket: $S3_BUCKET"
echo "Caminho: $S3_MOUNT_PATH"
echo "Credenciais: $PASSWD_S3FS"
echo "Endpoint: $S3_ENDPOINT"
echo ""
read -p "Confirma as configurações? (s/N): " confirm

if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
    echo "❌ Configuração cancelada pelo usuário."
    exit 1
fi

echo "🔧 Iniciando configuração do S3..."

# Instala o s3fs
apt update && apt install -y s3fs

# Cria diretório de montagem
mkdir -p ${S3_MOUNT_PATH}

# Cria arquivo de credenciais
echo "${ACCESS_KEY}:${SECRET_KEY}" > ${PASSWD_S3FS}
chmod 600 ${PASSWD_S3FS}

# Monta o bucket
s3fs ${S3_BUCKET} ${S3_MOUNT_PATH} \
  -o passwd_file=${PASSWD_S3FS} \
  -o url=${S3_ENDPOINT} \
  -o use_path_request_style \
  -o allow_other

# Adiciona ao fstab para persistência
echo "s3fs#${S3_BUCKET} ${S3_MOUNT_PATH} fuse _netdev,passwd_file=${PASSWD_S3FS},url=${S3_ENDPOINT},use_path_request_style,allow_other 0 0" >> /etc/fstab

echo "✅ Montagem do S3 concluída com sucesso em ${S3_MOUNT_PATH}"
echo "📁 Para verificar se está funcionando, execute: ls -la ${S3_MOUNT_PATH}"
echo "🔄 Para desmontar: umount ${S3_MOUNT_PATH}"