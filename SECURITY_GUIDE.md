# Guia de Segurança para Nomad e Consul

## Visão Geral

Este guia apresenta as melhores práticas para proteger seu cluster Nomad e Consul contra acessos não autorizados. As configurações atuais do seu script já implementam algumas medidas básicas, mas há várias melhorias importantes que podem ser aplicadas.

## 🔒 Segurança do Consul

### 1. ACLs (Access Control Lists)

**Status Atual:** Desabilitado
**Recomendação:** Habilitar ACLs para controle granular de acesso

#### Configuração de ACLs:

```hcl
# Adicionar ao arquivo /etc/consul.d/consul.hcl
acl = {
  enabled = true
  default_policy = "deny"
  enable_token_persistence = true
}
```

#### Passos para implementar ACLs:

1. **Bootstrap do sistema ACL:**
```bash
consul acl bootstrap
# Salve o SecretID do token master gerado!
```

2. **Criar políticas específicas:**
```bash
# Política para agentes Consul
consul acl policy create \
  -name "agent-policy" \
  -description "Policy for Consul agents" \
  -rules @agent-policy.hcl

# Política para Nomad
consul acl policy create \
  -name "nomad-policy" \
  -description "Policy for Nomad integration" \
  -rules @nomad-policy.hcl
```

3. **Exemplo de política para agentes (agent-policy.hcl):**
```hcl
node_prefix "" {
  policy = "write"
}
service_prefix "" {
  policy = "read"
}
key_prefix "" {
  policy = "read"
}
```

### 2. TLS/SSL Encryption

**Status Atual:** Não configurado
**Recomendação:** Implementar TLS para criptografar comunicação

#### Gerar certificados:

```bash
# Criar CA
consul tls ca create

# Gerar certificados para cada servidor
consul tls cert create -server -dc dc1

# Gerar certificados para clientes
consul tls cert create -client -dc dc1
```

#### Configuração TLS no Consul:

```hcl
# Adicionar ao consul.hcl
tls {
  defaults {
    verify_incoming = true
    verify_outgoing = true
    verify_server_hostname = true
  }
  internal_rpc {
    ca_file = "/etc/consul.d/certs/consul-agent-ca.pem"
    cert_file = "/etc/consul.d/certs/dc1-server-consul-0.pem"
    key_file = "/etc/consul.d/certs/dc1-server-consul-0-key.pem"
  }
  https {
    ca_file = "/etc/consul.d/certs/consul-agent-ca.pem"
    cert_file = "/etc/consul.d/certs/dc1-server-consul-0.pem"
    key_file = "/etc/consul.d/certs/dc1-server-consul-0-key.pem"
  }
}

ports {
  https = 8501
  http = -1  # Desabilita HTTP não criptografado
}
```

### 3. Gossip Encryption

**Status Atual:** ✅ Implementado (encrypt key)
**Melhoria:** Rotacionar chaves periodicamente

```bash
# Gerar nova chave
new_key=$(consul keygen)

# Instalar nova chave em todos os nós
consul keyring -install="$new_key"

# Usar nova chave
consul keyring -use="$new_key"

# Remover chave antiga
consul keyring -remove="$old_key"
```

### 4. Configurações de Rede Seguras

```hcl
# Restringir bind_addr para interface específica
bind_addr = "10.0.1.10"  # IP privado específico

# Configurar client_addr para acesso controlado
client_addr = "127.0.0.1 10.0.1.10"  # Apenas localhost e IP privado

# Desabilitar UI em produção ou proteger com proxy reverso
ui_config {
  enabled = false  # ou configurar autenticação via proxy
}
```

## 🛡️ Segurança do Nomad

### 1. ACLs do Nomad

**Status Atual:** Desabilitado
**Recomendação:** Habilitar ACLs

#### Configuração:

```hcl
# Adicionar ao nomad.hcl
acl {
  enabled = true
}
```

#### Bootstrap e configuração:

```bash
# Bootstrap do sistema ACL
nomad acl bootstrap
# Salve o Secret ID do token master!

# Criar política para operadores
nomad acl policy apply \
  -description "Admin policy" \
  admin-policy admin-policy.hcl

# Criar token para operadores
nomad acl token create \
  -name="admin-token" \
  -policy="admin-policy"
```

### 2. TLS para Nomad

```hcl
# Configuração TLS no nomad.hcl
tls {
  http = true
  rpc  = true

  ca_file   = "/etc/nomad.d/certs/nomad-ca.pem"
  cert_file = "/etc/nomad.d/certs/server.pem"
  key_file  = "/etc/nomad.d/certs/server-key.pem"

  verify_server_hostname = true
  verify_https_client    = true
}
```

### 3. Configurações de Segurança do Cliente

```hcl
client {
  enabled = true
  
  # Configurações de segurança
  options {
    "driver.raw_exec.enable" = "false"  # Desabilita raw_exec
    "driver.java.enable" = "false"      # Desabilita Java se não necessário
  }
  
  # Configurar recursos permitidos
  reserved {
    cpu    = 500
    memory = 512
    disk   = 1024
  }
}
```

## 🔥 Firewall e Rede

### Portas Necessárias:

#### Consul:
- **8300**: Server RPC (apenas entre servidores)
- **8301**: Serf LAN (todos os agentes)
- **8302**: Serf WAN (apenas servidores WAN)
- **8500**: HTTP API (restringir acesso)
- **8501**: HTTPS API (quando TLS habilitado)
- **8600**: DNS (opcional)

#### Nomad:
- **4646**: HTTP API (restringir acesso)
- **4647**: RPC (apenas entre servidores)
- **4648**: Serf (todos os agentes)

### Configuração de Firewall (UFW):

```bash
# Consul - apenas IPs do cluster
ufw allow from 10.0.1.0/24 to any port 8300
ufw allow from 10.0.1.0/24 to any port 8301
ufw allow from 10.0.1.0/24 to any port 8302

# Nomad - apenas IPs do cluster
ufw allow from 10.0.1.0/24 to any port 4646
ufw allow from 10.0.1.0/24 to any port 4647
ufw allow from 10.0.1.0/24 to any port 4648

# Acesso administrativo apenas de IPs específicos
ufw allow from 10.0.1.100 to any port 8500  # Admin workstation
ufw allow from 10.0.1.100 to any port 4646  # Admin workstation
```

## 🔐 Autenticação e Autorização

### 1. Integração com LDAP/AD (Consul Enterprise)

```hcl
# Configuração LDAP para Consul Enterprise
connect {
  enabled = true
}

config_entries {
  bootstrap = [
    {
      kind = "proxy-defaults"
      name = "global"
      config {
        protocol = "http"
      }
    }
  ]
}
```

### 2. Proxy Reverso com Autenticação

#### Nginx com autenticação básica:

```nginx
server {
    listen 443 ssl;
    server_name consul.example.com;
    
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;
    
    auth_basic "Consul Access";
    auth_basic_user_file /etc/nginx/.htpasswd;
    
    location / {
        proxy_pass http://127.0.0.1:8500;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## 📊 Monitoramento e Auditoria

### 1. Logs de Auditoria

```hcl
# Consul - habilitar logs detalhados
log_level = "INFO"
log_file = "/var/log/consul/"
log_rotate_duration = "24h"
log_rotate_max_files = 30

# Nomad - configuração similar
log_level = "INFO"
log_file = "/var/log/nomad/"
log_rotate_duration = "24h"
log_rotate_max_files = 30
```

### 2. Métricas e Alertas

```hcl
# Habilitar métricas Prometheus
telemetry {
  prometheus_retention_time = "60s"
  disable_hostname = true
}
```

## 🚀 Script de Implementação Rápida

Crie um script para aplicar as configurações de segurança:

```bash
#!/bin/bash
# security-hardening.sh

echo "Aplicando configurações de segurança..."

# Backup das configurações atuais
cp /etc/consul.d/consul.hcl /etc/consul.d/consul.hcl.backup
cp /etc/nomad.d/nomad.hcl /etc/nomad.d/nomad.hcl.backup

# Aplicar configurações de segurança
# (adicionar comandos específicos baseados nas necessidades)

echo "Configurações de segurança aplicadas!"
echo "IMPORTANTE: Teste todas as funcionalidades antes de usar em produção!"
```

## ⚠️ Checklist de Segurança

- [ ] ACLs habilitados no Consul
- [ ] ACLs habilitados no Nomad
- [ ] TLS configurado para ambos os serviços
- [ ] Gossip encryption ativo
- [ ] Firewall configurado
- [ ] UI protegida ou desabilitada
- [ ] Logs de auditoria habilitados
- [ ] Backup das chaves de criptografia
- [ ] Monitoramento implementado
- [ ] Políticas de acesso documentadas
- [ ] Procedimentos de rotação de chaves definidos

## 📚 Recursos Adicionais

- [Consul Security Guide](https://learn.hashicorp.com/tutorials/consul/security-intro)
- [Nomad Security Guide](https://learn.hashicorp.com/tutorials/nomad/security-intro)
- [HashiCorp Security Best Practices](https://learn.hashicorp.com/tutorials/consul/security-best-practices)

---

**Nota:** Implemente essas configurações gradualmente e teste em ambiente de desenvolvimento antes de aplicar em produção. Sempre mantenha backups das configurações atuais.