#!/usr/bin/env bash
# ==============================================================================
# Funções comuns para scripts de instalação
# ==============================================================================

# Cores para os logs
VERDE='\033[0;32m'
AMARELO='\033[1;33m'
VERMELHO='\033[0;31m'
AZUL='\033[0;34m'
RESET='\033[0m'

# Funções de log
log()  { echo -e "${VERDE}[postinstall]${RESET} $*"; }
log_warn() { echo -e "${AMARELO}[postinstall][AVISO]${RESET} $*"; }
log_info() { echo -e "${AZUL}[postinstall][INFO]${RESET} $*"; }
fail() { echo -e "${VERMELHO}[postinstall][ERRO]${RESET} $*" >&2; exit 1; }
on_err(){ fail "Falha na linha $1: comando '$2' (último código: $3)"; }

# Função para tentar comandos com retry
retry() {
  local attempts="${1:-5}"; shift || true
  local delay=3 i=1
  until "$@"; do
    local rc=$?
    if (( i >= attempts )); then return "$rc"; fi
    log "Comando falhou (tentativa $i/$attempts, rc=$rc). Repetindo em ${delay}s…"
    sleep "$delay"; i=$((i+1)); delay=$((delay*2))
  done
}

# Função para montar a lista JSON retry_join a partir de entrada
montar_retry_join() {
  local input="$1"
  local RJ="[]"

  # Remove espaços e verifica se há conteúdo
  if [[ -n "${input// }" ]]; then
    local arr=()
    IFS=',' read -ra arr <<<"$input"

    RJ="["
    local first=1
    for j in "${arr[@]}"; do
      j="$(echo "$j" | xargs)"  # Remove espaços extras
      [[ -z "$j" ]] && continue
      if (( first )); then
        RJ+="\"$j\""
        first=0
      else
        RJ+=", \"$j\""
      fi
    done
    RJ+="]"
  fi

  echo "$RJ"
}

# Função para verificar se o script está sendo executado como root
check_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "Execute como root (sudo)."
  fi
}