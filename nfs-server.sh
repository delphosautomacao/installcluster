#!/bin/bash

# Instala o servidor NFS
apt update && apt install -y nfs-kernel-server

# Cria os diretórios compartilhados
mkdir -p /srv/shared

# Define permissões
chown -R nobody:nogroup /srv/shared
chmod -R 777 /srv/shared

# Configura exportação
echo "/srv/shared *(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports

# Aplica as configurações
exportfs -a
systemctl enable nfs-server
systemctl restart nfs-server