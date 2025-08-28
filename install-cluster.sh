#!/usr/bin/env bash
# ==============================================================================
# Script de instalação e configuração de cluster Nomad e Consul
# ==============================================================================

# Diretório do script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Importa bibliotecas
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/consul.sh"
source "${SCRIPT_DIR}/lib/nomad.sh"

# Verifica se está rodando como root
check_root

# Configurações padrão
INSTALL_DOCKER="n"
INSTALL_CONSUL="n"
INSTALL_NOMAD="n"

# Verifica se deve executar em modo não-interativo
INTERACTIVE=true
if [[ "$1" == "--non-interactive" || "$1" == "-n" ]]; then
  INTERACTIVE=false
  log_info "Executando em modo não-interativo"
  
  # Carrega configurações de arquivo se especificado
  if [[ -n "$2" && -f "$2" ]]; then
    log_info "Carregando configurações do arquivo: $2"
    source "$2"
  fi
fi
NOMAD_ROLE="1"
REGION="global"
DC="dc1"
NODE_NAME="$(hostname)"
DATA_DIR="/opt/nomad"
CONSUL_DATA_DIR="/opt/consul"
NOMAD_USER="nomad"
NOMAD_GROUP="nomad"
CONSUL_USER="consul"
CONSUL_GROUP="consul"
NOMAD_HCL="/etc/nomad.d/nomad.hcl"
CONSUL_HCL="/etc/consul.d/consul.hcl"
NOMAD_JOIN="n"
NOMAD_SERVERS=""
CONSUL_JOIN="n"
CONSUL_SERVERS=""
CONSUL_BOOTSTRAP_EXPECT=1
NOMAD_BOOTSTRAP_EXPECT=1
CONSUL_ENCRYPT_KEY=""
CONSUL_ADVERTISE_ADDR=""

## Função para validar configurações antes da instalação
validate_pre_install() {
  local errors=0
  
  log_info "Validando configurações antes da instalação..."
  
  # Verifica se pelo menos um serviço será instalado
  if [[ "${INSTALL_DOCKER,,}" != "s" && "${INSTALL_CONSUL,,}" != "s" && "${INSTALL_NOMAD,,}" != "s" ]]; then
    log_warn "Nenhum serviço selecionado para instalação."
    ((errors++))
  fi
  
  # Validações específicas do Consul
  if [[ "${INSTALL_CONSUL,,}" == "s" ]]; then
    if [[ -z "$CONSUL_ADVERTISE_ADDR" ]]; then
      log_warn "Endereço de anúncio do Consul não definido."
      ((errors++))
    fi
    
    if [[ "${CONSUL_JOIN,,}" == "s" && -z "${CONSUL_SERVERS// }" ]]; then
      log_warn "Configurado para juntar-se ao cluster Consul, mas nenhum servidor especificado."
      ((errors++))
    fi
  fi
  
  # Validações específicas do Nomad
  if [[ "${INSTALL_NOMAD,,}" == "s" ]]; then
    if [[ "$NOMAD_ROLE" != "1" && "$NOMAD_ROLE" != "2" && "$NOMAD_ROLE" != "3" ]]; then
      log_warn "Papel do Nomad inválido: $NOMAD_ROLE. Deve ser 1, 2 ou 3."
      ((errors++))
    fi
    
    if [[ "${NOMAD_JOIN,,}" == "s" && -z "${NOMAD_SERVERS// }" ]]; then
      log_warn "Configurado para juntar-se ao cluster Nomad, mas nenhum servidor especificado."
      ((errors++))
    fi
    
    # Verifica dependência do Consul para Nomad
    if [[ "${INSTALL_CONSUL,,}" != "s" ]]; then
      log_warn "Nomad configurado sem Consul. A integração pode não funcionar corretamente."
      ((errors++))
    fi
  fi
  
  if [[ $errors -gt 0 ]]; then
    log_warn "Foram encontrados $errors problemas na configuração pré-instalação."
    if [[ "$INTERACTIVE" == "true" ]]; then
      read -p "Deseja continuar mesmo assim? (s/n) [n]: " continue_install
      if [[ "${continue_install,,}" != "s" ]]; then
        fail "Instalação cancelada pelo usuário."
      fi
    fi
  else
    log_info "Validação pré-instalação concluída com sucesso!"
  fi
  
  return $errors
}

# Função para exibir o resumo da instalação
show_summary() {
  log "============================================================"
  log "                RESUMO DA INSTALAÇÃO"
  log "============================================================"
  
  if [[ "${INSTALL_DOCKER,,}" == "s" ]]; then
    log_info "Docker: INSTALADO"
  else
    log_info "Docker: NÃO INSTALADO"
  fi
  
  if [[ "${INSTALL_CONSUL,,}" == "s" ]]; then
    log_info "Consul: INSTALADO"
    log_info "  - Data Dir: ${CONSUL_DATA_DIR}"
    log_info "  - Bootstrap Expect: ${CONSUL_BOOTSTRAP_EXPECT}"
    log_info "  - Advertise Addr: ${CONSUL_ADVERTISE_ADDR}"
    log_info "  - Encrypt Key: $(if [[ -n "$CONSUL_ENCRYPT_KEY" ]]; then echo "Configurada"; else echo "Não configurada"; fi)"
    if [[ "${CONSUL_JOIN,,}" == "s" ]]; then
      log_info "  - Cluster: Configurado para juntar-se a servidores existentes"
      log_info "  - Servidores: ${CONSUL_SERVERS}"
    else
      log_info "  - Cluster: Configurado como servidor independente"
    fi
  else
    log_info "Consul: NÃO INSTALADO"
  fi
  
  if [[ "${INSTALL_NOMAD,,}" == "s" ]]; then
    log_info "Nomad: INSTALADO"
    log_info "  - Data Dir: ${DATA_DIR}"
    log_info "  - Região: ${REGION}"
    log_info "  - Datacenter: ${DC}"
    log_info "  - Nome do Nó: ${NODE_NAME}"
    
    case "$NOMAD_ROLE" in
      1) log_info "  - Papel: Servidor" ;;
      2) log_info "  - Papel: Cliente" ;;
      3) log_info "  - Papel: Ambos (Servidor e Cliente)" ;;
    esac
    
    if [[ "${NOMAD_JOIN,,}" == "s" ]]; then
      log_info "  - Cluster: Configurado para juntar-se a servidores existentes"
      log_info "  - Servidores: ${NOMAD_SERVERS}"
    else
      log_info "  - Cluster: Configurado como servidor independente"
    fi
    
    log_info "  - Diretório de alocações: /opt/alloc_mounts"
  else
    log_info "Nomad: NÃO INSTALADO"
  fi
  
  log "============================================================"
}

# Função principal
main() {
  log "============================================================"
  log "     INSTALAÇÃO DE CLUSTER NOMAD/CONSUL"
  log "============================================================"
  
  # Atualiza repositórios
  log "Atualizando repositórios..."
  apt-get update -qq
  
  if [[ "$INTERACTIVE" == "true" ]]; then
    # Pergunta sobre instalação do Docker
    read -p "Instalar Docker? (s/n) [${INSTALL_DOCKER}]: " input
    INSTALL_DOCKER=${input:-$INSTALL_DOCKER}
    
    # Pergunta sobre instalação do Consul
    read -p "Instalar Consul? (s/n) [${INSTALL_CONSUL}]: " input
    INSTALL_CONSUL=${input:-$INSTALL_CONSUL}
    
    # Pergunta sobre instalação do Nomad
    read -p "Instalar Nomad? (s/n) [${INSTALL_NOMAD}]: " input
    INSTALL_NOMAD=${input:-$INSTALL_NOMAD}
  else
    log_info "Usando configurações pré-definidas:"
    log_info "- Docker: ${INSTALL_DOCKER}"
    log_info "- Consul: ${INSTALL_CONSUL}"
    log_info "- Nomad: ${INSTALL_NOMAD}"
  fi
  
  # Validação pré-instalação
  validate_pre_install
  
  # Configuração do Docker
  if [[ "${INSTALL_DOCKER,,}" == "s" ]]; then
    log_info "Instalando Docker..."
    apt-get install -yq --no-install-recommends apt-transport-https ca-certificates curl software-properties-common
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt-get update -qq
    apt-get install -yq --no-install-recommends docker-ce docker-ce-cli containerd.io
    systemctl enable docker
    systemctl start docker
    log_info "Docker instalado com sucesso!"
  fi
  
  # Configuração do Consul
  if [[ "${INSTALL_CONSUL,,}" == "s" ]]; then
    # Configuração do endereço de anúncio se não estiver definido
    if [[ -z "$CONSUL_ADVERTISE_ADDR" ]]; then
      CONSUL_ADVERTISE_ADDR=$(hostname -I | awk '{print $1}')
    fi
    
    if [[ "$INTERACTIVE" == "true" ]]; then
      # Perguntas específicas do Consul
      read -p "Número de servidores esperados para bootstrap (bootstrap_expect) [${CONSUL_BOOTSTRAP_EXPECT}]: " input
      CONSUL_BOOTSTRAP_EXPECT=${input:-$CONSUL_BOOTSTRAP_EXPECT}
      
      # Endereço para anúncio (advertise_addr)
      read -p "Endereço IP para anúncio (advertise_addr) [${CONSUL_ADVERTISE_ADDR}]: " input
      CONSUL_ADVERTISE_ADDR=${input:-$CONSUL_ADVERTISE_ADDR}
      
      # Chave de criptografia (encrypt)
      read -p "Gerar nova chave de criptografia ou usar existente? (g/e) [g]: " encrypt_option
      encrypt_option=${encrypt_option:-g}
      
      if [[ "${encrypt_option,,}" == "g" ]]; then
        CONSUL_ENCRYPT_KEY=$(generate_consul_key_with_logs)
        log_info "Nova chave de criptografia gerada: ${CONSUL_ENCRYPT_KEY}"
      else
        read -p "Informe a chave de criptografia existente: " CONSUL_ENCRYPT_KEY
      fi
      
      # Juntar-se a cluster existente
      read -p "Juntar-se a cluster Consul existente? (s/n) [${CONSUL_JOIN}]: " input
      CONSUL_JOIN=${input:-$CONSUL_JOIN}
      
      if [[ "${CONSUL_JOIN,,}" == "s" ]]; then
        read -p "Lista de servidores Consul (separados por vírgula): " CONSUL_SERVERS
      fi
    else
      # Modo não-interativo
      log_info "Configuração do Consul em modo não-interativo:"
      log_info "- Bootstrap Expect: ${CONSUL_BOOTSTRAP_EXPECT}"
      log_info "- Advertise Addr: ${CONSUL_ADVERTISE_ADDR}"
      
      # Gera chave de criptografia se não estiver definida
      if [[ -z "${CONSUL_ENCRYPT_KEY// }" ]]; then
        CONSUL_ENCRYPT_KEY=$(generate_consul_key_with_logs)
        log_info "Nova chave de criptografia gerada automaticamente"
      else
        log_info "Usando chave de criptografia fornecida"
      fi
      
      log_info "- Juntar-se a cluster: ${CONSUL_JOIN}"
      if [[ "${CONSUL_JOIN,,}" == "s" ]]; then
        log_info "- Servidores: ${CONSUL_SERVERS}"
      fi
    fi
    
    # Instala e configura o Consul
    setup_consul "$CONSUL_USER" "$CONSUL_GROUP" "$CONSUL_DATA_DIR" "$CONSUL_HCL" \
                "$CONSUL_JOIN" "$CONSUL_SERVERS" "$CONSUL_BOOTSTRAP_EXPECT" \
                "$CONSUL_ENCRYPT_KEY" "$CONSUL_ADVERTISE_ADDR" "$DC" "$NODE_NAME"
  fi
  
  # Configuração do Nomad
  if [[ "${INSTALL_NOMAD,,}" == "s" ]]; then
    if [[ "$INTERACTIVE" == "true" ]]; then
      # Perguntas específicas do Nomad
      log "Escolha o papel do Nomad:"
      log "  1) Servidor"
      log "  2) Cliente"
      log "  3) Ambos (Servidor e Cliente)"
      read -p "Opção [${NOMAD_ROLE}]: " input
      NOMAD_ROLE=${input:-$NOMAD_ROLE}
      
      read -p "Nome da região [${REGION}]: " input
      REGION=${input:-$REGION}
      
      read -p "Nome do datacenter [${DC}]: " input
      DC=${input:-$DC}
      
      read -p "Nome do nó [${NODE_NAME}]: " input
      NODE_NAME=${input:-$NODE_NAME}
      
      # Pergunta sobre bootstrap_expect apenas para servidores
      if [[ "$NOMAD_ROLE" == "1" || "$NOMAD_ROLE" == "3" ]]; then
        read -p "Número de servidores esperados para bootstrap (bootstrap_expect) [${NOMAD_BOOTSTRAP_EXPECT}]: " input
        NOMAD_BOOTSTRAP_EXPECT=${input:-$NOMAD_BOOTSTRAP_EXPECT}
      fi
      
      # Juntar-se a cluster existente
      read -p "Juntar-se a cluster Nomad existente? (s/n) [${NOMAD_JOIN}]: " input
      NOMAD_JOIN=${input:-$NOMAD_JOIN}
      
      if [[ "${NOMAD_JOIN,,}" == "s" ]]; then
        read -p "Lista de servidores Nomad (separados por vírgula): " NOMAD_SERVERS
      fi
    else
      # Modo não-interativo
      log_info "Configuração do Nomad em modo não-interativo:"
      
      case "$NOMAD_ROLE" in
        1) log_info "- Papel: Servidor" ;;
        2) log_info "- Papel: Cliente" ;;
        3) log_info "- Papel: Ambos (Servidor e Cliente)" ;;
      esac
      
      log_info "- Região: ${REGION}"
      log_info "- Datacenter: ${DC}"
      log_info "- Nome do Nó: ${NODE_NAME}"
      log_info "- Juntar-se a cluster: ${NOMAD_JOIN}"
      
      if [[ "${NOMAD_JOIN,,}" == "s" ]]; then
        log_info "- Servidores: ${NOMAD_SERVERS}"
      fi
    fi
    
    # Instala e configura o Nomad
    setup_nomad "$NOMAD_ROLE" "$REGION" "$DC" "$NODE_NAME" "$DATA_DIR" \
               "$NOMAD_USER" "$NOMAD_GROUP" "$NOMAD_HCL" "$NOMAD_JOIN" \
               "$NOMAD_SERVERS" "$NOMAD_BOOTSTRAP_EXPECT"
  fi
  
  # Validação da configuração
  log_info "Validando configuração..."
  errors=0
  
  if [[ "${INSTALL_CONSUL,,}" == "s" ]]; then
    validate_consul_config "$CONSUL_HCL" "$CONSUL_JOIN" "$CONSUL_SERVERS" "$CONSUL_BOOTSTRAP_EXPECT" "$CONSUL_ENCRYPT_KEY"
    errors=$((errors + $?))
  fi
  
  if [[ "${INSTALL_NOMAD,,}" == "s" ]]; then
    validate_nomad_config "$NOMAD_HCL" "$INSTALL_CONSUL"
    errors=$((errors + $?))
  fi
  
  if [[ $errors -gt 0 ]]; then
    log_warn "Foram encontrados $errors problemas na configuração. Verifique os avisos acima."
  else
    log_info "Configuração validada com sucesso!"
  fi
  
  # Exibe resumo da instalação
  show_summary
  
  log "Instalação concluída!"
}

# Executa a função principal
main "$@"