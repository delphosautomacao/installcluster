# 🔐 Segurança do Cluster Nomad e Consul

Este documento fornece instruções completas para proteger seu cluster Nomad e Consul contra acessos não autorizados.

## 📋 Pré-requisitos

- Cluster Nomad e Consul já instalado e funcionando
- Acesso root aos servidores
- Conectividade de rede entre os nós do cluster

## 🚀 Implementação Rápida

### Passo 1: Aplicar Configurações de Segurança

```bash
# Execute em TODOS os nós do cluster
sudo ./security-hardening.sh
```

Este script irá:
- ✅ Configurar TLS para Consul e Nomad
- ✅ Habilitar ACLs
- ✅ Configurar logs de auditoria
- ✅ Configurar firewall básico
- ✅ Criar backup das configurações atuais

### Passo 2: Configurar Políticas e Tokens

```bash
# Execute APENAS em UM nó (preferencialmente o líder)
sudo ./setup-acl-policies.sh
```

Este script irá:
- ✅ Fazer bootstrap dos ACLs
- ✅ Criar políticas de acesso
- ✅ Gerar tokens para diferentes usuários/serviços
- ✅ Configurar tokens nos serviços

## 🔧 Configuração Manual (Alternativa)

Se preferir configurar manualmente, siga o guia detalhado em `SECURITY_GUIDE.md`.

## 🎯 Após a Implementação

### 1. Verificar Status dos Serviços

```bash
# Verificar Consul
sudo systemctl status consul
consul members

# Verificar Nomad
sudo systemctl status nomad
nomad server members
nomad node status
```

### 2. Configurar Cliente para Acesso Seguro

```bash
# Execute o script gerado automaticamente
source /root/cluster-tokens/setup-client.sh

# Ou configure manualmente:
export CONSUL_HTTP_SSL=true
export CONSUL_HTTP_ADDR="https://SEU-IP:8501"
export CONSUL_CACERT="/etc/consul.d/certs/consul-agent-ca.pem"
export CONSUL_HTTP_TOKEN="seu-token-consul"

export NOMAD_ADDR="https://SEU-IP:4646"
export NOMAD_CACERT="/etc/nomad.d/certs/nomad-ca.pem"
export NOMAD_TOKEN="seu-token-nomad"
```

### 3. Testar Acesso

```bash
# Testar Consul
consul members
consul catalog services

# Testar Nomad
nomad server members
nomad job status
```

## 🔑 Gerenciamento de Tokens

### Tokens Criados Automaticamente

| Serviço | Token | Descrição | Uso |
|---------|-------|-----------|-----|
| Consul | Bootstrap | Token master | Administração inicial |
| Consul | Agent | Token para agentes | Comunicação entre agentes |
| Consul | Nomad Integration | Token para Nomad | Integração Nomad-Consul |
| Consul | Operator Read | Token de leitura | Monitoramento |
| Consul | Operator Write | Token de escrita | Administração |
| Nomad | Bootstrap | Token master | Administração inicial |
| Nomad | Operator Read | Token de leitura | Monitoramento |
| Nomad | Operator Write | Token de escrita | Administração |
| Nomad | Developer | Token para devs | Deploy de aplicações |

### Localização dos Tokens

Todos os tokens são salvos em: `/root/cluster-tokens/`

```bash
# Listar todos os tokens
ls -la /root/cluster-tokens/

# Ver token específico
cat /root/cluster-tokens/consul-operator-write.token
cat /root/cluster-tokens/nomad-developer.token
```

### Distribuir Tokens para Usuários

```bash
# Para administradores
echo "export CONSUL_HTTP_TOKEN=$(grep SecretID /root/cluster-tokens/consul-operator-write.token | awk '{print $2}')" > admin-consul.env
echo "export NOMAD_TOKEN=$(grep 'Secret ID' /root/cluster-tokens/nomad-operator-write.token | awk '{print $4}')" > admin-nomad.env

# Para desenvolvedores
echo "export NOMAD_TOKEN=$(grep 'Secret ID' /root/cluster-tokens/nomad-developer.token | awk '{print $4}')" > dev-nomad.env

# Para monitoramento
echo "export CONSUL_HTTP_TOKEN=$(grep SecretID /root/cluster-tokens/consul-operator-read.token | awk '{print $2}')" > monitoring-consul.env
echo "export NOMAD_TOKEN=$(grep 'Secret ID' /root/cluster-tokens/nomad-operator-read.token | awk '{print $4}')" > monitoring-nomad.env
```

## 🛡️ Configurações de Firewall

### Portas Abertas Automaticamente

| Serviço | Porta | Protocolo | Descrição |
|---------|-------|-----------|-----------|
| Consul | 8300 | TCP | Server RPC |
| Consul | 8301 | TCP/UDP | Serf LAN |
| Consul | 8302 | TCP/UDP | Serf WAN |
| Consul | 8501 | TCP | HTTPS API |
| Nomad | 4646 | TCP | HTTP API |
| Nomad | 4647 | TCP | RPC |
| Nomad | 4648 | TCP/UDP | Serf |

### Verificar Status do Firewall

```bash
sudo ufw status verbose
```

### Personalizar Firewall

```bash
# Permitir acesso de IP específico
sudo ufw allow from 192.168.1.100 to any port 8501
sudo ufw allow from 192.168.1.100 to any port 4646

# Remover regra
sudo ufw delete allow from 192.168.1.100 to any port 8501
```

## 🔄 Manutenção de Segurança

### Rotação de Chaves Gossip

```bash
# Gerar nova chave
new_key=$(consul keygen)

# Instalar em todos os nós
consul keyring -install="$new_key"

# Ativar nova chave
consul keyring -use="$new_key"

# Remover chave antiga
consul keyring -remove="$old_key"
```

### Rotação de Certificados TLS

```bash
# Gerar novos certificados
cd /etc/consul.d/certs
consul tls cert create -server -dc dc1

# Atualizar configuração e reiniciar
sudo systemctl restart consul
sudo systemctl restart nomad
```

### Auditoria de Tokens

```bash
# Listar tokens ativos do Consul
consul acl token list

# Listar tokens ativos do Nomad
nomad acl token list

# Revogar token específico
consul acl token delete -id="token-id"
nomad acl token delete "token-id"
```

## 🚨 Troubleshooting

### Problema: Serviços não iniciam após aplicar segurança

```bash
# Verificar logs
sudo journalctl -u consul -f
sudo journalctl -u nomad -f

# Verificar configuração
consul validate /etc/consul.d/consul.hcl
nomad config validate /etc/nomad.d/nomad.hcl
```

### Problema: Erro de certificado TLS

```bash
# Verificar certificados
openssl x509 -in /etc/consul.d/certs/dc1-server-consul-0.pem -text -noout
openssl x509 -in /etc/nomad.d/certs/server.pem -text -noout

# Regenerar certificados se necessário
cd /etc/consul.d/certs
consul tls cert create -server -dc dc1
```

### Problema: Token inválido

```bash
# Verificar token
consul acl token read -id="token-id"
nomad acl token info "token-id"

# Gerar novo token se necessário
consul acl token create -policy-name="policy-name"
nomad acl token create -policy="policy-name"
```

### Problema: Firewall bloqueando conexões

```bash
# Verificar regras
sudo ufw status numbered

# Adicionar regra temporária para debug
sudo ufw allow from any to any port 8500

# Remover após teste
sudo ufw delete [número-da-regra]
```

## 📊 Monitoramento de Segurança

### Logs Importantes

```bash
# Logs do Consul
sudo tail -f /var/log/consul/consul.log

# Logs do Nomad
sudo tail -f /var/log/nomad/nomad.log

# Logs do sistema
sudo journalctl -u consul -f
sudo journalctl -u nomad -f
```

### Métricas de Segurança

```bash
# Status ACL
consul acl auth-method list
nomad acl auth-method list

# Conexões ativas
ss -tulpn | grep -E ':(8300|8301|8500|8501|4646|4647|4648)'

# Processos dos serviços
ps aux | grep -E '(consul|nomad)'
```

## 🔒 Backup e Recuperação

### Backup Automático

O script `security-hardening.sh` cria automaticamente backup em:
`/root/cluster-backup-YYYYMMDD-HHMMSS/`

### Backup Manual

```bash
# Criar backup completo
BACKUP_DIR="/root/manual-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Backup configurações
cp -r /etc/consul.d "$BACKUP_DIR/"
cp -r /etc/nomad.d "$BACKUP_DIR/"

# Backup tokens
cp -r /root/cluster-tokens "$BACKUP_DIR/"

# Backup dados Consul
consul snapshot save "$BACKUP_DIR/consul-snapshot.snap"

echo "Backup criado em: $BACKUP_DIR"
```

### Restauração

```bash
# Restaurar configurações
sudo cp backup/consul.d/consul.hcl /etc/consul.d/
sudo cp backup/nomad.d/nomad.hcl /etc/nomad.d/

# Restaurar snapshot Consul
consul snapshot restore backup/consul-snapshot.snap

# Reiniciar serviços
sudo systemctl restart consul nomad
```

## 📞 Suporte

Para problemas ou dúvidas:

1. Consulte os logs dos serviços
2. Verifique a documentação oficial:
   - [Consul Security](https://learn.hashicorp.com/tutorials/consul/security-intro)
   - [Nomad Security](https://learn.hashicorp.com/tutorials/nomad/security-intro)
3. Verifique o arquivo `SECURITY_GUIDE.md` para configurações avançadas

---

**⚠️ IMPORTANTE:** 
- Sempre teste em ambiente de desenvolvimento primeiro
- Mantenha backups atualizados
- Monitore logs regularmente
- Rotacione chaves e certificados periodicamente
- Distribua apenas os tokens necessários para cada usuário