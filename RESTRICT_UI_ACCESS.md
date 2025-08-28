# 🔒 Restringir Acesso UI do Nomad e Consul por IP

Este guia mostra como configurar o acesso às interfaces web (UI) do Nomad e Consul para que sejam acessíveis apenas a partir do seu IP específico.

## 🚀 Método Rápido (Recomendado)

### 1. Execute o Script Rápido

```bash
sudo chmod +x quick-ip-restrict.sh
sudo ./quick-ip-restrict.sh
```

**O script irá:**
- ✅ Detectar automaticamente seu IP público
- ✅ Configurar regras de firewall restritivas
- ✅ Ajustar configurações do Consul
- ✅ Reiniciar os serviços
- ✅ Mostrar URLs de acesso

### 2. Resultado

Após a execução, apenas seu IP poderá acessar:
- **Consul UI**: `http://SEU_SERVIDOR:8500/ui/`
- **Nomad UI**: `http://SEU_SERVIDOR:4646/ui/`

---

## 🔧 Método Completo (Avançado)

Para configuração mais detalhada com opções adicionais:

```bash
sudo chmod +x restrict-ui-access.sh
sudo ./restrict-ui-access.sh
```

**Recursos adicionais:**
- 🔍 Detecção avançada de IP
- 💾 Backup automático das configurações
- 🌐 Geração de configs para proxy reverso (Nginx)
- 🔄 Opções de reversão
- 📊 Testes de conectividade

---

## 📋 O Que é Configurado

### 1. Firewall (UFW)
```bash
# Remove acesso geral
ufw delete allow 8500
ufw delete allow 8501
ufw delete allow 4646

# Adiciona acesso específico
ufw allow from SEU_IP to any port 8500  # Consul HTTP
ufw allow from SEU_IP to any port 8501  # Consul HTTPS
ufw allow from SEU_IP to any port 4646  # Nomad UI

# Mantém acesso local
ufw allow from 127.0.0.1 to any port 8500,8501,4646
```

### 2. Configuração do Consul
```hcl
# Em /etc/consul.d/consul.hcl
client_addr = "127.0.0.1 IP_SERVIDOR SEU_IP"
```

### 3. Configuração do Nomad
- Mantém configuração padrão (geralmente adequada)
- Verifica se `bind_addr` está correto

---

## 🔄 Gerenciamento de IPs

### Adicionar Novo IP Autorizado
```bash
# Via firewall
sudo ufw allow from NOVO_IP to any port 8500,8501,4646

# Atualizar Consul (edite /etc/consul.d/consul.hcl)
client_addr = "127.0.0.1 IP_SERVIDOR SEU_IP NOVO_IP"

# Reiniciar serviços
sudo systemctl restart consul nomad
```

### Remover IP Autorizado
```bash
# Listar regras numeradas
sudo ufw status numbered

# Remover regra específica
sudo ufw delete NUMERO_DA_REGRA

# Atualizar Consul removendo o IP do client_addr
# Reiniciar serviços
```

### Verificar IPs Autorizados
```bash
# Ver regras de firewall
sudo ufw status | grep -E '(8500|8501|4646)'

# Ver configuração do Consul
grep client_addr /etc/consul.d/consul.hcl
```

---

## 🆘 Solução de Problemas

### Não Consigo Acessar a UI

1. **Verifique seu IP atual:**
   ```bash
   curl https://ipinfo.io/ip
   ```

2. **Verifique regras de firewall:**
   ```bash
   sudo ufw status | grep -E '(8500|8501|4646)'
   ```

3. **Verifique se os serviços estão rodando:**
   ```bash
   sudo systemctl status consul nomad
   ```

4. **Teste conectividade local:**
   ```bash
   curl -I http://localhost:8500/ui/
   curl -I http://localhost:4646/ui/
   ```

### Meu IP Mudou

**Solução rápida:**
```bash
sudo ./quick-ip-restrict.sh
```

**Ou manualmente:**
```bash
# Descobrir novo IP
NOVO_IP=$(curl -s https://ipinfo.io/ip)

# Remover IP antigo das regras UFW
sudo ufw status numbered | grep -E '(8500|8501|4646)'
sudo ufw delete NUMERO_DA_REGRA_ANTIGA

# Adicionar novo IP
sudo ufw allow from $NOVO_IP to any port 8500,8501,4646

# Atualizar Consul
sudo sed -i "s/client_addr = \".*\"/client_addr = \"127.0.0.1 $(hostname -I | awk '{print $1}') $NOVO_IP\"/" /etc/consul.d/consul.hcl

# Reiniciar
sudo systemctl restart consul nomad
```

### Erro "Connection Refused"

1. **Verifique se o IP está autorizado**
2. **Confirme que os serviços estão rodando**
3. **Teste acesso local primeiro**
4. **Verifique logs:**
   ```bash
   sudo journalctl -u consul -f
   sudo journalctl -u nomad -f
   ```

---

## 🔐 Segurança Adicional

### 1. Usar HTTPS com Certificados

Se você configurou TLS/SSL:
- **Consul HTTPS**: `https://SEU_SERVIDOR:8501/ui/`
- **Nomad HTTPS**: `https://SEU_SERVIDOR:4646/ui/` (se configurado)

### 2. Proxy Reverso com Nginx

O script completo gera configurações de exemplo para Nginx em:
`/root/ui-access-backup-*/nginx-configs/`

### 3. VPN como Alternativa

Considere usar VPN em vez de IP fixo:
- Mais seguro para IPs dinâmicos
- Permite acesso de múltiplos dispositivos
- Não requer reconfiguração constante

---

## 📝 Comandos Úteis

```bash
# Ver status dos serviços
sudo systemctl status consul nomad

# Ver logs em tempo real
sudo journalctl -u consul -f
sudo journalctl -u nomad -f

# Testar conectividade
curl -I http://SEU_SERVIDOR:8500/ui/
curl -I http://SEU_SERVIDOR:4646/ui/

# Ver configurações atuais
cat /etc/consul.d/consul.hcl | grep client_addr
cat /etc/nomad.d/nomad.hcl | grep bind_addr

# Backup das configurações
sudo cp /etc/consul.d/consul.hcl /root/consul.hcl.backup
sudo cp /etc/nomad.d/nomad.hcl /root/nomad.hcl.backup

# Restaurar configurações
sudo cp /root/consul.hcl.backup /etc/consul.d/consul.hcl
sudo cp /root/nomad.hcl.backup /etc/nomad.d/nomad.hcl
sudo systemctl restart consul nomad
```

---

## ⚠️ Avisos Importantes

1. **Backup**: Sempre faça backup antes de modificar configurações
2. **IP Dinâmico**: Se seu IP muda frequentemente, considere usar VPN
3. **Acesso Local**: O acesso via `localhost` sempre é mantido
4. **Firewall**: As regras afetam apenas as portas UI, não as APIs
5. **ACLs**: Se ACLs estão ativos, você ainda precisará de tokens válidos

---

## 🎯 Resumo

**Para restringir rapidamente:**
```bash
sudo ./quick-ip-restrict.sh
```

**Para reverter:**
```bash
# Permitir acesso geral novamente
sudo ufw allow 8500
sudo ufw allow 8501
sudo ufw allow 4646

# Restaurar configuração do Consul
sudo sed -i '/^client_addr/d' /etc/consul.d/consul.hcl
sudo systemctl restart consul nomad
```

Agora apenas seu IP específico pode acessar as interfaces web do Nomad e Consul! 🔒✅