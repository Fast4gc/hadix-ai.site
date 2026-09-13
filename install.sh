#!/usr/bin/env bash
#
# Hadix AI — instalador do backend na VPS
#
# Uso:
#   curl -fsSLO https://raw.githubusercontent.com/Fast4gc/hadix.app/main/install.sh
#   chmod +x install.sh
#   sudo ./install.sh
#
# Flags:
#   -y, --yes            Modo não interativo: usa variáveis de ambiente já definidas
#                        ou gera segredos, sem perguntar.
#   -i, --interactive    Força o modo interativo (perguntar tudo).
#   --skip-env           Não cria nem altera um .env existente.
#   -f, --force-env      Recria o .env do zero (sobrescreve o antigo).
#   -d, --dir <caminho>  Diretório de instalação (padrão: /opt/hadix).
#   --no-docker          Não instala o Docker (presume que já está instalado).
#
# Exemplo não interativo:
#   EMAIL=voce@exemplo.com API_DOMAIN=api.exemplo.com DRIVE_DOMAIN=drive.exemplo.com \
#   ALLOWED_ORIGINS=https://exemplo.com \
#   sudo -E ./install.sh -y
#
# Variáveis de ambiente aceitas (todas opcionais):
#   EMAIL, API_DOMAIN, DRIVE_DOMAIN, ALLOWED_ORIGINS, OLLAMA_MODEL, DRIVE_QUOTA,
#   API_TOKEN, POSTGRES_PASSWORD, NEXTCLOUD_ADMIN_PASSWORD, DRIVE_PASSWORD,
#   HADIX_REPO_URL, HADIX_BRANCH, HADIX_DIR, HADIX_SKIP_APT
#

set -euo pipefail

# ------------------------------ configuração base ---------------------------
HADIX_REPO_URL="${HADIX_REPO_URL:-https://github.com/Fast4gc/hadix.app.git}"
HADIX_BRANCH="${HADIX_BRANCH:-main}"
HADIX_DIR="${HADIX_DIR:-/opt/hadix}"
MODEL_DEFAULT="${OLLAMA_MODEL:-qwen3:4b}"
QUOTA_DEFAULT="${DRIVE_QUOTA:-20 GB}"

INTERACTIVE=1
FORCE_ENV=0
SKIP_ENV=0
INSTALL_DOCKER=1

COMPOSE_DIR="$HADIX_DIR/backend"
ENV_FILE="$COMPOSE_DIR/.env"
SETUP_PHP="$COMPOSE_DIR/scripts/setup-drive.php"

info() { printf '\033[1;36m[i]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) INTERACTIVE=0; shift ;;
    -i|--interactive) INTERACTIVE=1; shift ;;
    --skip-env) SKIP_ENV=1; FORCE_ENV=0; shift ;;
    -f|--force-env) FORCE_ENV=1; SKIP_ENV=0; shift ;;
    -d|--dir) HADIX_DIR="$2"; shift 2 ;;
    --no-docker) INSTALL_DOCKER=0; shift ;;
    -h|--help) usage ;;
    *) die "Argumento desconhecido: $1 (use --help)" ;;
  esac
done

COMPOSE_DIR="$HADIX_DIR/backend"
ENV_FILE="$COMPOSE_DIR/.env"
SETUP_PHP="$COMPOSE_DIR/scripts/setup-drive.php"

# --------------------------------- pré-checagens ----------------------------
[ "$(id -u)" -eq 0 ] || die "Execute com sudo: sudo ./install.sh"

mem_gb=0
if [ -r /proc/meminfo ]; then
  mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
fi
if [ "$mem_gb" -gt 0 ] && [ "$mem_gb" -lt 16 ]; then
  warn "VPS com ${mem_gb} GB de RAM — o mínimo recomendado pelo stack é 16 GB."
fi

banner() {
  printf '\033[1;90m'
  printf ' ======================================\n'
  printf '   Hadix AI — instalador do backend\n'
  printf ' ======================================\n'
  printf '\033[0m'
}

# -------------------------------- Docker ------------------------------------
install_docker() {
  if require_cmd docker && docker compose version >/dev/null 2>&1; then
    ok "Docker + Docker Compose já instalados."
    return
  fi
  if [ "$INSTALL_DOCKER" -eq 0 ]; then
    require_cmd docker || die "Docker não encontrado e --no-docker foi passado."
    die "Docker Compose v2 não encontrado. Instale o plugin ou remova --no-docker."
  fi

  info "Instalando Docker Engine + Docker Compose..."

  if require_cmd apt-get && [ -z "${HADIX_SKIP_APT:-}" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq git curl openssl ca-certificates gnupg lsb-release >/dev/null
  fi

  require_cmd curl || die "curl é necessário. Instale com: apt-get install -y curl"

  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true

  for _ in $(seq 1 30); do
    require_cmd docker && docker info >/dev/null 2>&1 && break
    sleep 2
  done
  require_cmd docker || die "Falha ao iniciar o Docker."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 não encontrado."

  ok "Docker pronto."
}

# -------------------------------- repositório -------------------------------
clone_repo() {
  if [ -d "$HADIX_DIR/.git" ]; then
    info "Atualizando o repositório em $HADIX_DIR"
    git -C "$HADIX_DIR" fetch --quiet --depth=1 origin "$HADIX_BRANCH"
    git -C "$HADIX_DIR" reset --hard --quiet "origin/$HADIX_BRANCH"
  else
    if [ -e "$HADIX_DIR" ] && [ ! -d "$HADIX_DIR/.git" ]; then
      die "$HADIX_DIR existe e não é um repositório git. Remova ou use -d <outro-diretorio>."
    fi
    info "Baixando o repositório para $HADIX_DIR"
    mkdir -p "$(dirname "$HADIX_DIR")"
    git clone --quiet --depth=1 -b "$HADIX_BRANCH" "$HADIX_REPO_URL" "$HADIX_DIR"
  fi
  [ -d "$COMPOSE_DIR" ] || die "Diretório backend/ não encontrado no repositório."
}

# --------------------- script extra do Nextcloud (drive) --------------------
# O compose.yaml monta ./scripts/setup-drive.php dentro do contêiner do Nextcloud.
# Como o arquivo não é versionado, criamos uma versão padrão se ele não existir.
ensure_setup_php() {
  [ -f "$SETUP_PHP" ] && return
  warn "scripts/setup-drive.php não existe — gerando uma versão padrão."
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
  ok "scripts/setup-drive.php criado (revise o conteúdo padrão se necessário)."
}

# ---------------------------------- .env ------------------------------------
gen_secret() { openssl rand -hex 32; }

read_value() {
  local var="$1" label="$2" def="${3:-}"
  local input
  [ -n "${!var:-}" ] && return 0   # valor já veio do ambiente — não pergunta
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
  require_cmd openssl || die "openssl é necessário (apt-get install -y openssl)"

  if [ -f "$ENV_FILE" ] && [ "$FORCE_ENV" -eq 0 ] && [ "$SKIP_ENV" -eq 0 ]; then
    if [ "$INTERACTIVE" -eq 1 ]; then
      if ask_yes "Já existe um .env. Reaproveitar as configurações atuais?"; then
        SKIP_ENV=1
      else
        FORCE_ENV=1
      fi
    else
      info "Reaproveitando o .env existente em $ENV_FILE"
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
    info "Configuração do ambiente (deixe em branco para usar o padrão):"
    read_value ACME_EMAIL     "E-mail para o certificado TLS (ACME)"
    read_value API_DOMAIN     "Domínio da API   (registro A -> IP da VPS)"
    read_value DRIVE_DOMAIN   "Domínio do drive (registro A -> IP da VPS)"
    read_value ALLOWED_ORIGINS "Origens CORS permitidas, separadas por vírgula (vazio = nenhuma)"
    if [ -z "$API_DOMAIN" ] || [ -z "$DRIVE_DOMAIN" ]; then
      die "Preencha os domínios da API e do drive."
    fi
  else
    for v in ACME_EMAIL API_DOMAIN DRIVE_DOMAIN; do
      [ -n "${!v:-}" ] || die "Em modo --yes, defina $v via variável de ambiente."
    done
    OLLAMA_MODEL="${OLLAMA_MODEL:-$MODEL_DEFAULT}"
    DRIVE_QUOTA="${DRIVE_QUOTA:-$QUOTA_DEFAULT}"
    ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-}"
  fi

  [ -n "${ACME_EMAIL:-}" ] || die "Defina ACME_EMAIL (e-mail para o certificado TLS)."
  [ -n "${API_TOKEN:-}" ] || API_TOKEN="$(gen_secret)"
  [ -n "${POSTGRES_PASSWORD:-}" ] || POSTGRES_PASSWORD="$(gen_secret)"
  [ -n "${NEXTCLOUD_ADMIN_PASSWORD:-}" ] || NEXTCLOUD_ADMIN_PASSWORD="$(gen_secret)"
  [ -n "${DRIVE_PASSWORD:-}" ] || DRIVE_PASSWORD="$(gen_secret)"

  write_env
  set -a; source "$ENV_FILE"; set +a
  ok "Arquivo .env criado em $ENV_FILE (permissões 600)."
}

# ---------------------------------- deploy ----------------------------------
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
  cd "$COMPOSE_DIR"
  info "Subindo a stack Hadix (compila a API e baixa as imagens — pode levar alguns minutos)."
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
  require_cmd ufw || return 0
  ufw status 2>/dev/null | grep -q "Status: active" && return 0
  if [ "$INTERACTIVE" -eq 1 ]; then
    if ask_yes "UFW detectado, mas inativo. Abrir as portas 80/443?"; then
      ufw allow 80/tcp
      ufw allow 443/tcp
      ufw allow 443/udp
      ok "Portas 80/443 liberadas no UFW."
    fi
  fi
}

# --------------------------------- resumo -----------------------------------
summary() {
  echo
  ok "Instalação concluída!"
  echo
  echo "  API   : https://$API_DOMAIN"
  echo "  Drive : https://$DRIVE_DOMAIN"
  echo "          admin: hadix-admin / (sua NEXTCLOUD_ADMIN_PASSWORD)"
  echo "  Modelo: $OLLAMA_MODEL"
  echo
  echo "Comandos úteis (na pasta $COMPOSE_DIR):"
  echo "  docker compose ps"
  echo "  docker compose logs -f --tail=200 api"
  echo "  docker compose exec ollama ollama pull <outro-modelo>"
  echo "  docker compose exec -T postgres pg_dump -U nextcloud nextcloud > backup.sql"
  echo
  warn "Guarde o arquivo $ENV_FILE em local seguro — ele contém todos os segredos."
}

# ---------------------------------- main ------------------------------------
main() {
  banner
  [ "$INTERACTIVE" -eq 1 ] && echo
  install_docker
  clone_repo
  ensure_setup_php
  configure_env
  deploy
  maybe_firewall
  summary
}

main "$@"