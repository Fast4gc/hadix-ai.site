#!/usr/bin/env bash
#
# Hadix AI — instalador/gerenciador do backend (autossuficiente)
#
# Este script NAO depende do GitHub: ele gera todos os arquivos do backend
# (compose.yaml, Caddyfile, API, Dockerfile, setup-drive.php, .env) na pasta
# /opt/hadix e instala o comando "hadix" para gerenciar tudo com sudo.
#
# Uso:
#   crie o arquivo /tmp/install.sh com o conteudo deste script no VPS e rode:
#     sudo bash /tmp/install.sh
#
# Ou rode direto (requer o script acessivel por URL publica):
#     wget -qO- URL_DO_SCRIPT | sudo bash
#
# Depois de instalado, use:
#     sudo hadix            -> mostra o help
#     sudo hadix status     -> status dos containers
#     sudo hadix start      -> sobe a stack
#     sudo hadix stop       -> derruba a stack
#     sudo hadix logs       -> logs da API
#     sudo hadix update     -> atualiza (recria .env se faltar) e reinicia
#

set -euo pipefail

# -------------------------------- cores -------------------------------------
info() { printf '\033[1;36m[i]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# -------------------------------- variaveis ---------------------------------
INSTALL_DIR="${HADIX_DIR:-/opt/hadix}"
BACKEND_DIR="$INSTALL_DIR/backend"
ENV_FILE="$BACKEND_DIR/.env"
SETUP_PHP="$BACKEND_DIR/scripts/setup-drive.php"
BIN_HADIX="/usr/local/bin/hadix"
MODEL_DEFAULT="${OLLAMA_MODEL:-qwen3:4b}"
QUOTA_DEFAULT="${DRIVE_QUOTA:-20 GB}"
INTERACTIVE=1

# -------------------------------- argumentos --------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)       INTERACTIVE=0; shift ;;
    -d|--dir)       INSTALL_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Argumento desconhecido: $1" ;;
  esac
done

BACKEND_DIR="$INSTALL_DIR/backend"
ENV_FILE="$BACKEND_DIR/.env"

# -------------------------------- pre-checagens -----------------------------
[ "$(id -u)" -eq 0 ] || die "Execute com sudo: sudo bash install.sh"

mem_gb=0
if [ -r /proc/meminfo ]; then
  mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
fi
if [ "$mem_gb" -gt 0 ] && [ "$mem_gb" -lt 16 ]; then
  warn "VPS com ${mem_gb} GB de RAM — minimo recomendado: 16 GB."
fi

printf '\033[1;90m'
printf ' =============================================\n'
printf '   Hadix AI — instalador autossuficiente\n'
printf '   instalando em: %s\n' "$INSTALL_DIR"
printf ' =============================================\n'
printf '\033[0m\n'

# -------------------------------- Docker ------------------------------------
install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker + Docker Compose ja instalados."
    return
  fi

  info "Instalando Docker Engine + Docker Compose..."

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl wget openssl ca-certificates gnupg >/dev/null
  fi

  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "curl ou wget necessario."

  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker >/dev/null 2>&1 || true
  systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true

  for _ in $(seq 1 30); do
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && break
    sleep 2
  done

  command -v docker >/dev/null 2>&1 || die "Falha ao iniciar o Docker."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 nao encontrado."

  ok "Docker pronto."
}

# ------------------------ gerar arquivos do backend --------------------------
write_backend_files() {
  info "Criando estrutura em $BACKEND_DIR"
  mkdir -p "$BACKEND_DIR/caddy" "$BACKEND_DIR/api/src" "$BACKEND_DIR/scripts"

  # compose.yaml
  cat > "$BACKEND_DIR/compose.yaml" <<'COMPOSE'
name: hadix

x-logging: &logging
  driver: json-file
  options:
    max-size: 10m
    max-file: '3'

services:
  caddy:
    image: caddy:2.11.4-alpine
    restart: unless-stopped
    ports: ['80:80', '443:443', '443:443/udp']
    environment:
      ACME_EMAIL: ${ACME_EMAIL:?Configure .env}
      API_DOMAIN: ${API_DOMAIN:?Configure .env}
      DRIVE_DOMAIN: ${DRIVE_DOMAIN:?Configure .env}
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      edge:
        ipv4_address: 172.30.50.2
    mem_limit: 256m
    cpus: 0.5
    logging: *logging

  api:
    build: ./api
    restart: unless-stopped
    init: true
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    environment:
      API_TOKEN: ${API_TOKEN:?Configure .env}
      OLLAMA_URL: http://ollama:11434
      OLLAMA_MODEL: ${OLLAMA_MODEL:-qwen3:4b}
      DRIVE_DOMAIN: ${DRIVE_DOMAIN}
      ALLOWED_ORIGINS: ${ALLOWED_ORIGINS:-}
    networks: [edge, inference]
    mem_limit: 384m
    cpus: 0.5
    logging: *logging

  ollama:
    image: ollama/ollama:0.34.0
    restart: unless-stopped
    environment:
      OLLAMA_HOST: 0.0.0.0:11434
      OLLAMA_MODEL: ${OLLAMA_MODEL:-qwen3:4b}
      OLLAMA_NUM_PARALLEL: '1'
      OLLAMA_MAX_LOADED_MODELS: '1'
      OLLAMA_MAX_QUEUE: '2'
      OLLAMA_CONTEXT_LENGTH: '2048'
      OLLAMA_KEEP_ALIVE: 5m
    volumes: [ollama_data:/root/.ollama]
    networks: [inference]
    mem_limit: 12g
    cpus: 3.0
    healthcheck:
      test: ['CMD', 'ollama', 'list']
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    logging: *logging

  postgres:
    image: postgres:17-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?Configure .env}
    volumes: [postgres_data:/var/lib/postgresql/data]
    networks: [data]
    mem_limit: 1g
    cpus: 0.75
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U nextcloud -d nextcloud']
      interval: 10s
      timeout: 5s
      retries: 10
    logging: *logging

  redis:
    image: redis:8-alpine
    restart: unless-stopped
    command: ['redis-server', '--maxmemory', '192mb', '--maxmemory-policy', 'noeviction']
    networks: [data]
    mem_limit: 256m
    cpus: 0.25
    logging: *logging

  nextcloud:
    image: nextcloud:32.0.15-apache
    restart: unless-stopped
    depends_on:
      postgres: { condition: service_healthy }
      redis: { condition: service_started }
    environment: &nextcloud-env
      POSTGRES_HOST: postgres
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      REDIS_HOST: redis
      NEXTCLOUD_ADMIN_USER: hadix-admin
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD:?Configure .env}
      NEXTCLOUD_TRUSTED_DOMAINS: ${DRIVE_DOMAIN}
      TRUSTED_PROXIES: 172.30.50.2
      OVERWRITEPROTOCOL: https
      OVERWRITEHOST: ${DRIVE_DOMAIN}
      OVERWRITECLIURL: https://${DRIVE_DOMAIN}
      PHP_MEMORY_LIMIT: 512M
      PHP_UPLOAD_LIMIT: 2G
      APACHE_BODY_LIMIT: '2147483648'
      HADIX_DRIVE_USER: hadix
      HADIX_DRIVE_PASSWORD: ${DRIVE_PASSWORD:?Configure .env}
      HADIX_DRIVE_QUOTA: ${DRIVE_QUOTA:-20 GB}
    volumes: &nextcloud-volumes
      - nextcloud_html:/var/www/html
      - nextcloud_data:/var/www/html/data
      - ./scripts/setup-drive.php:/opt/hadix/setup-drive.php:ro
    networks: [edge, data]
    mem_limit: 3g
    cpus: 1.5
    logging: *logging

  cron:
    image: nextcloud:32.0.15-apache
    restart: unless-stopped
    entrypoint: /cron.sh
    environment: *nextcloud-env
    volumes: *nextcloud-volumes
    networks: [data]
    depends_on: [nextcloud]
    mem_limit: 768m
    cpus: 0.5
    logging: *logging

networks:
  edge:
    ipam:
      config: [{ subnet: 172.30.50.0/24 }]
  # Egress is needed to download models; no inference service publishes host ports.
  inference: {}
  data:
    internal: true

volumes:
  caddy_data:
  caddy_config:
  ollama_data:
  postgres_data:
  nextcloud_html:
  nextcloud_data:
COMPOSE

  # Caddyfile
  cat > "$BACKEND_DIR/caddy/Caddyfile" <<'CADDY'
{
  email {$ACME_EMAIL}
  admin off
}

{$API_DOMAIN} {
  encode zstd gzip
  header {
    Strict-Transport-Security "max-age=31536000"
    -Server
  }
  reverse_proxy api:3000 {
    transport http {
      response_header_timeout 250s
    }
  }
}

{$DRIVE_DOMAIN} {
  encode zstd gzip
  header {
    Strict-Transport-Security "max-age=31536000"
    -Server
  }
  redir /.well-known/carddav /remote.php/dav 301
  redir /.well-known/caldav /remote.php/dav 301
  reverse_proxy nextcloud:80
}
CADDY

  # Dockerfile da API
  cat > "$BACKEND_DIR/api/Dockerfile" <<'DKRFILE'
FROM node:24-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --chown=node:node src ./src
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 CMD node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "src/server.mjs"]
DKRFILE

  cat > "$BACKEND_DIR/api/.dockerignore" <<'DKIGNORE'
node_modules
test
*.log
.env*
DKIGNORE

  # package.json
  cat > "$BACKEND_DIR/api/package.json" <<'PKG'
{
  "name": "hadix-vps-api",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=24" },
  "scripts": { "start": "node src/server.mjs" },
  "dependencies": {
    "express": "^5.1.0",
    "express-rate-limit": "^8.1.0",
    "helmet": "^8.1.0"
  }
}
PKG

  # server.mjs
  cat > "$BACKEND_DIR/api/src/server.mjs" <<'SERVER'
import { createApp, readConfig } from './app.mjs';
const app = createApp(readConfig());
const server = app.listen(3000, '0.0.0.0', () => console.log('Hadix API listening on :3000'));
server.requestTimeout = 250_000;
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10_000).unref();
});
SERVER

  # app.mjs
  cat > "$BACKEND_DIR/api/src/app.mjs" <<'APP'
import express from 'express';
import helmet from 'helmet';
import { rateLimit } from 'express-rate-limit';
import { createHash, timingSafeEqual } from 'node:crypto';

const digest = value => createHash('sha256').update(value).digest();
export function readConfig(env = process.env) {
  if (!env.API_TOKEN || env.API_TOKEN.length < 32) throw new Error('API_TOKEN deve ter pelo menos 32 caracteres.');
  const ollamaUrl = new URL(env.OLLAMA_URL || 'http://ollama:11434');
  if (!['http:', 'https:'].includes(ollamaUrl.protocol)) throw new Error('OLLAMA_URL invalida.');
  return {
    token: env.API_TOKEN,
    ollamaUrl: ollamaUrl.origin,
    model: env.OLLAMA_MODEL || 'qwen3:4b',
    driveUrl: env.DRIVE_DOMAIN ? `https://${env.DRIVE_DOMAIN}` : null,
    origins: (env.ALLOWED_ORIGINS || '').split(',').map(s => s.trim()).filter(Boolean),
    timeoutMs: 240_000,
    rateMax: 12,
  };
}

export function createApp(config, { fetchImpl = fetch } = {}) {
  const app = express();
  let active = false;
  app.set('trust proxy', 1);
  app.disable('x-powered-by');
  app.use(helmet());
  app.use((_req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));
  app.use((req, res, next) => {
    const origin = req.get('origin');
    if (origin) {
      if (!config.origins.includes(origin)) return res.status(403).json({ error: 'origin_not_allowed' });
      res.set('Access-Control-Allow-Origin', origin);
      res.vary('Origin');
      res.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
      res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    }
    if (req.method === 'OPTIONS') return res.sendStatus(204);
    next();
  });
  app.use(rateLimit({ windowMs: 60_000, limit: config.rateMax, standardHeaders: 'draft-8', legacyHeaders: false,
    message: { error: 'rate_limited', message: 'Aguarde um minuto antes de tentar novamente.' } }));
  app.use((req, res, next) => {
    const auth = req.get('authorization') || '';
    if (!auth.startsWith('Bearer ') || !timingSafeEqual(digest(auth.slice(7)), digest(config.token))) {
      return res.status(401).json({ error: 'unauthorized' });
    }
    next();
  });
  app.use(express.json({ limit: '64kb', strict: true }));
  app.get('/api/config', (_req, res) => res.json({ model: config.model, driveUrl: config.driveUrl, maxParallel: 1 }));
  app.get('/api/ready', async (_req, res) => {
    try {
      const response = await fetchImpl(`${config.ollamaUrl}/api/tags`, { signal: AbortSignal.timeout(5000) });
      if (!response.ok) throw new Error('upstream');
      const data = await response.json();
      const loaded = Array.isArray(data.models) && data.models.some(m => m.name === config.model || m.model === config.model);
      res.status(loaded ? 200 : 503).json({ status: loaded ? 'ready' : 'model_missing', model: config.model });
    } catch { res.status(503).json({ status: 'ollama_unavailable' }); }
  });
  app.post('/api/chat', async (req, res) => {
    const messages = req.body?.messages;
    if (!Array.isArray(messages) || messages.length < 1 || messages.length > 24 ||
      messages.some(m => !m || !['system', 'user', 'assistant'].includes(m.role) || typeof m.content !== 'string' || !m.content.trim() || m.content.length > 8000) ||
      messages.reduce((sum, m) => sum + m.content.length, 0) > 16000) {
      return res.status(400).json({ error: 'invalid_messages', message: 'Envie 1-24 mensagens de texto, ate 16.000 caracteres no total.' });
    }
    if (active) return res.set('Retry-After', '10').status(429).json({ error: 'model_busy' });
    active = true;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), config.timeoutMs);
    const disconnected = () => { if (!res.writableEnded) controller.abort(); };
    res.on('close', disconnected);
    try {
      const response = await fetchImpl(`${config.ollamaUrl}/api/chat`, {
        method: 'POST', signal: controller.signal, headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: config.model,
          messages: messages.map(({ role, content }) => ({ role, content })),
          stream: false, think: false, keep_alive: '5m',
          options: { num_ctx: 2048, num_predict: 512, num_thread: 3, temperature: 0.7 },
        }),
      });
      if (!response.ok) return res.status(response.status === 404 ? 503 : 502).json({ error: response.status === 404 ? 'model_missing' : 'ollama_error' });
      const data = await response.json();
      if (typeof data.message?.content !== 'string') return res.status(502).json({ error: 'invalid_ollama_response' });
      if (!res.destroyed) res.json({ model: config.model, message: { role: 'assistant', content: data.message.content }, done: true });
    } catch {
      if (!res.destroyed) res.status(controller.signal.aborted ? 504 : 502).json({ error: controller.signal.aborted ? 'inference_timeout' : 'ollama_unavailable' });
    } finally {
      clearTimeout(timeout);
      res.off('close', disconnected);
      active = false;
    }
  });
  app.use((_req, res) => res.status(404).json({ error: 'not_found' }));
  app.use((err, _req, res, _next) => {
    if (err.type === 'entity.too.large') return res.status(413).json({ error: 'payload_too_large' });
    if (err instanceof SyntaxError) return res.status(400).json({ error: 'invalid_json' });
    res.status(500).json({ error: 'internal_error' });
  });
  return app;
}
APP

  # setup-drive.php
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

  ok "Arquivos do backend gerados em $BACKEND_DIR"
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
  if [ -e /dev/tty ]; then
    IFS= read -r input </dev/tty || input=""
  else
    IFS= read -r input || input=""
  fi
  [ -z "$input" ] && input="$def"
  printf -v "$var" '%s' "$input"
}

ask_yes() {
  local def="${2:-s}" input
  printf '%s [%s]: ' "$1" "$def" >&2
  if [ -e /dev/tty ]; then
    IFS= read -r input </dev/tty || input="$def"
  else
    IFS= read -r input || input="$def"
  fi
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
  command -v openssl >/dev/null 2>&1 || die "openssl necessario (apt-get install -y openssl)"

  if [ -f "$ENV_FILE" ]; then
    if [ "$INTERACTIVE" -eq 1 ]; then
      if ask_yes "Ja existe um .env em $ENV_FILE. Reaproveitar?"; then
        set -a; source "$ENV_FILE"; set +a
        return
      fi
      warn "Recriando o .env..."
    else
      info "Reaproveitando o .env existente."
      set -a; source "$ENV_FILE"; set +a
      return
    fi
  fi

  if [ "$INTERACTIVE" -eq 1 ]; then
    info "Configuracao (deixe em branco para aceitar o padrao, quando houver):"
    read_value ACME_EMAIL      "E-mail para o certificado TLS (ACME)"
    read_value API_DOMAIN      "Dominio da API   (registro A -> IP da VPS)"
    read_value DRIVE_DOMAIN    "Dominio do drive (registro A -> IP da VPS)"
    read_value ALLOWED_ORIGINS "Origens CORS, separadas por virgula (vazio = nenhuma)"
    [ -n "${API_DOMAIN:-}" ] && [ -n "${DRIVE_DOMAIN:-}" ] || die "Preencha os dominios."
  else
    for v in ACME_EMAIL API_DOMAIN DRIVE_DOMAIN; do
      [ -n "${!v:-}" ] || die "Em modo -y, defina $v via variavel de ambiente."
    done
  fi

  [ -n "${ACME_EMAIL:-}" ] || die "Defina ACME_EMAIL."
  [ -n "${API_TOKEN:-}" ]                || API_TOKEN="$(gen_secret)"
  [ -n "${POSTGRES_PASSWORD:-}" ]        || POSTGRES_PASSWORD="$(gen_secret)"
  [ -n "${NEXTCLOUD_ADMIN_PASSWORD:-}" ] || NEXTCLOUD_ADMIN_PASSWORD="$(gen_secret)"
  [ -n "${DRIVE_PASSWORD:-}" ]           || DRIVE_PASSWORD="$(gen_secret)"
  OLLAMA_MODEL="${OLLAMA_MODEL:-$MODEL_DEFAULT}"
  DRIVE_QUOTA="${DRIVE_QUOTA:-$QUOTA_DEFAULT}"
  ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-}"

  write_env
  set -a; source "$ENV_FILE"; set +a
  ok "Arquivo .env criado em $ENV_FILE (permissoes 600)."
}

# ------------------------------ comando hadix --------------------------------
write_hadix_command() {
  cat > "$BIN_HADIX" <<CMD
#!/usr/bin/env bash
# Hadix AI — gerenciador do backend
set -euo pipefail
BACKEND="$BACKEND_DIR"

cd "\$BACKEND"

case "\${1:-help}" in
  start)   shift 2>/dev/null || true; docker compose up -d --build ;;
  stop)    docker compose down ;;
  restart) docker compose restart ;;
  status|ps) docker compose ps ;;
  logs)    docker compose logs -f --tail=200 "\${2:-api}" ;;
  env)     cat .env ;;
  model)   docker compose exec -T ollama ollama pull "\${2:-\$MODEL_DEFAULT}" ;;
  help|*)  cat <<'EOF'
Hadix AI — gerenciador do backend
  sudo hadix start          sobe a stack
  sudo hadix stop           derruba a stack
  sudo hadix restart        reinicia os containers
  sudo hadix status         status dos containers
  sudo hadix logs [servico] logs (padrao: api)
  sudo hadix env            mostra o .env
  sudo hadix model [nome]   baixa um modelo no Ollama
  sudo hadix help           mostra esta ajuda
EOF
    ;;
esac
CMD
  chmod 755 "$BIN_HADIX"
  ok "Comando instalado: sudo $BIN_HADIX"
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
  info "Subindo a stack Hadix (compila a API e baixa as imagens — pode levar minutos)..."
  docker compose up -d --build

  info "Baixando o modelo Ollama: $OLLAMA_MODEL"
  wait_for "docker compose exec -T ollama ollama list" "o Ollama ficar saudavel" 60
  docker compose exec -T ollama ollama pull "$OLLAMA_MODEL"

  info "Configurando o usuario do drive no Nextcloud."
  wait_for "docker compose exec -T nextcloud php occ status 2>/dev/null | grep -qE 'installed: true'" \
           "o Nextcloud concluir a instalacao" 90
  docker compose exec -T -u www-data nextcloud php /opt/hadix/setup-drive.php
}

# -------------------------------- firewall ----------------------------------
maybe_firewall() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q "Status: active" && return 0
  if [ "$INTERACTIVE" -eq 1 ]; then
    if ask_yes "UFW detectado mas inativo. Abrir portas 80/443?"; then
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
  ok "Instalacao concluida!"
  echo
  echo "  API   : https://$API_DOMAIN"
  echo "  Drive : https://$DRIVE_DOMAIN"
  echo "          admin: hadix-admin / (sua NEXTCLOUD_ADMIN_PASSWORD)"
  echo "  Modelo: $OLLAMA_MODEL"
  echo
  echo "Comandos uteis:"
  echo "  sudo hadix status      # status dos containers"
  echo "  sudo hadix logs        # logs da API"
  echo "  sudo hadix start|stop  # sobe/derruba a stack"
  echo "  cd $BACKEND_DIR && docker compose ps"
  echo
  warn "Guarde o arquivo $ENV_FILE em local seguro."
}

# -------------------------------- main --------------------------------------
main() {
  install_docker
  write_backend_files
  write_hadix_command
  configure_env
  deploy
  maybe_firewall
  summary
}

main "$@"