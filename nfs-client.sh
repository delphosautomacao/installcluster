#!/bin/bash

# IP do servidor NFS
NFS_SERVER_IP="10.0.0.1"  # substitua pelo IP real do nó1

# Instala cliente NFS
apt update && apt install -y nfs-common

# Cria pontos de montagem
mkdir -p /mnt/whaticket
mkdir -p /mnt/pocketbase

# Monta os diretórios
mount ${NFS_SERVER_IP}:/srv/shared /mnt/shared

# Adiciona ao fstab para persistência
echo "${NFS_SERVER_IP}:/srv/shared /mnt/shared nfs defaults 0 0" >> /etc/fstab
