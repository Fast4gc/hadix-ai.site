#!/usr/bin/env bash
#
# Hadix AI — instalador do backend
#
# Uso:
#   sudo ./install.sh
#
# Flags:
#   -y, --yes            Modo não interativo (usa variáveis de ambiente).
#   --skip-env           Não cria nem altera o .env existente.
#   -f, --force-env      Recria o .env do zero.
#   --no-docker          Não instala o Docker (presume que já está instalado).
#

set -euo pipefail

# -------------------------------- cores -------------------------------------
info() { printf '\033[1;36m[i]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# -------------------------------- variáveis ---------------------------------
INTERACTIVE=1
FORCE_ENV=0
SKIP_ENV=0
INSTALL_DOCKER=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backend"
ENV_FILE="$BACKEND_DIR/.env"
SETUP_PHP="$BACKEND_DIR/scripts/setup-drive.php"
MODEL_DEFAULT="${OLLAMA_MODEL:-qwen3:4b}"
QUOTA_DEFAULT="${DRIVE_QUOTA:-20 GB}"

# -------------------------------- argumentos --------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)          INTERACTIVE=0; shift ;;
    --skip-env)        SKIP_ENV=1; FORCE_ENV=0; shift ;;
    -f|--force-env)    FORCE_ENV=1; SKIP_ENV=0; shift ;;
    --no-docker)       INSTALL_DOCKER=0; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Argumento desconhecido: $1" ;;
  esac
done

# -------------------------------- pré-checagens -----------------------------
[ "$(id -u)" -eq 0 ] || die "Execute com sudo: sudo ./install.sh"
[ -d "$BACKEND_DIR" ] || die "backend/ não encontrado em $SCRIPT_DIR"

mem_gb=0
if [ -r /proc/meminfo ]; then
  mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
fi
if [ "$mem_gb" -gt 0 ] && [ "$mem_gb" -lt 16 ]; then
  warn "VPS com ${mem_gb} GB de RAM — mínimo recomendado: 16 GB."
fi

printf '\033[1;90m'
printf ' ======================================\n'
printf '   Hadix AI — instalador do backend\n'
printf ' ======================================\n'
printf '\033[0m\n'

# -------------------------------- Docker ------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker + Docker Compose já instalados."
    return
  fi

  if [ "$INSTALL_DOCKER" -eq 0 ]; then
    command -v docker >/dev/null 2>&1 || die "Docker não encontrado e --no-docker foi passado."
    die "Docker Compose v2 não encontrado."
  fi

  info "Instalando Docker Engine + Docker Compose..."

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq git curl openssl ca-certificates gnupg >/dev/null
  fi

  command -v curl >/dev/null 2>&1 || die "curl necessário. Instale: apt-get install -y curl"

  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
  systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true

  for _ in $(seq 1 30); do
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && break
    sleep 2
  done

  command -v docker >/dev/null 2>&1 || die "Falha ao iniciar o Docker."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 não encontrado."

  ok "Docker pronto."
}

# -------------------------------- setup-drive.php ----------------------------
# O compose monta ./scripts/setup-drive.php no Nextcloud.
# Arquivo não versionado — geramos se não existir.
ensure_setup_php() {
  [ -f "$SETUP_PHP" ] && return
  warn "scripts/setup-drive.php não existe — gerando versão padrão."
  mkdir -p "$(dirname "$SETUP_PHP")"
  cat > "$SETUP_PHP" <<'PHP'
<?php
declare(strict_types=1);

$user  = getenv('HADIX_DRIVE_USER') ?: 'hadix';
$pass  = (string) getenv('HADIX_DRIVE_PASSWORD');
$quota = getenv('HADIX_DRIVE_QUOTA') ?: '20 GB';

if ($pass === '') {
    fwrite(STDERR, "[hadix] HADIX_DRIVE_PASSWORD nao definida (configure o .env).\n");
    exit(1);
}

function occ(array $args): array {
    $cmd  = array_merge(['php', '/var/www/html/occ'], $args);
    $out  = [];
    $code = 0;
    exec(implode(' ', array_map('escapeshellarg', $cmd)) . ' 2>&1', $out, $code);
    return ['out' => implode("\n", $out), 'code' => $code];
}

$list = occ(['user:list']);
if (strpos($list['out'], "$user:") === false) {
    echo "[hadix] criando o usuario do drive: $user\n";
    $r = occ(['user:add', '--display-name', 'Hadix Drive', '--password', $pass, $user]);
    if ($r['code'] !== 0) {
        fwrite(STDERR, "[hadix] falha ao criar o usuario:\n" . $r['out'] . "\n");
        exit(1);
    }
} else {
    echo "[hadix] usuario $user ja existe.\n";
}

$r = occ(['user:setting', $user, 'files', 'quota', '--value', $quota]);
if ($r['code'] !== 0) {
    fwrite(STDERR, "[hadix] falha ao definir a quota:\n" . $r['out'] . "\n");
    exit(1);
}
echo "[hadix] quota definida: $quota\n";
echo "[hadix] configuracao do drive concluida.\n";
PHP
  chmod 644 "$SETUP_PHP"
  ok "scripts/setup-drive.php criado."
}

# -------------------------------- .env --------------------------------------
gen_secret() { openssl rand -hex 32; }

read_value() {
  local var="$1" label="$2" def="${3:-}"
  local input
  [ -n "${!var:-}" ] && return 0
  printf '%s' "$label" >&2
  [ -n "$def" ] && printf ' [%s]' "$def" >&2
  printf ': ' >&2
  IFS= read -r input
  [ -z "$input" ] && input="$def"
  printf -v "$var" '%s' "$input"
}

ask_yes() {
  local def="${2:-s}" input
  printf '%s [%s]: ' "$1" "$def" >&2
  IFS= read -r input
  [ -z "$input" ] && input="$def"
  case "$input" in
    s|S|sim|y|Y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

write_env() {
  cat > "$ENV_FILE" <<EOF
ACME_EMAIL="$ACME_EMAIL"
API_DOMAIN="$API_DOMAIN"
DRIVE_DOMAIN="$DRIVE_DOMAIN"
API_TOKEN="$API_TOKEN"
OLLAMA_MODEL="$OLLAMA_MODEL"
ALLOWED_ORIGINS="$ALLOWED_ORIGINS"
POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
NEXTCLOUD_ADMIN_PASSWORD="$NEXTCLOUD_ADMIN_PASSWORD"
DRIVE_PASSWORD="$DRIVE_PASSWORD"
DRIVE_QUOTA="$DRIVE_QUOTA"
EOF
  chmod 600 "$ENV_FILE"
}

configure_env() {
  command -v openssl >/dev/null 2>&1 || die "openssl necessário (apt-get install -y openssl)"

  if [ -f "$ENV_FILE" ] && [ "$FORCE_ENV" -eq 0 ] && [ "$SKIP_ENV" -eq 0 ]; then
    if [ "$INTERACTIVE" -eq 1 ]; then
      if ask_yes "Já existe um .env. Reaproveitar?"; then
        SKIP_ENV=1
      else
        FORCE_ENV=1
      fi
    else
      info "Reaproveitando o .env existente."
      SKIP_ENV=1
    fi
  fi

  if [ "$SKIP_ENV" -eq 1 ]; then
    [ -f "$ENV_FILE" ] || die ".env não encontrado em $ENV_FILE"
    set -a; source "$ENV_FILE"; set +a
    for v in ACME_EMAIL API_DOMAIN DRIVE_DOMAIN API_TOKEN POSTGRES_PASSWORD \
             NEXTCLOUD_ADMIN_PASSWORD DRIVE_PASSWORD; do
      [ -n "${!v:-}" ] || die "Falta a variável $v no .env"
    done
    OLLAMA_MODEL="${OLLAMA_MODEL:-$MODEL_DEFAULT}"
    DRIVE_QUOTA="${DRIVE_QUOTA:-$QUOTA_DEFAULT}"
    return
  fi

  if [ "$INTERACTIVE" -eq 1 ]; then
    info "Configuração (deixe em branco para usar o padrão):"
    read_value ACME_EMAIL      "E-mail para o certificado TLS (ACME)"
    read_value API_DOMAIN      "Domínio da API   (registro A -> IP da VPS)"
    read_value DRIVE_DOMAIN    "Domínio do drive (registro A -> IP da VPS)"
    read_value ALLOWED_ORIGINS "Origens CORS, separadas por vírgula (vazio = nenhuma)"
    [ -n "$API_DOMAIN" ] && [ -n "$DRIVE_DOMAIN" ] || die "Preencha os domínios."
  else
    for v in ACME_EMAIL API_DOMAIN DRIVE_DOMAIN; do
      [ -n "${!v:-}" ] || die "Em modo -y, defina $v via variável de ambiente."
    done
    OLLAMA_MODEL="${OLLAMA_MODEL:-$MODEL_DEFAULT}"
    DRIVE_QUOTA="${DRIVE_QUOTA:-$QUOTA_DEFAULT}"
    ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-}"
  fi

  [ -n "${ACME_EMAIL:-}" ] || die "Defina ACME_EMAIL."
  [ -n "${API_TOKEN:-}" ]                  || API_TOKEN="$(gen_secret)"
  [ -n "${POSTGRES_PASSWORD:-}" ]          || POSTGRES_PASSWORD="$(gen_secret)"
  [ -n "${NEXTCLOUD_ADMIN_PASSWORD:-}" ]   || NEXTCLOUD_ADMIN_PASSWORD="$(gen_secret)"
  [ -n "${DRIVE_PASSWORD:-}" ]             || DRIVE_PASSWORD="$(gen_secret)"

  write_env
  set -a; source "$ENV_FILE"; set +a
  ok "Arquivo .env criado em $ENV_FILE (permissões 600)."
}

# -------------------------------- deploy ------------------------------------
wait_for() {
  local cmd="$1" label="$2" tries="${3:-60}"
  info "Aguardando $label..."
  for _ in $(seq 1 "$tries"); do
    if bash -c "$cmd" >/dev/null 2>&1; then
      ok "$label pronto."
      return 0
    fi
    sleep 5
  done
  die "Tempo esgotado aguardando $label."
}

deploy() {
  cd "$BACKEND_DIR"
  info "Subindo a stack Hadix..."
  docker compose up -d --build

  info "Baixando o modelo Ollama: $OLLAMA_MODEL"
  wait_for "docker compose exec -T ollama ollama list" "o Ollama ficar saudável" 60
  docker compose exec -T ollama ollama pull "$OLLAMA_MODEL"

  info "Configurando o usuário do drive no Nextcloud."
  wait_for "docker compose exec -T nextcloud php occ status 2>/dev/null | grep -qE 'installed: true'" \
           "o Nextcloud concluir a instalação" 90
  docker compose exec -T -u www-data nextcloud php /opt/hadix/setup-drive.php
}

# -------------------------------- firewall ----------------------------------
maybe_firewall() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q "Status: active" && return 0
  if [ "$INTERACTIVE" -eq 1 ]; then
    if ask_yes "UFW detectado mas inativo. Abrir as portas 80/443?"; then
      ufw allow 80/tcp
      ufw allow 443/tcp
      ufw allow 443/udp
      ok "Portas 80/443 liberadas no UFW."
    fi
  fi
}

# -------------------------------- resumo ------------------------------------
summary() {
  echo
  ok "Instalação concluída!"
  echo
  echo "  API   : https://$API_DOMAIN"
  echo "  Drive : https://$DRIVE_DOMAIN"
  echo "          admin: hadix-admin / (sua NEXTCLOUD_ADMIN_PASSWORD)"
  echo "  Modelo: $OLLAMA_MODEL"
  echo
  echo "Comandos úteis (em $BACKEND_DIR):"
  echo "  docker compose ps"
  echo "  docker compose logs -f --tail=200 api"
  echo "  docker compose exec ollama ollama pull <outro-modelo>"
  echo "  docker compose exec -T postgres pg_dump -U nextcloud nextcloud > backup.sql"
  echo
  warn "Guarde o arquivo $ENV_FILE em local seguro."
}

# -------------------------------- main --------------------------------------
main() {
  install_docker
  ensure_setup_php
  configure_env
  deploy
  maybe_firewall
  summary
}

main "$@"