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
UPDATE_URL_DEFAULT="https://raw.githubusercontent.com/Fast4gc/hadix-ai.site/main/install.sh"
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
      AI_DOMAIN: ${AI_DOMAIN:?Configure .env}
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./panel:/srv/panel:ro
      - ./site:/srv/site:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      edge:
        ipv4_address: 172.30.60.2
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
      TRUSTED_PROXIES: 172.30.60.2
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
      config: [{ subnet: 172.30.60.0/24 }]
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
  handle_path /painel/* {
    root * /srv/panel
    file_server
  }
  handle {
    reverse_proxy api:3000 {
      transport http {
        response_header_timeout 250s
      }
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

{$AI_DOMAIN} {
  encode zstd gzip
  header {
    Strict-Transport-Security "max-age=31536000"
    -Server
  }
  root * /srv/site
  file_server
}
CADDY

  # Dockerfile da API
  cat > "$BACKEND_DIR/api/Dockerfile" <<'DKRFILE'
FROM node:24-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev && npm cache clean --force
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
  # painel (frontend) — servido pelo caddy em https://$API_DOMAIN/painel/
  mkdir -p "$BACKEND_DIR/panel"
  cat > "$BACKEND_DIR/panel/index.html" <<'PANEL'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Hadix AI — Painel</title>
<meta name="description" content="Painel do Hadix AI: status da API, modelo e chat com o agente.">
<meta name="theme-color" content="#08090a">
<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css">
<style>
:root {
  --hadix-bg: #0b0d0f;
  --hadix-panel: #12151a;
  --hadix-panel-2: #171b21;
  --hadix-border: #262b33;
  --hadix-lime: #c9f24b;
  --hadix-lime-dim: rgba(201,242,75,.12);
  --hadix-text: #eef0ec;
  --hadix-muted: #8b939e;
  --hadix-monospace: "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
}
body {
  background: var(--hadix-bg);
  color: var(--hadix-text);
  font-family: "Inter", system-ui, -apple-system, sans-serif;
  min-height: 100vh;
}
a { color: var(--hadix-lime); }
.brand-mark {
  display: inline-grid; place-items: center;
  width: 30px; height: 30px;
  background: var(--hadix-lime); color: #0b0d0f;
  border-radius: 8px; font-weight: 700;
}
.sidebar {
  min-height: 100vh;
  background: var(--hadix-panel);
  border-right: 1px solid var(--hadix-border);
}
.sidebar .nav-link {
  color: var(--hadix-muted);
  border-radius: 10px;
  padding: .6rem .9rem;
  margin: .15rem 0;
  display: flex; align-items: center; gap: .65rem;
  transition: color .15s, background .15s;
}
.sidebar .nav-link:hover { color: var(--hadix-text); background: var(--hadix-panel-2); }
.sidebar .nav-link.active {
  color: #0b0d0f; background: var(--hadix-lime); font-weight: 600;
}
.card {
  background: var(--hadix-panel);
  border: 1px solid var(--hadix-border);
  border-radius: 14px;
}
.stat-value {
  font-family: var(--hadix-monospace);
  font-size: 1.75rem; font-weight: 500; letter-spacing: -.02em;
}
.dot {
  width: 10px; height: 10px; border-radius: 50%;
  display: inline-block; flex: 0 0 auto;
}
.dot.ok { background: var(--hadix-lime); box-shadow: 0 0 0 4px var(--hadix-lime-dim); }
.dot.warn { background: #f0b429; box-shadow: 0 0 0 4px rgba(240,180,41,.15); }
.dot.bad { background: #f2574c; box-shadow: 0 0 0 4px rgba(242,87,76,.15); }
.mono { font-family: var(--hadix-monospace); }
.code {
  background: var(--hadix-panel-2);
  border: 1px solid var(--hadix-border);
  border-radius: 8px;
  padding: .4rem .6rem;
  font-family: var(--hadix-monospace); font-size: .8rem;
  color: var(--hadix-text);
  word-break: break-all;
}
.chat-panel { display: flex; flex-direction: column; height: 520px; }
.chat-log {
  flex: 1; overflow-y: auto;
  padding: 1rem;
  display: flex; flex-direction: column; gap: .75rem;
}
.msg {
  max-width: 82%;
  padding: .7rem 1rem;
  border-radius: 14px;
  font-size: .925rem;
  line-height: 1.5;
  white-space: pre-wrap; word-break: break-word;
}
.msg.user {
  align-self: flex-end;
  background: var(--hadix-lime); color: #0b0d0f;
  border-bottom-right-radius: 4px;
}
.msg.assistant {
  align-self: flex-start;
  background: var(--hadix-panel-2);
  border: 1px solid var(--hadix-border);
  border-bottom-left-radius: 4px;
}
.msg.error { border-color: rgba(242,87,76,.5); color: #ffb4ae; }
.chat-input { border-top: 1px solid var(--hadix-border); padding: .8rem; background: var(--hadix-panel); border-radius: 0 0 14px 14px; }
.form-control, .form-select {
  background: var(--hadix-panel-2);
  border: 1px solid var(--hadix-border);
  color: var(--hadix-text);
}
.form-control:focus { background: var(--hadix-panel-2); color: var(--hadix-text); border-color: var(--hadix-lime); box-shadow: 0 0 0 .2rem var(--hadix-lime-dim); }
.btn-lime { background: var(--hadix-lime); color: #0b0d0f; font-weight: 600; border: 0; }
.btn-lime:hover { background: #d9f86b; color: #0b0d0f; }
.btn-outline-lime { color: var(--hadix-lime); border: 1px solid var(--hadix-lime); }
.btn-outline-lime:hover { background: var(--hadix-lime-dim); color: var(--hadix-lime); }
.footer-note { color: var(--hadix-muted); font-size: .8rem; }
#endpoints .card { margin-bottom: 1rem; }
.msg .loading-dots span { animation: blink 1.2s infinite; margin-right: 2px; }
.msg .loading-dots span:nth-child(2) { animation-delay: .2s; }
.msg .loading-dots span:nth-child(3) { animation-delay: .4s; }
@keyframes blink { 0%,80%,100% { opacity: .2 } 40% { opacity: 1 } }
</style>
</head>
<body>
<div class="d-flex">
  <!-- Sidebar -->
  <aside class="sidebar d-none d-md-flex flex-column p-3" style="width: 240px; position: sticky; top: 0;">
    <div class="d-flex align-items-center gap-2 mb-4 px-1">
      <span class="brand-mark">✳</span>
      <div class="lh-1">
        <div class="fw-bold">Hadix <span class="text-info">AI</span></div>
        <small class="footer-note">Painel</small>
      </div>
    </div>
    <nav class="nav flex-column">
      <a class="nav-link active" data-page="dashboard" href="#dashboard"><i class="bi bi-grid-1x2"></i> Visão geral</a>
      <a class="nav-link" data-page="chat" href="#chat"><i class="bi bi-chat-dots"></i> Chat</a>
      <a class="nav-link" data-page="endpoints" href="#endpoints"><i class="bi bi-hdd-network"></i> Endpoints</a>
    </nav>
    <div class="mt-auto pt-3 ps-1 footer-note">
      <div id="navStatus" class="d-flex align-items-center gap-2">
        <span class="dot bad" id="navDot"></span>
        <span id="navStatusText">Desconectado</span>
      </div>
    </div>
  </aside>

  <!-- Main -->
  <main class="flex-grow-1 p-3 p-lg-4" style="max-width: 1080px;">
    <!-- Topbar -->
    <div class="d-flex flex-wrap align-items-center justify-content-between gap-2 mb-4">
      <div>
        <h1 class="h4 mb-0 fw-bold" id="pageTitle">Visão geral</h1>
        <small class="footer-note" id="pageSub">Status da API Hadix em tempo real</small>
      </div>
      <div class="d-flex gap-2">
        <span class="d-md-none me-1"><span class="dot bad" id="navDotMobile"></span></span>
        <button class="btn btn-outline-lime btn-sm" data-bs-toggle="modal" data-bs-target="#configModal"><i class="bi bi-gear me-1"></i>Configuração</button>
      </div>
    </div>

    <!-- Page: dashboard -->
    <section id="page-dashboard">
      <div class="row g-3">
        <div class="col-sm-6 col-xl-3">
          <div class="card h-100 p-3">
            <div class="d-flex justify-content-between align-items-center mb-2">
              <small class="footer-note text-uppercase">API</small>
              <span class="dot warn" id="apiDot"></span>
            </div>
            <div class="stat-value" id="apiStat">—</div>
            <small class="footer-note" id="apiSub">/healthz</small>
          </div>
        </div>
        <div class="col-sm-6 col-xl-3">
          <div class="card h-100 p-3">
            <div class="d-flex justify-content-between align-items-center mb-2">
              <small class="footer-note text-uppercase">Modelo</small>
              <span class="dot warn" id="modelDot"></span>
            </div>
            <div class="stat-value" id="modelStat">—</div>
            <small class="footer-note" id="modelSub">/api/ready</small>
          </div>
        </div>
        <div class="col-sm-6 col-xl-3">
          <div class="card h-100 p-3">
            <div class="d-flex justify-content-between align-items-center mb-2">
              <small class="footer-note text-uppercase">Drive</small>
              <span class="dot warn" id="driveDot"></span>
            </div>
            <div class="stat-value" id="driveStat">—</div>
            <small class="footer-note" id="driveSub">/api/config</small>
          </div>
        </div>
        <div class="col-sm-6 col-xl-3">
          <div class="card h-100 p-3">
            <div class="d-flex justify-content-between align-items-center mb-2">
              <small class="footer-note text-uppercase">Latência</small>
              <span class="dot warn" id="latDot"></span>
            </div>
            <div class="stat-value" id="latStat">—</div>
            <small class="footer-note" id="latSub">última medição</small>
          </div>
        </div>
      </div>

      <div class="card p-3 mt-4">
        <div class="d-flex align-items-center justify-content-between mb-3">
          <h2 class="h6 mb-0">Sistema</h2>
          <button class="btn btn-sm btn-outline-lime" id="refreshBtn"><i class="bi bi-arrow-clockwise me-1"></i>Atualizar</button>
        </div>
        <div class="table-responsive">
          <table class="table table-dark align-middle mb-0" style="--bs-table-bg:transparent">
            <thead>
              <tr><th class="footer-note text-uppercase">Componente</th><th class="footer-note text-uppercase">Endereço</th><th class="footer-note text-uppercase">Status</th></tr>
            </thead>
            <tbody>
              <tr><td>API</td><td class="mono" id="apiUrlCell">—</td><td id="apiStateCell">—</td></tr>
              <tr><td>Modelo</td><td class="mono" id="modelCell">—</td><td id="modelStateCell">—</td></tr>
              <tr><td>Drive</td><td class="mono" id="driveCell">—</td><td id="driveStateCell">—</td></tr>
            </tbody>
          </table>
        </div>
      </div>
    </section>

    <!-- Page: chat -->
    <section id="page-chat" class="d-none">
      <div class="card">
        <div class="card-body chat-panel p-0">
          <div class="chat-log" id="chatLog" aria-live="polite">
            <div class="msg assistant">Olá. Sou o agente do Hadix AI rodando no modelo <b id="chatModelLabel">—</b>. Como posso ajudar?</div>
          </div>
          <div class="chat-input d-flex gap-2">
            <input class="form-control" id="chatText" type="text" autocomplete="off" placeholder="Escreva sua mensagem…">
            <button class="btn btn-lime" id="chatSend"><i class="bi bi-send-fill"></i></button>
          </div>
        </div>
      </div>
    </section>

    <!-- Page: endpoints -->
    <section id="page-endpoints" class="d-none">
      <div class="card p-3 mb-3">
        <h2 class="h6 mb-3">Rotas da API</h2>
        <p class="footer-note mb-0">Todas as rotas <code class="code">/api/*</code> exigem o header <code class="code">Authorization: Bearer &lt;token&gt;</code>. A rota <code class="code">/healthz</code> é pública.</p>
      </div>
      <div id="endpoints">
        <div class="card p-3"><div class="d-flex align-items-center gap-2"><span class="badge bg-secondary mono">GET</span><span class="code">/healthz</span><span class="dot ok"></span></div><small class="footer-note">Público — status do serviço.</small></div>
        <div class="card p-3"><div class="d-flex align-items-center gap-2"><span class="badge bg-secondary mono">GET</span><span class="code">/api/config</span></div><small class="footer-note">Token — modelo, URL do drive e paralelismo máximo.</small></div>
        <div class="card p-3"><div class="d-flex align-items-center gap-2"><span class="badge bg-secondary mono">GET</span><span class="code">/api/ready</span></div><small class="footer-note">Token — se o modelo está carregado (200) ou ausente (503).</small></div>
        <div class="card p-3"><div class="d-flex align-items-center gap-2"><span class="badge bg-info mono">POST</span><span class="code">/api/chat</span></div><small class="footer-note">Token — corpo: <code class="code">{"messages":[{"role":"user","content":"…"}]}</code>. Rate limit: 12/min.</small></div>
      </div>
    </section>
  </main>
</div>

<!-- Config modal -->
<div class="modal fade" id="configModal" tabindex="-1" aria-hidden="true">
  <div class="modal-dialog modal-dialog-centered">
    <div class="modal-content" style="background: var(--hadix-panel); border: 1px solid var(--hadix-border); color: var(--hadix-text);">
      <div class="modal-header border-secondary-subtle">
        <h5 class="modal-title">Configuração</h5>
        <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal" aria-label="Fechar"></button>
      </div>
      <div class="modal-body">
        <div class="mb-3">
          <label for="cfgApi" class="form-label footer-note">Endereço da API</label>
          <input id="cfgApi" class="form-control mono" placeholder="https://api.hadix.site">
          <div class="form-text footer-note">Usado para /healthz, /api/config, /api/ready e /api/chat.</div>
        </div>
        <div class="mb-3">
          <label for="cfgToken" class="form-label footer-note">Token de acesso (API_TOKEN)</label>
          <input id="cfgToken" class="form-control mono" type="password" placeholder="Bearer token">
        </div>
        <div class="form-check mb-2">
          <input class="form-check-input" type="checkbox" id="cfgSave">
          <label class="form-check-label footer-note" for="cfgSave">Salvar localmente</label>
        </div>
      </div>
      <div class="modal-footer border-secondary-subtle">
        <button class="btn btn-lime" data-bs-dismiss="modal" id="cfgSaveBtn">Salvar</button>
      </div>
    </div>
  </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
<script>
(() => {
  'use strict';
  const STORE_KEY = 'hadix.panel.v1';
  const $ = id => document.getElementById(id);

  const cfg = { apiBase: '', token: '', save: false };
  const loadCfg = () => {
    const saved = localStorage.getItem(STORE_KEY);
    if (saved) {
      const p = JSON.parse(saved);
      Object.assign(cfg, p);
    }
    cfg.apiBase = cfg.apiBase || location.origin.replace(/^https?:\/\/([^.]+\.)?/, 'https://api.');
    $('cfgApi').value = cfg.apiBase;
    $('cfgToken').value = cfg.token;
    $('cfgSave').checked = cfg.save;
  };
  const storeCfg = () => {
    if (cfg.save) localStorage.setItem(STORE_KEY, JSON.stringify(cfg));
    else localStorage.removeItem(STORE_KEY);
  };

  const setDot = (el, st) => {
    el.classList.remove('ok', 'warn', 'bad');
    if (st === 'ok') el.classList.add('ok');
    else if (st === 'bad') el.classList.add('bad');
    else el.classList.add('warn');
  };

  const api = async (path, { method = 'GET', body, timeoutMs = 6000 } = {}) => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetch(cfg.apiBase.replace(/\/$/, '') + path, {
        method, signal: controller.signal,
        headers: {
          'Content-Type': 'application/json',
          ...(cfg.token ? { Authorization: `Bearer ${cfg.token}` } : {}),
        },
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
      const data = await res.json().catch(() => ({}));
      return { ok: res.ok, status: res.status, data };
    } finally { clearTimeout(timer); }
  };

  const fmt = ms => ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`;

  async function refresh() {
    setDot($('navDot'), 'warn'); setDot($('navDotMobile'), 'warn');
    $('navStatusText').textContent = cfg.apiBase ? 'Verificando…' : 'Sem configuração';

    const t0 = performance.now();
    const health = await api('/healthz');
    const latency = performance.now() - t0;

    // API
    $('apiStat').textContent = health.ok ? 'online' : (health.status ? `HTTP ${health.status}` : 'offline');
    setDot($('apiDot'), health.ok ? 'ok' : 'bad');
    $('apiSub').textContent = health.ok ? 'respondendo' : 'sem resposta';
    $('apiUrlCell').textContent = cfg.apiBase || '—';
    $('apiStateCell').innerHTML = `<span class="dot ${health.ok ? 'ok' : 'bad'} me-1"></span>${health.ok ? 'online' : 'offline'}`;

    // Latência
    $('latStat').textContent = cfg.apiBase ? fmt(latency) : '—';
    setDot($('latDot'), latency < 2000 ? 'ok' : (health.ok ? 'warn' : 'bad'));
    $('latSub').textContent = health.ok ? `carregou em ${fmt(latency)}` : 'falhou';

    if (!cfg.apiBase) {
      setDot($('navDot'), 'bad'); setDot($('navDotMobile'), 'bad');
      $('navStatusText').textContent = 'Configure a API';
      return;
    }
    if (!cfg.token) {
      setDot($('navDot'), 'bad'); setDot($('navDotMobile'), 'bad');
      $('navStatusText').textContent = 'Token ausente';
    }

    // Config + Ready (exigem token)
    const [conf, ready] = await Promise.all([
      api('/api/config').catch(() => ({ ok: false, status: 0, data: {} })),
      api('/api/ready', { timeoutMs: 8000 }).catch(() => ({ ok: false, status: 0, data: {} })),
    ]);

    const modelName = conf.data.model || '—';
    $('modelCell').textContent = modelName;
    $('chatModelLabel').textContent = modelName;

    if (ready.ok && ready.data.status === 'ready') {
      $('modelStat').textContent = 'pronto';
      setDot($('modelDot'), 'ok');
      $('modelSub').textContent = modelName;
    } else if (conf.ok) {
      $('modelStat').textContent = 'baixando';
      setDot($('modelDot'), 'warn');
      $('modelSub').textContent = modelName;
    } else {
      $('modelStat').textContent = 'indisponível';
      setDot($('modelDot'), 'bad');
      $('modelSub').textContent = conf.status ? `HTTP ${conf.status}` : 'sem resposta';
    }
    $('modelStateCell').innerHTML =
      `<span class="dot ${ready.ok ? 'ok' : 'bad'} me-1"></span>${ready.ok ? 'pronto' : 'indisponível'}`;

    const driveUrl = conf.data.driveUrl || '—';
    $('driveStat').textContent = conf.data.driveUrl ? 'ativo' : '—';
    setDot($('driveDot'), conf.data.driveUrl ? 'ok' : 'warn');
    $('driveSub').textContent = conf.data.driveUrl ? 'link no config' : 'não definido';
    $('driveCell').textContent = driveUrl;
    $('driveStateCell').innerHTML = `<span class="dot ${conf.data.driveUrl ? 'ok' : 'warn'} me-1"></span>${conf.data.driveUrl ? 'ativo' : 'não definido'}`;

    setDot($('navDot'), health.ok && ready.ok ? 'ok' : (health.ok ? 'warn' : 'bad'));
    setDot($('navDotMobile'), health.ok && ready.ok ? 'ok' : (health.ok ? 'warn' : 'bad'));
    $('navStatusText').textContent = health.ok ? (ready.ok ? 'Conectado' : `Modelo não pronto`) : 'API offline';
  }

  // Navegação
  const titles = {
    dashboard: ['Visão geral', 'Status da API Hadix em tempo real'],
    chat: ['Chat', 'Converse com o agente Hadix'],
    endpoints: ['Endpoints', 'Referência das rotas da API'],
  };
  document.querySelectorAll('.sidebar .nav-link').forEach(link => {
    link.addEventListener('click', () => {
      document.querySelectorAll('.sidebar .nav-link').forEach(l => l.classList.remove('active'));
      link.classList.add('active');
      document.querySelectorAll('section[id^="page-"]').forEach(s => s.classList.add('d-none'));
      $('page-' + link.dataset.page).classList.remove('d-none');
      $('pageTitle').textContent = titles[link.dataset.page][0];
      $('pageSub').textContent = titles[link.dataset.page][1];
    });
  });

  // Chat
  let busy = false;
  const appendMsg = (role, html) => {
    const d = document.createElement('div');
    d.className = 'msg ' + role;
    d.innerHTML = html;
    $('chatLog').appendChild(d);
    $('chatLog').scrollTop = $('chatLog').scrollHeight;
    return d;
  };

  async function sendChat() {
    const text = $('chatText').value.trim();
    if (!text || busy) return;
    if (!cfg.apiBase || !cfg.token) {
      appendMsg('error', 'Configure o endereço da API e o token no ícone de engrenagem.');
      return;
    }
    appendMsg('user', text.replace(/[<>&]/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c])));
    $('chatText').value = '';
    const pending = appendMsg('assistant', '<div class="loading-dots"><span>●</span><span>●</span><span>●</span></div>');
    busy = true;
    const res = await api('/api/chat', { method: 'POST', body: { messages: [{ role: 'user', content: text }] }, timeoutMs: 250000 });
    busy = false;
    const content = res.data.message?.content || res.data.error || (res.ok ? 'Resposta vazia.' : `Erro ${res.status || ''}`);
    pending.innerHTML = content.replace(/[<>&]/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c])).replace(/\n/g, '<br>');
    if (!res.ok) pending.classList.add('error');
    $('chatLog').scrollTop = $('chatLog').scrollHeight;
  }

  $('chatSend').addEventListener('click', sendChat);
  $('chatText').addEventListener('keydown', e => { if (e.key === 'Enter') sendChat(); });

  // Config save
  $('cfgSaveBtn').addEventListener('click', () => {
    cfg.apiBase = $('cfgApi').value.trim().replace(/\/+$/, '');
    cfg.token = $('cfgToken').value.trim();
    cfg.save = $('cfgSave').checked;
    storeCfg();
    refresh();
  });

  $('refreshBtn').addEventListener('click', refresh);

  loadCfg();
  refresh();
})();
</script>
</body>
</html>
PANEL
  chmod 644 "$BACKEND_DIR/panel/index.html"

  # site (landing + chat) — servido pela caddy em https://$AI_DOMAIN/
  mkdir -p "$BACKEND_DIR/site/assets/js"
  cat > "$BACKEND_DIR/site/assets/js/adaptive-space.js" <<'HX_JS_ADAPTIVE'
// A single low-poly wire surface morphs with the four product scenes.
window.createAdaptiveSpace = function () {
  const backdrop=document.querySelector('.spatial-backdrop');
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const {THREE:T,gsap}=window;
  let renderer;
  const canvas=document.createElement('canvas');canvas.className='adaptive-canvas';canvas.setAttribute('aria-hidden','true');
  try { if(!T)return null;renderer=new T.WebGLRenderer({canvas,alpha:true,antialias:true,powerPreference:'low-power'}); } catch { return null; }
  backdrop.append(canvas);renderer.setPixelRatio(Math.min(devicePixelRatio,1.4));
  const scene=new T.Scene(),camera=new T.PerspectiveCamera(40,1,.1,40);camera.position.z=7;
  const columns=48,rows=24,count=(columns+1)*(rows+1),targets=[];
  for(let shape=0;shape<4;shape++){
    const data=new Float32Array(count*3);
    for(let j=0;j<=rows;j++)for(let i=0;i<=columns;i++){
      const u=i/columns*Math.PI*2,v=j/rows*Math.PI*2,k=(j*(columns+1)+i)*3;
      let x,y,z;
      if(shape===0){const lat=j/rows*Math.PI;x=Math.cos(u)*Math.sin(lat)*1.8;y=Math.cos(lat)*1.8;z=Math.sin(u)*Math.sin(lat)*1.8;}
      if(shape===1){const radius=1.25+.22*Math.cos(v*4);x=Math.sign(Math.cos(u))*Math.pow(Math.abs(Math.cos(u)),.45)*radius;y=(j/rows-.5)*3.3;z=Math.sign(Math.sin(u))*Math.pow(Math.abs(Math.sin(u)),.45)*radius;}
      if(shape===2){const along=(i/columns-.5)*5.5;x=along;y=Math.sin(i/columns*Math.PI*2)*.7+Math.cos(v)*.44;z=Math.cos(i/columns*Math.PI*2)*.6+Math.sin(v)*.44;}
      if(shape===3){const r=1.45+.5*Math.cos(v);x=r*Math.cos(u);y=r*Math.sin(u);z=.5*Math.sin(v)+.3*Math.sin(u*4);}
      data.set([x,y,z],k);
    }targets.push(data);
  }
  const geometry=new T.BufferGeometry();geometry.setAttribute('position',new T.BufferAttribute(targets[0].slice(),3));
  const indices=[];
  for(let j=0;j<=rows;j++)for(let i=0;i<=columns;i++){const k=j*(columns+1)+i;if(i<columns)indices.push(k,k+1);if(j<rows)indices.push(k,k+columns+1);}
  geometry.setIndex(indices);
  const material=new T.LineBasicMaterial({color:0xa8cf95,transparent:true,opacity:.12,depthWrite:false});
  const mesh=new T.LineSegments(geometry,material);mesh.frustumCulled=false;scene.add(mesh);
  const state={mix:1,rx:0,ry:0,turn:0},pointer={x:0,y:0};let current=0,from=targets[0],to=targets[0],frame=0,last=0,lost=false;
  function draw(){if(lost)return;const positions=geometry.attributes.position.array;for(let i=0;i<positions.length;i++)positions[i]=from[i]+(to[i]-from[i])*state.mix;geometry.attributes.position.needsUpdate=true;mesh.rotation.set(state.rx+pointer.y,state.ry+pointer.x+state.turn,.12);renderer.render(scene,camera);}
  function tick(now){frame=0;if(document.hidden||lost)return;const delta=Math.min((now-last)/1000||0,.04);last=now;state.turn+=delta*.025;draw();if(!reduced.matches)frame=requestAnimationFrame(tick);}
  function resume(){cancelAnimationFrame(frame);frame=0;if(!document.hidden&&!lost){draw();last=performance.now();if(!reduced.matches)frame=requestAnimationFrame(tick);}}
  function resize(){renderer.setSize(innerWidth,innerHeight,false);camera.aspect=innerWidth/innerHeight;camera.updateProjectionMatrix();const mobile=innerWidth<=800;mesh.position.set(mobile?0:1.8,mobile?-.4:.2,-1);mesh.scale.setScalar(mobile?.9:1.15);draw();}
  function setScene(index,instant=false){
    current=index;backdrop.dataset.scene=['hero','platform','pipeline','agents'][index];
    from=geometry.attributes.position.array.slice();to=targets[index];gsap.killTweensOf(state);state.mix=0;
    const duration=instant||reduced.matches?0:1.5;
    gsap.to(state,{mix:1,rx:[.1,.3,.25,.35][index],ry:[0,.55,-.15,.35][index],duration,ease:'power2.inOut',onUpdate:draw});
    gsap.to(material,{opacity:[.035,.12,.2,.16][index],duration,ease:'sine.inOut',overwrite:true,onUpdate:draw});
    gsap.to(backdrop,{'--grid-tilt':[61,48,66,55][index]+'deg','--grid-shift':[0,28,-20,14][index]+'px',duration,ease:'power2.inOut'});
  }
  const xTo=gsap.quickTo(pointer,'x',{duration:1.2,ease:'power2.out',onUpdate:draw});
  const yTo=gsap.quickTo(pointer,'y',{duration:1.2,ease:'power2.out',onUpdate:draw});
  addEventListener('pointermove',e=>{if(reduced.matches||e.pointerType!=='mouse'||document.hidden)return;xTo((e.clientX/innerWidth-.5)*.16);yTo((e.clientY/innerHeight-.5)*.1);},{passive:true});
  document.addEventListener('visibilitychange',resume);
  reduced.addEventListener('change',()=>{gsap.killTweensOf(pointer);pointer.x=pointer.y=0;setScene(current,true);resume();});
  canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();lost=true;cancelAnimationFrame(frame);canvas.hidden=true;});
  addEventListener('resize',resize);resize();resume();
  return {setScene};
};

HX_JS_ADAPTIVE

  mkdir -p "$BACKEND_DIR/site/assets/js"
  cat > "$BACKEND_DIR/site/assets/js/main.js" <<'HX_JS_MAIN'
// Navigation remains usable if GSAP is unavailable (normal document fallback).
const toggle = document.getElementById('menuToggle');
const mobileNav = document.getElementById('mobileNav');
function setMenu(open, focus = false) {
  toggle.setAttribute('aria-expanded', String(open));
  toggle.setAttribute('aria-label', open ? 'Fechar menu' : 'Abrir menu');
  mobileNav.hidden = !open;
  if (focus) toggle.focus();
}
toggle.addEventListener('click', () => setMenu(mobileNav.hidden));
mobileNav.addEventListener('click', e => { if (e.target.closest('a')) setMenu(false); });
document.addEventListener('keydown', e => { if(e.key === 'Escape') setMenu(false, true); });
document.addEventListener('click', e => { if(!mobileNav.contains(e.target) && !toggle.contains(e.target)) setMenu(false); });
matchMedia('(min-width:801px)').addEventListener('change', e => { if(e.matches) setMenu(false); });

if (window.gsap) initializeScenes();
function initializeScenes() {
  const {gsap} = window;
  const ids = ['hero','platform','pipeline','agents'];
  const names = ['Início','Plataforma','Pipeline','Agentes'];
  const panels = ids.map(id => document.getElementById(id));
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const cta = document.getElementById('cta');
  panels[3].append(cta);
  const controls = document.createElement('nav');
  controls.className = 'scene-controls';
  controls.setAttribute('aria-label','Navegar entre telas');
  controls.innerHTML = '<span class="scene-current" aria-live="polite"></span><span>/ 04</span><span class="scene-hint">ROLE PARA EXPLORAR</span><button type="button" aria-label="Tela anterior">↑</button><button type="button" aria-label="Próxima tela">↓</button>';
  document.body.append(controls);
  const [previous,next] = controls.querySelectorAll('button');
  const orbit = document.createElement('div');
  orbit.className = 'scene-orbit';orbit.setAttribute('aria-hidden','true');
  document.getElementById('main').prepend(orbit);
  panels.forEach(panel => {panel.classList.add('scene');panel.tabIndex = -1;});
  document.body.classList.add('scene-mode');
  let current = Math.max(0, ids.indexOf(location.hash.slice(1) === 'cta' ? 'agents' : location.hash.slice(1)));
  let busy = false, cooldown = 0, wheelTotal = 0, wheelTime = 0, transition;
  const assembly = createAssembly(gsap);
  const adaptiveSpace = window.createAdaptiveSpace?.();
  const planet = window.createPortalPlanet?.();
  const ambient = gsap.to('.globe-art',{rotation:5,duration:12,ease:'sine.inOut',repeat:-1,yoyo:true,paused:true});
  function update() {
    controls.querySelector('.scene-current').textContent = `0${current+1} / ${names[current]}`;
    previous.disabled = current === 0; next.disabled = current === 3;
    document.querySelectorAll('.section-index a,.nav a').forEach(link => {
      const active = link.hash === '#' + ids[current];link.classList.toggle('active',active);
      if(active)link.setAttribute('aria-current','page');else link.removeAttribute('aria-current');
    });
    document.getElementById('scrollBar').style.transform = `scaleX(${(current+1)/4})`;
    if(current === 0 && !reduced.matches && !document.hidden)ambient.resume();else ambient.pause();
  }
  function enter(index) {
    if(index === 1) { if(reduced.matches)assembly.progress(1).pause();else assembly.restart(); }
    else assembly.pause();
    if(planet){planet.state.progress=0;planet.canvas.style.opacity='1';planet.setEnabled(index===0);planet.resize();}
  }
  function navigate(index, {historyMode='push',focus=false,target=null}={}) {
    index = Math.max(0,Math.min(3,index));
    if(busy) return;
    if(index === current) {if(target)target.scrollIntoView({block:'start',behavior:reduced.matches?'instant':'smooth'});return;}
    const origin = current;
    const outgoing = panels[current], incoming = panels[index], direction = index > current ? 1 : -1;
    busy = true; current = index; wheelTotal=0;
    setMenu(false);
    outgoing.inert = true;outgoing.setAttribute('aria-hidden','true');
    incoming.inert = false;incoming.removeAttribute('aria-hidden');incoming.scrollTop=0;
    if(historyMode==='push') history.pushState(null,'','#'+ids[index]);
    update();
    adaptiveSpace?.setScene(index);
    assembly.pause();
    if(index===1)assembly.progress(reduced.matches?1:0).pause();
    const duration = reduced.matches ? 0 : .85;
    const children = incoming.querySelectorAll('.hero-copy, .globe-stage, .section-heading, .architecture, .pipeline-grid, .agent-grid');
    transition = gsap.timeline({onComplete:()=>{
      gsap.set(outgoing,{autoAlpha:0,y:0,scale:1});
      gsap.set(incoming,{clearProps:'transform'});
      gsap.set(children,{clearProps:'transform,opacity,visibility'});
      gsap.set(outgoing.querySelectorAll('.hero-copy,.hero-bottom,.scene-label,.globe-tag'),{clearProps:'transform,opacity,visibility'});
      busy=false;cooldown=performance.now()+250;enter(index);
      if(focus || outgoing.contains(document.activeElement))incoming.focus({preventScroll:true});
      if(target)target.scrollIntoView({block:'start',behavior:'instant'});
    }});
    if(planet?.ready && !reduced.matches && ((origin===0 && index===1)||(origin===1 && index===0))){
      const forward=index===1;
      planet.state.progress=forward?0:1;planet.setEnabled(true);planet.resize();
      gsap.set(planet.canvas,{opacity:forward?1:0});
      gsap.set(incoming,{autoAlpha:0,y:0,scale:forward?.92:1});
      transition.to(outgoing.querySelectorAll('.hero-copy,.hero-bottom,.scene-label,.globe-tag'),{autoAlpha:0,y:-18,duration:.4,ease:'power2.in'},0)
        .to(planet.state,{progress:forward?1:0,duration:1.65,ease:'power3.inOut',onUpdate:planet.draw},0)
        .to(outgoing,{autoAlpha:0,duration:.6,ease:'power2.inOut'},forward?.65:0)
        .to(planet.canvas,{opacity:forward?0:1,duration:forward?.55:.5,ease:'sine.inOut'},forward?1.1:.15)
        .to(incoming,{autoAlpha:1,scale:1,duration:.8,ease:'power3.out'},forward?.95:.8)
        .to(orbit,{x:forward?-180:0,scale:forward?.8:1,rotation:forward?65:0,duration:1.65,ease:'power2.inOut'},0);
      return;
    }
    if(planet){planet.state.progress=0;planet.setEnabled(index===0);}
    transition.to(outgoing,{autoAlpha:0,y:-direction*60,scale:.96,duration:duration*.65,ease:'power2.in'},0)
      .fromTo(incoming,{autoAlpha:0,y:direction*70,scale:1.035},{autoAlpha:1,y:0,scale:1,duration,ease:'power3.out'},duration*.2)
      .fromTo(children,{y:direction*24},{y:0,duration:duration*.7,stagger:reduced.matches?0:.06,ease:'power2.out'},duration*.3)
      .to(orbit,{x:[0,-180,80,-70][index],rotation:index*65,scale:[1,.8,1.25,.95][index],duration,ease:'power2.inOut'},0);
  }
  panels.forEach((panel,i)=>{gsap.set(panel,{autoAlpha:i===current?1:0});panel.inert=i!==current;if(i!==current)panel.setAttribute('aria-hidden','true');});
  update();enter(current);adaptiveSpace?.setScene(current,true);
  if(location.hash==='#cta')requestAnimationFrame(()=>cta.scrollIntoView());
  previous.addEventListener('click',()=>navigate(current-1,{focus:true}));
  next.addEventListener('click',()=>navigate(current+1,{focus:true}));
  document.addEventListener('click',e=>{
    const link=e.target.closest('a[href^="#"]');if(!link)return;
    const id=link.hash.slice(1),index=ids.indexOf(id==='cta'?'agents':id==='main'?'hero':id);
    if(index<0)return;e.preventDefault();navigate(index,{focus:true,target:id==='cta'?cta:null});
  });
  function restoreHash(){
    if(transition && busy)transition.progress(1);
    const id=location.hash.slice(1);navigate(Math.max(0,ids.indexOf(id==='cta'?'agents':id)),{historyMode:'none',target:id==='cta'?cta:null});
  }
  addEventListener('popstate',restoreHash);addEventListener('hashchange',restoreHash);
  function boundary(direction){const panel=panels[current];return direction>0 ? panel.scrollTop+panel.clientHeight>=panel.scrollHeight-3 : panel.scrollTop<=2;}
  document.getElementById('main').addEventListener('wheel',e=>{
    if(e.ctrlKey || Math.abs(e.deltaX)>Math.abs(e.deltaY) || !mobileNav.hidden)return;
    const direction=Math.sign(e.deltaY);if(!direction)return;
    if(busy || performance.now()<cooldown){e.preventDefault();return;}
    if(!boundary(direction)){wheelTotal=0;return;}
    e.preventDefault();const now=performance.now();
    if(now-wheelTime>180 || Math.sign(wheelTotal)!==direction)wheelTotal=0;
    wheelTime=now;wheelTotal+=e.deltaY*(e.deltaMode===1?16:e.deltaMode===2?innerHeight:1);
    if(Math.abs(wheelTotal)>45){navigate(current+direction);wheelTotal=0;}
  },{passive:false});
  document.addEventListener('keydown',e=>{
    if(e.target.closest('input,textarea,select,button') || e.target.isContentEditable || !mobileNav.hidden)return;
    const direction=['ArrowDown','PageDown',' '].includes(e.key)?1:['ArrowUp','PageUp'].includes(e.key)?-1:0;
    if(direction && boundary(direction)){e.preventDefault();navigate(current+direction,{focus:true});}
    if(e.key==='Home'){e.preventDefault();navigate(0,{focus:true});}
    if(e.key==='End'){e.preventDefault();navigate(3,{focus:true});}
  });
  let touch=null;
  const main=document.getElementById('main');
  main.addEventListener('touchstart',e=>{if(e.touches.length===1)touch={x:e.touches[0].clientX,y:e.touches[0].clientY,top:boundary(-1),bottom:boundary(1)};else touch=null;},{passive:true});
  main.addEventListener('touchend',e=>{
    if(!touch || busy || performance.now()<cooldown)return;
    const dy=touch.y-e.changedTouches[0].clientY,dx=touch.x-e.changedTouches[0].clientX;
    if(Math.abs(dy)>65 && Math.abs(dy)>Math.abs(dx) && (dy>0?touch.bottom:touch.top))navigate(current+Math.sign(dy));touch=null;
  },{passive:true});
  main.addEventListener('touchcancel',()=>touch=null,{passive:true});
  reduced.addEventListener('change',()=>{if(busy)transition.progress(1);if(reduced.matches)assembly.progress(1).pause();update();});
  document.addEventListener('visibilitychange',()=>{update();if(document.hidden)assembly.pause();else if(current===1 && !reduced.matches)assembly.resume();});
}
function createAssembly(gsap) {
  const modules=[...document.querySelectorAll('.assembly-module')];
  const cards=['perception','memory','reasoning','action'].map(name=>document.querySelector('.layer-'+name));
  const labels=['Percebendo sinais','Conectando contexto','Construindo raciocínio','Preparando a ação'];
  const status=document.getElementById('assemblyStatus'), percent=document.getElementById('assemblyPercent');
  const paths=modules.map(m=>[...m.querySelectorAll(':scope > g > path')].slice(0,3));
  const connectors=document.querySelector('.assembly-links path'),length=connectors.getTotalLength();
  const timeline=gsap.timeline({paused:true,onUpdate(){const p=this.progress(),step=Math.min(3,Math.floor(p*4));percent.textContent=Math.round(p*100)+'%';status.textContent=p>.99?'04 / Sistema conectado':`0${step+1} / ${labels[step]}`;cards.forEach((card,i)=>{card.classList.toggle('active',i===step);card.classList.toggle('is-built',i<step);});}});
  modules.forEach((module,i)=>{
    // Draw the silhouette before the material arrives. Every layer has its own beat.
    timeline.fromTo(module,{autoAlpha:.08,y:32},{autoAlpha:1,y:0,duration:.65,ease:'power3.out'},i*.8)
      .fromTo(paths[i],{fillOpacity:0,strokeDasharray:(_,p)=>p.getTotalLength(),strokeDashoffset:(_,p)=>p.getTotalLength()},{strokeDashoffset:0,duration:.55,ease:'power2.inOut'},i*.8)
      .to(paths[i],{fillOpacity:1,duration:.32,ease:'sine.out'},i*.8+.38);
  });
  timeline.fromTo(connectors,{strokeDasharray:length,strokeDashoffset:length},{strokeDashoffset:0,duration:3.2,ease:'none'},0)
    .fromTo('.assembly-progress span',{scaleX:0},{scaleX:1,duration:3.2,ease:'none'},0);
  return timeline;
}
HX_JS_MAIN

  mkdir -p "$BACKEND_DIR/site"
  cat > "$BACKEND_DIR/site/index.html" <<'HX_INDEX'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><meta name="theme-color" content="#080909">
<title>Hadix AI — Sinal vira decisão</title><meta name="description" content="Conecte dados, dê contexto aos seus agentes e transforme sinais em decisões com Hadix AI.">
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
<link rel="stylesheet" href="assets/css/style.css"><script src="https://cdn.jsdelivr.net/npm/gsap@3.12.5/dist/gsap.min.js" defer></script><script src="https://cdn.jsdelivr.net/npm/gsap@3.12.5/dist/ScrollTrigger.min.js" defer></script><script src="https://cdn.jsdelivr.net/npm/three@0.147.0/build/three.min.js" defer></script><script src="assets/js/planet3d.js" defer></script><script src="assets/js/adaptive-space.js" defer></script><script src="assets/js/main.js" defer></script>
<noscript><style>.menu-toggle{display:none!important}@media(max-width:800px){.mobile-nav[hidden]{display:block!important;position:static;margin:0 20px}.mobile-nav a{padding:12px}}</style></noscript></head><body>
<a class="skip-link" href="#main">Pular para o conteúdo</a><div class="spatial-backdrop" aria-hidden="true"><div class="grid-wall"></div><div class="grid-floor"></div></div><div class="grain" aria-hidden="true"></div><div class="scroll-progress" aria-hidden="true"><span id="scrollBar"></span></div>
<header class="topbar"><a class="brand" href="#hero" aria-label="Hadix AI, início"><span class="brand-mark" aria-hidden="true">✳</span>hadix<span class="brand-ai">.ai</span></a><nav class="nav" aria-label="Principal"><a href="#platform">Plataforma</a><a href="#pipeline">Pipeline</a><a href="#agents">Agentes</a></nav><a class="btn header-cta" href="login/">Entrar na IA <span aria-hidden="true">↗</span></a><button class="menu-toggle" id="menuToggle" aria-expanded="false" aria-controls="mobileNav" aria-label="Abrir menu"><span></span><span></span></button></header>
<nav class="mobile-nav" id="mobileNav" aria-label="Navegação mobile" hidden><a href="#platform">Plataforma</a><a href="#pipeline">Pipeline</a><a href="#agents">Agentes</a><a href="login/">Entrar na IA ↗</a></nav>
<aside class="section-index" aria-label="Seções"><a class="active" href="#hero" aria-label="01 Início">01</a><a href="#platform" aria-label="02 Plataforma">02</a><a href="#pipeline" aria-label="03 Pipeline">03</a><a href="#agents" aria-label="04 Agentes">04</a></aside>
<main id="main">
<section class="hero wrap" id="hero"><div class="hero-copy"><p class="eyebrow"><span class="status-dot"></span> Inteligência conectada. Ação autônoma.</p><h1>Sinal vira<br><span class="accent">decisão.</span></h1><p class="hero-sub">Seus dados já têm as respostas.<br>Conecte-os a agentes que percebem, raciocinam e agem. Do primeiro sinal ao próximo passo.</p><div class="hero-actions"><a href="login/" class="btn btn-lime">Começar a conversar <span aria-hidden="true">↗</span></a><a href="#pipeline" class="btn">Explore o pipeline <span aria-hidden="true">↓</span></a></div><div class="hero-note"><span class="tiny-cross">+</span> Menos operação manual. Mais possibilidades.</div></div>
<figure class="globe-stage"><a class="planet-entry" href="#platform" aria-label="Entrar no planeta e explorar a plataforma"><span>ENTRAR NA PLATAFORMA ↗</span></a><span class="scene-label scene-label-top">HADIX NETWORK <span>/ 001</span></span><img class="globe-art" src="assets/img/network.svg" alt="Globo em linhas finas com pontos de conexão em verde lima" width="640" height="640"><span class="globe-tag"><span class="status-dot"></span> Sinais conectados</span><figcaption class="scene-label scene-label-bottom"><span>PERCEBER → RACIOCINAR → AGIR</span><span>⌁</span></figcaption></figure>
<div class="hero-bottom"><span>INTELIGÊNCIA QUE MOVE O SEU NEGÓCIO</span><a href="#platform">ROLE PARA EXPLORAR <span>↓</span></a></div></section>
<div class="signal-strip" aria-label="Capacidades da plataforma"><div><span>DADOS EM MOVIMENTO</span><b>✳</b><span>CONTEXTO PERSISTENTE</span><b>✳</b><span>AGENTES CONECTADOS</span><b>✳</b><span>DECISÕES COM INTELIGÊNCIA</span><b>✳</b><span>AÇÕES ORQUESTRADAS</span></div></div>
<section class="platform wrap section" id="platform"><div class="section-heading"><p class="eyebrow">01 / A PLATAFORMA</p><div><h2>Uma inteligência.<br><span class="muted">Todas as camadas.</span></h2><p>Da percepção à ação, uma arquitetura que conecta o que o seu negócio sabe ao que ele pode fazer.</p></div></div>
<div class="architecture"><article class="layer layer-perception"><span class="layer-icon">⌘</span><p class="micro">01 / INPUT</p><h3>Perceba cada sinal.</h3><p>Eventos, imagens, sensores e texto. Transforme fontes dispersas em informação útil.</p></article><article class="layer layer-memory"><span class="layer-icon">⌁</span><p class="micro">02 / CONTEXT</p><h3>Contexto que permanece.</h3><p>Conecte documentos e histórico para dar aos agentes a memória do seu negócio.</p></article><figure class="stack-stage"><div class="assembly-status" aria-hidden="true"><span class="status-dot"></span><span id="assemblyStatus">04 / Sistema conectado</span><span id="assemblyPercent">100%</span></div><svg class="assembly-svg" role="img" aria-labelledby="assemblyTitle" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 540 700"><title id="assemblyTitle">Construção progressiva das quatro camadas do Hadix</title><defs><linearGradient id="holo"><stop stop-color="#85ddf4"/><stop offset=".27" stop-color="#b1eaf8"/><stop offset=".48" stop-color="#d6b8e8"/><stop offset=".7" stop-color="#f5d9b8"/><stop offset="1" stop-color="#d6ecc1"/></linearGradient><linearGradient id="top" x2="0" y2="1"><stop stop-color="#252921"/><stop offset="1" stop-color="#10130e"/></linearGradient></defs><g class="assembly-links" stroke="#89907e" stroke-width=".7" stroke-dasharray="4 6" opacity=".5"><path d="M104 153V540M270 63V452M436 153V540M270 235V622"/></g><g class="assembly-module" data-module="0"><g transform="translate(0 35) scale(1 .7)"><path d="M104 105V128Q104 139 119 147L247 214Q270 227 293 214L422 147Q436 140 436 128V105" fill="#11140f" stroke="#69705f" stroke-width="1"/><path d="M116 84L247 15Q270 3 293 15L424 84Q448 97 424 111L293 181Q270 193 247 181L116 111Q92 98 116 84Z" fill="url(#top)" stroke="#69705f" stroke-width="1.2"/><path d="M128 87L250 23Q270 13 290 23L412 87Q430 98 412 108L290 173Q270 183 250 173L128 108Q110 98 128 87Z" fill="none" stroke="#565e4d" stroke-width=".8"/><path d="M118 126v15" stroke="#444c3b" stroke-width="1"/><path d="M121.7 127.93v15" stroke="#444c3b" stroke-width="1"/><path d="M125.4 129.86v15" stroke="#444c3b" stroke-width="1"/><path d="M129.1 131.79v15" stroke="#444c3b" stroke-width="1"/><path d="M132.8 133.72v15" stroke="#444c3b" stroke-width="1"/><path d="M136.5 135.65v15" stroke="#444c3b" stroke-width="1"/><path d="M140.2 137.58v15" stroke="#444c3b" stroke-width="1"/><path d="M143.9 139.51v15" stroke="#444c3b" stroke-width="1"/><path d="M147.6 141.44v15" stroke="#444c3b" stroke-width="1"/><path d="M151.3 143.37v15" stroke="#444c3b" stroke-width="1"/><path d="M155 145.3v15" stroke="#444c3b" stroke-width="1"/><path d="M158.7 147.23v15" stroke="#444c3b" stroke-width="1"/><path d="M162.4 149.16v15" stroke="#444c3b" stroke-width="1"/><path d="M166.1 151.09v15" stroke="#444c3b" stroke-width="1"/><path d="M169.8 153.02v15" stroke="#444c3b" stroke-width="1"/><path d="M173.5 154.95v15" stroke="#444c3b" stroke-width="1"/><path d="M177.2 156.88v15" stroke="#444c3b" stroke-width="1"/><path d="M180.9 158.81v15" stroke="#444c3b" stroke-width="1"/><path d="M184.60000000000002 160.74v15" stroke="#444c3b" stroke-width="1"/><path d="M188.3 162.67000000000002v15" stroke="#444c3b" stroke-width="1"/><path d="M389 151v7" stroke="#444c3b" stroke-width="1"/><path d="M391.6 149.6v7" stroke="#444c3b" stroke-width="1"/><path d="M394.2 148.2v7" stroke="#444c3b" stroke-width="1"/><path d="M396.8 146.8v7" stroke="#444c3b" stroke-width="1"/><path d="M399.4 145.4v7" stroke="#444c3b" stroke-width="1"/><path d="M402 144v7" stroke="#444c3b" stroke-width="1"/><path d="M404.6 142.6v7" stroke="#444c3b" stroke-width="1"/><path d="M407.2 141.2v7" stroke="#444c3b" stroke-width="1"/><path d="M409.8 139.8v7" stroke="#444c3b" stroke-width="1"/><path d="M412.4 138.4v7" stroke="#444c3b" stroke-width="1"/><path d="M415 137v7" stroke="#444c3b" stroke-width="1"/><path d="M417.6 135.6v7" stroke="#444c3b" stroke-width="1"/><ellipse cx="125" cy="98" rx="3.2" ry="1.8" fill="#7d8770"/><ellipse cx="270" cy="24" rx="3.2" ry="1.8" fill="#7d8770"/><ellipse cx="414" cy="98" rx="3.2" ry="1.8" fill="#7d8770"/><ellipse cx="270" cy="173" rx="3.2" ry="1.8" fill="#7d8770"/><g transform="translate(270 98) scale(1 .53) rotate(-45)"><path d="M-8-48H8V-18L29-39 40-28 18-7H48V8H18L40 29 29 40 8 18V48H-8V18L-29 40-40 29-18 8H-48V-8H-18L-40-29-29-40-8-18Z" fill="none" stroke="#777e6e" stroke-width="1.2"/></g><path d="M270 192V216" stroke="#69705f" stroke-width=".6"/></g></g><g class="assembly-module" data-module="1"><g transform="translate(0 195) scale(1 .7)"><path d="M104 105V128Q104 139 119 147L247 214Q270 227 293 214L422 147Q436 140 436 128V105" fill="#11140f" stroke="#69705f" stroke-width="1"/><path d="M116 84L247 15Q270 3 293 15L424 84Q448 97 424 111L293 181Q270 193 247 181L116 111Q92 98 116 84Z" fill="url(#top)" stroke="#69705f" stroke-width="1.2"/><path d="M128 87L250 23Q270 13 290 23L412 87Q430 98 412 108L290 173Q270 183 250 173L128 108Q110 98 128 87Z" fill="none" stroke="#565e4d" stroke-width=".8"/><path d="M118 126v15" stroke="#444c3b" stroke-width="1"/><path d="M121.7 127.93v15" stroke="#444c3b" stroke-width="1"/><path d="M125.4 129.86v15" stroke="#444c3b" stroke-width="1"/><path d="M129.1 131.79v15" stroke="#444c3b" stroke-width="1"/><path d="M132.8 133.72v15" stroke="#444c3b" stroke-width="1"/><path d="M136.5 135.65v15" stroke="#444c3b" stroke-width="1"/><path d="M140.2 137.58v15" stroke="#444c3b" stroke-width="1"/><path d="M143.9 139.51v15" stroke="#444c3b" stroke-width="1"/><path d="M147.6 141.44v15" stroke="#444c3b" stroke-width="1"/><path d="M151.3 143.37v15" stroke="#444c3b" stroke-width="1"/><path d="M155 145.3v15" stroke="#444c3b" stroke-width="1"/><path d="M158.7 147.23v15" stroke="#444c3b" stroke-width="1"/><path d="M162.4 149.16v15" stroke="#444c3b" stroke-width="1"/><path d="M166.1 151.09v15" stroke="#444c3b" stroke-width="1"/><path d="M169.8 153.02v15" stroke="#444c3b" stroke-width="1"/><path d="M173.5 154.95v15" stroke="#444c3b" stroke-width="1"/><path d="M177.2 156.88v15" stroke="#444c3b" stroke-width="1"/><path d="M180.9 158.81v15" stroke="#444c3b" stroke-width="1"/><path d="M184.60000000000002 160.74v15" stroke="#444c3b" stroke-width="1"/><path d="M188.3 162.67000000000002v15" stroke="#444c3b" stroke-width="1"/><path d="M389 151v7" stroke="#444c3b" stroke-width="1"/><path d="M391.6 149.6v7" stroke="#444c3b" stroke-width="1"/><path d="M394.2 148.2v7" stroke="#444c3b" stroke-width="1"/><path d="M396.8 146.8v7" stroke="#444c3b" stroke-width="1"/><path d="M399.4 145.4v7" stroke="#444c3b" stroke-width="1"/><path d="M402 144v7" stroke="#444c3b" stroke-width="1"/><path d="M404.6 142.6v7" stroke="#444c3b" stroke-width="1"/><path d="M407.2 141.2v7" stroke="#444c3b" stroke-width="1"/><path d="M409.8 139.8v7" stroke="#444c3b" stroke-width="1"/><path d="M412.4 138.4v7" stroke="#444c3b" stroke-width="1"/><path d="M415 137v7" stroke="#444c3b" stroke-width="1"/><path d="M417.6 135.6v7" stroke="#444c3b" stroke-width="1"/><ellipse cx="125" cy="98" rx="3.2" ry="1.8" fill="#7d8770"/><ellipse cx="270" cy="24" rx="3.2" ry="1.8" fill="#7d8770"/><ellipse cx="414" cy="98" rx="3.2" ry="1.8" fill="#7d8770"/><ellipse cx="270" cy="173" rx="3.2" ry="1.8" fill="#7d8770"/><g transform="translate(270 98) scale(1 .53) rotate(-45)"><path d="M-8-48H8V-18L29-39 40-28 18-7H48V8H18L40 29 29 40 8 18V48H-8V18L-29 40-40 29-18 8H-48V-8H-18L-40-29-29-40-8-18Z" fill="none" stroke="#777e6e" stroke-width="1.2"/></g><path d="M270 192V216" stroke="#69705f" stroke-width=".6"/></g></g><g class="assembly-module" data-module="2"><g transform="translate(0 355) scale(1 .7)"><path d="M104 105V128Q104 139 119 147L247 214Q270 227 293 214L422 147Q436 140 436 128V105" fill="url(#holo)" stroke="#dfe4d2" stroke-width="1"/><path d="M116 84L247 15Q270 3 293 15L424 84Q448 97 424 111L293 181Q270 193 247 181L116 111Q92 98 116 84Z" fill="url(#top)" stroke="#dfe4d2" stroke-width="1.2"/><path d="M128 87L250 23Q270 13 290 23L412 87Q430 98 412 108L290 173Q270 183 250 173L128 108Q110 98 128 87Z" fill="none" stroke="#f1e9cc" stroke-width=".8"/><path d="M118 126v15" stroke="#35434a" stroke-width="1"/><path d="M121.7 127.93v15" stroke="#35434a" stroke-width="1"/><path d="M125.4 129.86v15" stroke="#35434a" stroke-width="1"/><path d="M129.1 131.79v15" stroke="#35434a" stroke-width="1"/><path d="M132.8 133.72v15" stroke="#35434a" stroke-width="1"/><path d="M136.5 135.65v15" stroke="#35434a" stroke-width="1"/><path d="M140.2 137.58v15" stroke="#35434a" stroke-width="1"/><path d="M143.9 139.51v15" stroke="#35434a" stroke-width="1"/><path d="M147.6 141.44v15" stroke="#35434a" stroke-width="1"/><path d="M151.3 143.37v15" stroke="#35434a" stroke-width="1"/><path d="M155 145.3v15" stroke="#35434a" stroke-width="1"/><path d="M158.7 147.23v15" stroke="#35434a" stroke-width="1"/><path d="M162.4 149.16v15" stroke="#35434a" stroke-width="1"/><path d="M166.1 151.09v15" stroke="#35434a" stroke-width="1"/><path d="M169.8 153.02v15" stroke="#35434a" stroke-width="1"/><path d="M173.5 154.95v15" stroke="#35434a" stroke-width="1"/><path d="M177.2 156.88v15" stroke="#35434a" stroke-width="1"/><path d="M180.9 158.81v15" stroke="#35434a" stroke-width="1"/><path d="M184.60000000000002 160.74v15" stroke="#35434a" stroke-width="1"/><path d="M188.3 162.67000000000002v15" stroke="#35434a" stroke-width="1"/><path d="M389 151v7" stroke="#4f493d" stroke-width="1"/><path d="M391.6 149.6v7" stroke="#4f493d" stroke-width="1"/><path d="M394.2 148.2v7" stroke="#4f493d" stroke-width="1"/><path d="M396.8 146.8v7" stroke="#4f493d" stroke-width="1"/><path d="M399.4 145.4v7" stroke="#4f493d" stroke-width="1"/><path d="M402 144v7" stroke="#4f493d" stroke-width="1"/><path d="M404.6 142.6v7" stroke="#4f493d" stroke-width="1"/><path d="M407.2 141.2v7" stroke="#4f493d" stroke-width="1"/><path d="M409.8 139.8v7" stroke="#4f493d" stroke-width="1"/><path d="M412.4 138.4v7" stroke="#4f493d" stroke-width="1"/><path d="M415 137v7" stroke="#4f493d" stroke-width="1"/><path d="M417.6 135.6v7" stroke="#4f493d" stroke-width="1"/><ellipse cx="125" cy="98" rx="3.2" ry="1.8" fill="#eee6cd"/><ellipse cx="270" cy="24" rx="3.2" ry="1.8" fill="#eee6cd"/><ellipse cx="414" cy="98" rx="3.2" ry="1.8" fill="#eee6cd"/><ellipse cx="270" cy="173" rx="3.2" ry="1.8" fill="#eee6cd"/><g transform="translate(270 98) scale(1 .53) rotate(-45)"><path d="M-8-48H8V-18L29-39 40-28 18-7H48V8H18L40 29 29 40 8 18V48H-8V18L-29 40-40 29-18 8H-48V-8H-18L-40-29-29-40-8-18Z" fill="url(#holo)" stroke="#d1e3de" stroke-width="1.2"/></g><path d="M270 192V216" stroke="#dfe4d2" stroke-width=".6"/></g></g><g class="assembly-module" data-module="3"><g transform="translate(0 515) scale(1 .7)"><path d="M104 105V128Q104 139 119 147L247 214Q270 227 293 214L422 147Q436 140 436 128V105" fill="#11140f" stroke="#69705f" stroke-width="1"/><path d="M116 84L247 15Q270 3 293 15L424 84Q448 97 424 111L293 181Q270 193 247 181L116 111Q92 98 116 84Z" fill="url(#top)" stroke="#69705f" stroke-width="1.2"/><path d="M128 87L250 23Q270 13 290 23L412 87Q430 98 412 108L290 173Q270 183 250 173L128 108Q110 98 128 87Z" fill="none" stroke="#565e4d" stroke-width=".8"/><path d="M118 126v15" stroke="#444c3b" stroke-width="1"/><path d="M121.7 127.93v15" stroke="#444c3b" stroke-width="1"/><path d="M125.4 129.86v15" stroke="#444c3b" stroke-width="1"/><path d="M129.1 131.79v15" stroke="#444c3b" stroke-width="1"/><path d="M132.8 133.72v15" stroke="#444c3b" stroke-width="1"/><path d="M136.5 135.65v15" stroke="#444c3b" stroke-width="1"/><path d="M140.2 137.58v15" stroke="#444c3b" stroke-width="1"/><path d="M143.9 139.51v15" stroke="#444c3b" stroke-width="1"/><path d="M147.6 141.44v15" stroke="#444c3b" stroke-width="1"/><path d="M151.3 143.37v15" stroke="#444c3b" stroke-width="1"/><path d="M155 145.3v15" stroke="#444c3b" stroke-width="1"/><path d="M158.7 147.23v15" stroke="#444c3b" stroke-width="1"/><path d="M162.4 149.16v15" stroke="#444c3b" stroke-width="1"/><path d="M166.1 151.09v15" stroke="#444c3b" stroke-width="1"/><path d="M169.8 153.02v15" stroke="#444c3b" stroke-width="1"/><path d="M173.5 154.95v15" stroke="#444c3b" stroke-width="1"/><path d="M177.2 156.88v15" stroke="#444c3b" stroke-width="1"/><path d="M180.9 158.81v15" stroke="#444c3b" stroke-width="1"/><path d="M184.60000000000002 160.74v15" stroke="#444c3b" stroke-width="1"/><path d="M188.3 162.67000000000002v15" stroke="#444c3b" stroke-width="1"/><path d="M389 151v7" stroke="#444c3b" stroke-width="1"/><path d="M391.6 149.6v7" stroke="#444c3b" stroke-width="1"/><path d="M394.2 148.2v7" stroke="#444c3b" stroke-width="1"/><path d="M396.8 146.8v7" stroke="#444c3b" stroke-width="1"/><path d="M399.4 145.4v7" stroke="#444c3b" stroke-width="1"/><path d="M402 144v7" stroke="#444c3b" stroke-width="1"/><path d="M404.6 142.6v7" stroke="#444c3b" stroke-width="1"/><path d="M407.2 141.2v7" stroke="#444c3b" stroke-width="1"/><path d="M409.8 139.8v7" stroke="#444c3b" stroke-width="1"/><path d="M412.4 138.4v7" stroke="#444c3b" stroke-width="1"/><path d="M415 137v7" stroke="#444c3b" stroke-width="1"/><path d="M417.6 135.6v7" stroke="#444c3b" stroke-width="1"/><ellipse cx="125" cy="98" rx="3.2" ry="1.8" fill="#7d8770"/><ellipse cx="270" cy="24" rx="3.2" ry="1.8" fill="#7d8770"/><ellipse cx="414" cy="98" rx="3.2" ry="1.8" fill="#7d8770"/><ellipse cx="270" cy="173" rx="3.2" ry="1.8" fill="#7d8770"/><g transform="translate(270 98) scale(1 .53) rotate(-45)"><path d="M-8-48H8V-18L29-39 40-28 18-7H48V8H18L40 29 29 40 8 18V48H-8V18L-29 40-40 29-18 8H-48V-8H-18L-40-29-29-40-8-18Z" fill="none" stroke="#777e6e" stroke-width="1.2"/></g><path d="M270 192V216" stroke="#69705f" stroke-width=".6"/></g></g><path d="M436 424H511" stroke="#d7e0c9" stroke-width=".8"/><rect x="506" y="420" width="7" height="7" fill="url(#holo)"/><g fill="#9ca68e" font-family="monospace" font-size="8"><text x="58" y="116">01</text><text x="466" y="261">02</text><text x="58" y="406" fill="#d3f56b">03</text><text x="466" y="551">04</text></g></svg><div class="assembly-progress" aria-hidden="true"><span></span></div><figcaption>HADIX ENGINE <span> / ARQUITETURA MODULAR</span></figcaption></figure><article class="layer layer-reasoning active"><span class="layer-icon">✳</span><p class="micro">03 / INTELLIGENCE</p><h3>Dê sentido aos dados.</h3><p>Agentes combinam contexto, ferramentas e regras para encontrar o próximo passo.</p><span class="layer-detail">RACIOCÍNIO CONECTADO <span>↗</span></span></article><article class="layer layer-action"><span class="layer-icon">↗</span><p class="micro">04 / OUTPUT</p><h3>Faça acontecer.</h3><p>Acione APIs, webhooks e fluxos de trabalho. Leve a decisão para onde ela faz diferença.</p></article></div><div class="section-foot"><span>INDEPENDENTES POR DESIGN. MELHORES JUNTAS.</span><span>✳</span></div></section>
<section class="pipeline wrap section" id="pipeline"><div class="section-heading"><p class="eyebrow">02 / O PIPELINE</p><div><h2>Do dado à ação.<br><span class="muted">Sem perder o contexto.</span></h2><p>Um fluxo contínuo. Quatro etapas para transformar informação em movimento.</p></div></div><div class="pipeline-grid">
<article class="pipeline-card"><div class="card-top"><span>01</span><span>↗</span></div><div class="pipeline-viz bars" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i><i></i><i></i></div><h3>Conecte.</h3><p>Bancos, filas, câmeras e APIs. Reúna suas fontes em um único fluxo.</p><span class="card-label">FONTES → SINAIS</span></article>
<article class="pipeline-card"><div class="card-top"><span>02</span><span>↗</span></div><div class="pipeline-viz scan" aria-hidden="true"><span></span><i></i></div><h3>Entenda.</h3><p>Enriqueça cada sinal com visão, linguagem e as regras do seu negócio.</p><span class="card-label">SINAIS → CONTEXTO</span></article>
<article class="pipeline-card"><div class="card-top"><span>03</span><span>↗</span></div><div class="pipeline-viz nodes" aria-hidden="true"><i></i><i>✳</i><i></i></div><h3>Decida.</h3><p>Orquestre agentes que analisam possibilidades e definem o próximo passo.</p><span class="card-label">CONTEXTO → DECISÃO</span></article>
<article class="pipeline-card"><div class="card-top"><span>04</span><span>↗</span></div><div class="pipeline-viz output" aria-hidden="true">↗</div><h3>Execute.</h3><p>Conecte decisões aos seus sistemas e acompanhe as ações de ponta a ponta.</p><span class="card-label">DECISÃO → IMPACTO</span></article></div></section>
<section class="agents wrap section" id="agents"><div class="section-heading"><p class="eyebrow">03 / OS AGENTES</p><div><h2>Especialistas por natureza.<br><span class="muted">Conectados por inteligência.</span></h2><p>Cada agente tem um papel. Juntos, ampliam o que a sua equipe consegue fazer.</p></div></div><div class="agent-grid">
<article class="agent-card"><span class="agent-icon">◉</span><span class="agent-tag">TEMPO REAL</span><h3>Analista de Sinal</h3><p>Acompanha métricas, filtra ruído e identifica o que merece atenção.</p></article><article class="agent-card"><span class="agent-icon">⌘</span><span class="agent-tag">MEMÓRIA</span><h3>Curador de Contexto</h3><p>Organiza documentos e conversas para manter o conhecimento acessível.</p></article><article class="agent-card"><span class="agent-icon">↗</span><span class="agent-tag">AUTOMAÇÃO</span><h3>Operador de Ação</h3><p>Conecta decisões a fluxos: abre chamados, atualiza sistemas e notifica equipes.</p></article><article class="agent-card"><span class="agent-icon">⌖</span><span class="agent-tag">GOVERNANÇA</span><h3>Auditor Crítico</h3><p>Revisa decisões de acordo com as políticas e os limites do seu negócio.</p></article></div></section>
<section class="cta wrap" id="cta"><span class="cta-symbol" aria-hidden="true">✳</span><p class="eyebrow">04 / O PRÓXIMO PASSO</p><h2>Seu próximo movimento<br>começa com <span class="accent">um sinal.</span></h2><p>Explore como dados e agentes podem trabalhar juntos no seu negócio.</p><a class="btn btn-lime" href="login/">Entrar no Hadix AI <span aria-hidden="true">↗</span></a><p class="cta-note">Conheça as camadas, os agentes e as possibilidades.</p></section>
</main><footer class="footer wrap"><a class="brand" href="#hero"><span class="brand-mark" aria-hidden="true">✳</span>hadix<span class="brand-ai">.ai</span></a><p>© 2026 HADIX AI</p><a href="#hero">VOLTAR AO TOPO ↑</a></footer></body></html>
HX_INDEX

  mkdir -p "$BACKEND_DIR/site/assets/css"
  cat > "$BACKEND_DIR/site/assets/css/style.css" <<'HX_CSS'
:root{--bg:#080909;--white:#eeefeb;--muted:#92968f;--lime:#d3f56b;--line:#ffffff1f;--mono:'IBM Plex Mono',monospace;--sans:'Space Grotesk',sans-serif;color-scheme:dark;font-family:var(--sans);background:var(--bg);color:var(--white);font-synthesis:none}*{box-sizing:border-box}html{scroll-behavior:smooth;scroll-padding-top:40px}body{margin:0;-webkit-font-smoothing:antialiased}a{color:inherit;text-decoration:none}button{font:inherit}img{display:block;max-width:100%}figure,p,h1,h2,h3{margin:0}::selection{background:var(--lime);color:var(--bg)}:focus-visible{outline:2px solid var(--lime);outline-offset:6px}[hidden]{display:none!important}.wrap{width:min(1200px,calc(100% - 128px));margin-inline:auto}.grain{position:fixed;inset:0;z-index:10;pointer-events:none;opacity:.025;background-image:url("data:image/svg+xml,%3Csvg viewBox='0 0 180 180' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Cpath fill='%23fff' filter='url(%23n)' d='M0 0h180v180H0z'/%3E%3C/svg%3E")}.scroll-progress{position:fixed;z-index:40;inset:0 0 auto;height:2px}.scroll-progress span{display:block;height:100%;background:var(--lime);transform:scaleX(0);transform-origin:left}.skip-link{position:fixed;top:10px;left:16px;z-index:100;transform:translateY(-150%);background:var(--lime);color:var(--bg);padding:12px}.skip-link:focus{transform:none}
.topbar{height:90px;width:min(1328px,calc(100% - 80px));margin:auto;display:flex;align-items:center;justify-content:space-between;gap:24px;border-bottom:1px solid var(--line);position:relative;z-index:30}.brand{display:inline-flex;align-items:center;font-size:28px;letter-spacing:-1.5px;font-weight:600;white-space:nowrap}.brand-mark{font-size:40px;margin-right:10px;color:var(--lime);line-height:1}.brand-ai{color:var(--muted)}.nav{display:flex;gap:36px;font:11px var(--mono)}.nav a{color:#bbbeb8;transition:color .15s}.nav a:hover{color:var(--lime)}.btn{border:1px solid #ffffff40;display:inline-flex;align-items:center;justify-content:space-between;gap:30px;padding:17px 22px;font:11px var(--mono);transition:background .15s,border-color .15s,color .15s,transform .15s}.btn span{font:18px var(--sans)}.btn:hover{border-color:var(--lime);background:#d3f56b0d}.btn:active{transform:scale(.98)}.btn-lime{background:var(--lime);border-color:var(--lime);color:#17200b}.btn-lime:hover{background:#e1ff93;color:#111}.header-cta{font-size:10px;padding:11px 15px;gap:24px}.menu-toggle{display:none}.mobile-nav{position:absolute;top:76px;left:20px;right:20px;background:#111310;border:1px solid var(--line);padding:16px;z-index:35}.mobile-nav a{display:block;padding:15px;border-bottom:1px solid var(--line);font:12px var(--mono)}.section-index{position:fixed;left:20px;top:44%;z-index:20;display:grid;gap:18px;font:10px var(--mono)}.section-index a{color:#73786e}.section-index a.active{color:var(--lime)}.section-index a.active:before{content:'';position:absolute;left:-20px;width:12px;height:1px;background:var(--lime);margin-top:6px}
.hero{min-height:700px;display:grid;grid-template-columns:1.03fr 1fr;align-items:center;position:relative;padding:70px 0 88px;gap:20px}.eyebrow{font:10px/1.6 var(--mono);letter-spacing:1.5px;color:var(--lime);display:flex;align-items:center;gap:9px}.status-dot{display:inline-block;width:5px;height:5px;flex-shrink:0;background:var(--lime);border-radius:50%;box-shadow:0 0 12px #d3f56360}.hero h1{font-size:clamp(60px,7.2vw,104px);line-height:1.02;letter-spacing:-6px;font-weight:500;margin:26px 0}.accent{color:var(--lime)}.hero-sub{max-width:390px;font-size:15px;line-height:1.8;color:#a4a79f}.hero-actions{display:flex;flex-wrap:wrap;gap:12px;margin-top:32px}.hero-note{display:flex;align-items:center;gap:12px;margin-top:30px;font:9px/1.7 var(--mono);color:var(--muted)}.tiny-cross{color:var(--lime);font-size:16px}.globe-stage{position:relative;min-width:0;aspect-ratio:1;align-self:center}.globe-art{width:112%;max-width:none;position:absolute;left:-6%;top:-4%;height:112%;object-fit:contain}.scene-label{position:absolute;font:8px/1.5 var(--mono);letter-spacing:1px;color:var(--muted);z-index:1}.scene-label-top{top:0;left:12%;right:0;display:flex;justify-content:space-between}.scene-label-top span{color:#666c60}.scene-label-bottom{bottom:0;left:12%;right:0;display:flex;justify-content:space-between}.globe-tag{position:absolute;right:2%;top:64%;padding:9px 12px;background:#10120dee;border:1px solid #ffffff26;font:8px var(--mono);display:flex;gap:8px;align-items:center}.hero-bottom{position:absolute;bottom:26px;left:0;right:0;display:flex;align-items:center;justify-content:space-between;font:8px var(--mono);letter-spacing:1px;color:#a0a59b}.hero-bottom a{display:flex;gap:20px;align-items:center}.hero-bottom a span{font:20px var(--sans);color:var(--lime)}.signal-strip{border-block:1px solid #d3f56b30;background:#c8ed6505;overflow:hidden}.signal-strip>div{display:flex;justify-content:center;align-items:center;gap:40px;min-width:max-content;padding:16px 28px;font:9px var(--mono);letter-spacing:1.3px;color:#a6ac9d}.signal-strip b{color:var(--lime);font-size:15px;font-weight:400}
.section{padding-top:100px}.section-heading{margin-bottom:44px}.section-heading>.eyebrow{margin-bottom:25px}.section-heading>div{display:flex;align-items:end;justify-content:space-between;gap:40px}h2{font-size:clamp(30px,3.7vw,49px);font-weight:400;letter-spacing:-2px;line-height:1.16}.muted{color:#858a80}.section-heading>div>p{color:#a4a79f;font-size:13px;line-height:1.8;max-width:320px;padding-bottom:4px}.architecture{border:1px solid var(--line);display:grid;grid-template-columns:1fr 1.45fr 1fr;grid-template-rows:repeat(3,230px);background:radial-gradient(ellipse at 52% 42%,#24282255,transparent 65%);position:relative}.layer{padding:30px 27px;position:relative}.layer-icon{font-size:27px;display:block;color:#b9bfb0;line-height:1;margin-bottom:17px}.micro{font:8px var(--mono);color:#878e80;letter-spacing:1px;margin-bottom:10px}.layer h3{font-size:17px;font-weight:400;letter-spacing:-.5px;margin-bottom:11px}.layer>p:not(.micro){font-size:12px;line-height:1.65;color:#969d8f;max-width:240px}.layer-perception{grid-area:1/1;border-bottom:1px solid var(--line)}.layer-memory{grid-area:3/1;border-top:1px solid var(--line)}.layer-reasoning{grid-area:2/3;border-block:1px solid var(--line);background:#ffffff03}.layer-action{grid-area:3/3}.layer.active:before{content:'';position:absolute;top:0;bottom:0;left:-1px;width:3px;background:linear-gradient(#8ce5f5,#d5c1fa,#f1e2a6,#9bdded)}.layer.active .layer-icon{color:var(--lime)}.layer-detail{display:flex;justify-content:space-between;font:7px var(--mono);letter-spacing:.5px;color:var(--lime);margin-top:17px}.stack-stage{grid-area:1/2/4/3;min-width:0;border-inline:1px solid var(--line);display:flex;flex-direction:column;justify-content:center;position:relative}.stack-stage img{width:100%;height:92%;object-fit:contain}.stack-stage figcaption{position:absolute;bottom:15px;left:0;right:0;text-align:center;font:7px var(--mono);letter-spacing:.8px;color:#c3caba}.stack-stage figcaption span{color:#838c79}.section-foot{display:flex;justify-content:space-between;align-items:center;padding-top:18px;font:8px var(--mono);letter-spacing:1px;color:#8c9483}.section-foot>span:last-child{color:var(--lime);font-size:20px}
.pipeline-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));border:1px solid var(--line)}.pipeline-card{padding:23px;min-width:0}.pipeline-card+.pipeline-card{border-left:1px solid var(--line)}.card-top{display:flex;justify-content:space-between;color:#a3ac96;font:10px var(--mono)}.card-top>span:last-child{color:var(--lime);font-size:16px}.pipeline-viz{height:140px;display:flex;align-items:center;justify-content:center;position:relative;margin:18px 0;background-image:radial-gradient(#ffffff16 .6px,transparent .6px);background-size:12px 12px}.pipeline-card h3{font-size:24px;letter-spacing:-1px;font-weight:400;margin-bottom:14px}.pipeline-card>p{font-size:12px;line-height:1.8;color:#969e8f;min-height:87px}.card-label{display:block;border-top:1px solid var(--line);padding-top:18px;margin-top:20px;font:8px var(--mono);letter-spacing:.5px;color:#8b9582}.bars{gap:9px}.bars i{width:7px;height:35px;background:#d3f56b88}.bars i:nth-child(2n){height:65px;background:var(--lime)}.bars i:nth-child(3n){height:45px}.bars i:nth-child(4){height:85px}.scan span{width:78px;height:78px;border:1px solid #d3f56b80;background:repeating-linear-gradient(0deg,transparent 0 8px,#d3f56b15 8px 9px)}.scan i{position:absolute;width:94px;height:1px;background:var(--lime);box-shadow:0 0 15px #d3f56b88}.nodes{gap:29px}.nodes:before{content:'';position:absolute;width:140px;height:1px;background:#d3f56b60}.nodes i{height:12px;width:12px;border:1px solid #d3f56b99;border-radius:50%;position:relative;background:#11160c;font-style:normal}.nodes i:nth-child(2){height:48px;width:48px;display:grid;place-items:center;font-size:30px;color:var(--lime)}.output{font-size:95px;color:var(--lime);font-weight:400}.agent-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px}.agent-card{padding:25px 22px;border:1px solid var(--line);position:relative;transition:border-color .15s,background .15s}.agent-card:hover{border-color:#d3f56b60;background:#d3f56b04}.agent-icon{font-size:29px;color:var(--lime);display:block;margin-bottom:42px}.agent-tag{position:absolute;right:18px;top:35px;font:7px var(--mono);letter-spacing:.6px;color:#929e85}.agent-card h3{font-size:16px;font-weight:400;margin-bottom:12px}.agent-card p{font-size:12px;line-height:1.8;color:#969e8f}
.cta{text-align:center;padding:110px 20px 90px;margin-top:100px;border-block:1px solid var(--line);background:radial-gradient(ellipse at 50% 50%,#b6d75f08,transparent 70%)}.cta-symbol{display:block;color:var(--lime);font-size:45px;margin-bottom:22px}.cta .eyebrow{justify-content:center;margin-bottom:24px}.cta h2{font-size:clamp(34px,4.5vw,62px)}.cta>p:not(.eyebrow){color:#a4ab9c;font-size:13px;margin:23px 0 30px}.cta .btn{min-width:230px;text-align:left}.cta>p.cta-note{font:9px/1.7 var(--mono);color:#909984;margin:20px 0 0}.footer{display:flex;align-items:center;justify-content:space-between;padding:32px 0;gap:20px}.footer .brand{font-size:22px}.footer .brand-mark{font-size:30px}.footer p,.footer>a:last-child{font:8px var(--mono);letter-spacing:1px;color:#959d8b}
@media(min-width:1600px){.hero{min-height:780px}}@media(max-width:1100px){.wrap{width:calc(100% - 96px)}.hero h1{letter-spacing:-4px}.hero-actions .btn{padding:15px;gap:18px;font-size:10px}.architecture{grid-template-columns:1fr 1.3fr 1fr;grid-template-rows:repeat(3,245px)}.layer{padding:24px 20px}.pipeline-card{padding:20px 16px}.agent-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.agent-card{padding:28px}.agent-icon{margin-bottom:28px}}
@media(max-width:800px){html{scroll-padding-top:24px}.wrap{width:calc(100% - 40px)}.topbar{width:calc(100% - 40px);height:76px}.brand{font-size:25px}.brand-mark{font-size:33px}.nav,.header-cta,.section-index{display:none}.menu-toggle{display:flex;flex-direction:column;justify-content:center;gap:7px;width:44px;height:44px;border:1px solid var(--line);background:transparent;padding:11px}.menu-toggle span{height:1px;background:var(--white);width:20px;transition:transform .15s}.menu-toggle[aria-expanded=true] span:first-child{transform:translateY(4px) rotate(45deg)}.menu-toggle[aria-expanded=true] span:last-child{transform:translateY(-4px) rotate(-45deg)}.hero{padding:58px 0 70px;grid-template-columns:1fr;gap:42px;min-height:0}.hero h1{font-size:76px;letter-spacing:-4px}.hero .eyebrow{font-size:9px;letter-spacing:1px}.hero-sub{font-size:14px}.hero-actions .btn{padding:16px 20px;font-size:10px;gap:20px}.hero-note{font-size:8px}.globe-stage{width:min(100%,460px);justify-self:center;margin:0 0 22px}.globe-art{width:104%;left:-2%;height:104%;top:-2%}.scene-label-top,.scene-label-bottom{left:4%;right:4%}.hero-bottom{font-size:7px;letter-spacing:.4px;gap:15px}.hero-bottom>span{max-width:150px;line-height:1.7}.hero-bottom a{gap:10px}.signal-strip>div{gap:24px;font-size:8px}.section{padding-top:70px}.section-heading>div{display:block}.section-heading>div>p{margin-top:20px;max-width:380px}h2{font-size:36px;letter-spacing:-1.7px}.architecture{grid-template-columns:1fr 1fr;grid-template-rows:auto}.stack-stage{grid-area:1/1/2/3;height:560px;border-inline:0;border-bottom:1px solid var(--line)}.stack-stage img{height:100%;padding-bottom:30px}.layer-perception{grid-area:2/1}.layer-memory{grid-area:2/2;border-top:0;border-bottom:1px solid var(--line);border-left:1px solid var(--line)}.layer-reasoning{grid-area:3/1;border-block:0}.layer-action{grid-area:3/2;border-left:1px solid var(--line)}.layer{padding:26px 20px}.layer h3{font-size:17px}.layer>p:not(.micro){font-size:12px}.pipeline-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.pipeline-card:nth-child(3){border-left:0}.pipeline-card:nth-child(n+3){border-top:1px solid var(--line)}.pipeline-card{padding:24px}.pipeline-card>p{min-height:66px}.section-foot{font-size:7px}.cta{margin-top:70px;padding:65px 15px}.cta h2{font-size:39px}.cta>p:not(.eyebrow){line-height:1.8}.footer{flex-wrap:wrap}.footer p{margin-left:auto}.footer>a:last-child{width:100%;text-align:center;margin-top:12px}}
@media(max-width:400px){.hero h1{font-size:65px}.hero-actions{gap:8px}.hero-actions .btn{padding:14px 12px;gap:12px;font-size:9px}.eyebrow{font-size:9px}.hero .eyebrow{font-size:8px}.hero-note{font-size:7px}.layer{padding:23px 14px}.layer h3{font-size:15px}.layer>p:not(.micro){font-size:11px}.layer-detail{font-size:6px}.pipeline-card{padding:18px 14px}.pipeline-card>p{min-height:87px}.agent-grid{grid-template-columns:1fr}.stack-stage{height:450px}.section-foot{font-size:6px}.cta h2{font-size:33px}}
@media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}*,*:before,*:after{animation:none!important;transition:none!important}}
/* Progressive 2D assembly: the static SVG is the complete fallback. */
.stack-stage .assembly-svg{display:block;width:100%;height:86%;overflow:visible}
.assembly-status{position:absolute;top:18px;left:20px;right:20px;display:flex;align-items:center;gap:8px;font:8px/1.5 var(--mono);color:#adb7a0;letter-spacing:.3px}
#assemblyPercent{margin-left:auto;color:var(--lime)}
.assembly-progress{position:absolute;bottom:40px;left:24px;right:24px;height:2px;background:#d3f56b16}
.assembly-progress span{display:block;height:100%;background:linear-gradient(90deg,#87dfec,var(--lime));transform-origin:left}
.layer{transition:background .3s ease}.layer.active{background:#d3f56b07}.layer.is-built .micro{color:var(--lime)}
@media(max-width:800px){.stack-stage .assembly-svg{height:83%;width:100%}.assembly-status{top:14px;font-size:8px}.assembly-progress{bottom:34px}}
@media(max-width:400px){.assembly-status{left:14px;right:14px;font-size:7px}}
/* Four scenes share one fixed viewport; each scene can scroll if content needs it. */
.scene-mode{overflow:hidden;height:100dvh}
.scene-mode .topbar{position:fixed;top:0;left:40px;right:40px;width:auto;height:76px;background:#080909e8;backdrop-filter:blur(14px)}
.scene-mode #main{position:fixed;inset:76px 0 48px;isolation:isolate}
.scene-mode #main>.scene{position:absolute;inset:0;width:100%;height:100%;min-height:0;margin:0;padding:28px max(64px,calc((100vw - 1200px)/2));overflow-y:auto;overflow-x:hidden;overscroll-behavior-y:contain;scrollbar-width:thin;scrollbar-color:#d3f56b40 transparent;outline:none}
.scene-mode #hero{display:grid;grid-template-columns:1fr 1fr;gap:30px;align-content:center;padding-bottom:70px}
.scene-mode .hero h1{font-size:clamp(60px,7.4vw,104px)}
.scene-mode .globe-stage{width:min(100%,520px);justify-self:center}
.scene-mode .hero-bottom{left:max(64px,calc((100vw - 1200px)/2));right:max(64px,calc((100vw - 1200px)/2));bottom:15px}
.scene-mode .signal-strip,.scene-mode>.footer{display:none}
.scene-mode .section-heading{margin-bottom:24px}
.scene-mode .section-heading>.eyebrow{margin-bottom:12px}
.scene-mode h2{font-size:clamp(28px,3.1vw,43px)}
.scene-mode .section-heading>div>p{font-size:12px}
.scene-mode .architecture{grid-template-rows:repeat(3,minmax(150px,1fr));height:clamp(450px,calc(100dvh - 330px),650px)}
.scene-mode .layer{padding:16px 20px}.scene-mode .layer-icon{font-size:22px;margin-bottom:10px}.scene-mode .layer h3{font-size:15px;margin-bottom:6px}.scene-mode .layer>p:not(.micro){font-size:11px;line-height:1.5}.scene-mode .micro{margin-bottom:7px}.scene-mode .layer-detail{margin-top:10px}
.scene-mode .stack-stage{height:100%}.scene-mode .section-foot{padding-top:8px}
.scene-mode #pipeline,.scene-mode #agents{display:flex;flex-direction:column;justify-content:safe center}
.scene-mode .pipeline-viz{height:clamp(90px,18vh,170px)}
.scene-mode .agent-grid{grid-template-columns:repeat(4,minmax(0,1fr))}
.scene-mode #agents .cta{width:100%;margin:28px 0 0;padding:22px 0 0;display:flex;align-items:center;justify-content:space-between;gap:20px;text-align:left;border-bottom:0;background:none}
.scene-mode #agents .cta h2{font-size:24px;letter-spacing:-1px}.scene-mode #agents .cta .cta-symbol,.scene-mode #agents .cta>p{display:none}
.scene-controls{position:fixed;bottom:0;left:40px;right:40px;height:48px;display:flex;align-items:center;gap:20px;border-top:1px solid var(--line);z-index:30;background:#080909;font:9px var(--mono);letter-spacing:1px}
.scene-controls .scene-current{color:var(--lime)}.scene-controls .scene-hint{margin-left:auto;color:#92968f}.scene-controls button{background:transparent;border:1px solid var(--line);color:var(--white);width:34px;height:30px;cursor:pointer;font-size:18px}.scene-controls button:hover{border-color:var(--lime);color:var(--lime)}.scene-controls button:disabled{opacity:.25;cursor:default}
.scene-orbit{position:fixed;left:57%;top:45%;width:48vw;height:48vw;max-width:750px;max-height:750px;border:1px solid #d3f56b12;border-radius:50%;pointer-events:none;z-index:-1;transform:translate(-50%,-50%)}
.scene-orbit:after{content:'';position:absolute;inset:12%;border:1px dashed #d3f56b0c;border-radius:50%}
@media(max-width:1100px) and (min-width:801px){.scene-mode #main>.scene{padding-inline:55px}.scene-mode .layer{padding:14px}.scene-mode .architecture{grid-template-columns:1fr 1.1fr 1fr}.scene-mode .agent-card{padding:20px 15px}.scene-mode .agent-tag{font-size:6px;right:12px}}
@media(max-width:800px){.scene-mode .topbar{left:20px;right:20px}.scene-mode #main>.scene{padding:28px 20px 30px}.scene-mode #hero{grid-template-columns:1fr;align-content:start;gap:28px;padding-bottom:65px}.scene-mode .hero h1{font-size:65px;margin:18px 0}.scene-mode .hero-sub{font-size:13px}.scene-mode .hero-note{margin-top:18px}.scene-mode .hero-actions{margin-top:22px}.scene-mode .globe-stage{width:min(75%,340px);margin:0 auto 30px}.scene-mode .hero-bottom{position:relative;left:auto;right:auto;bottom:auto}.scene-mode .section-heading>div>p{margin-top:12px}.scene-mode .architecture{height:auto;grid-template-rows:auto}.scene-mode .stack-stage{height:350px}.scene-mode .layer{padding:20px 14px}.scene-mode .agent-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.scene-mode .agent-card{padding:22px 15px}.scene-mode .agent-tag{font-size:6px;right:10px}.scene-mode #agents .cta{align-items:start;flex-direction:column}.scene-mode #agents .cta h2{font-size:25px}.scene-mode .pipeline-card{padding:20px 14px}.scene-controls{left:20px;right:20px;gap:12px;font-size:8px}.scene-controls .scene-hint{font-size:0}.scene-controls .scene-hint:after{content:'DESLIZE';font-size:7px}.scene-orbit{width:90vw;height:90vw;top:45%}.scene-mode #pipeline,.scene-mode #agents{justify-content:flex-start}}
@media(max-height:650px) and (min-width:801px){.scene-mode #hero{align-content:start}.scene-mode .globe-stage{width:330px}.scene-mode .hero h1{font-size:64px}.scene-mode .hero-note{display:none}.scene-mode #pipeline,.scene-mode #agents{justify-content:flex-start}}
@media(min-width:801px){.scene-mode .architecture{grid-template-rows:repeat(3,minmax(140px,1fr));height:clamp(420px,calc(100dvh - 380px),600px)}}
.scene-mode .nav a.active{color:var(--lime)}
.planet-canvas{position:absolute;inset:0;width:100%;height:100%;z-index:3;pointer-events:none;visibility:hidden}
.planet-ready .globe-art{opacity:0!important}.planet-ready .globe-stage{position:relative}.planet-ready .globe-stage .scene-label,.planet-ready .globe-tag{z-index:4}
.scene-mode .layer.active{box-shadow:inset 0 0 32px #d3f56b05}.assembly-svg{isolation:isolate}
.planet-entry{position:absolute;inset:8% 0;z-index:6;border-radius:50%;display:flex;align-items:flex-end;justify-content:center;cursor:pointer}.planet-entry span{font:8px var(--mono);letter-spacing:1px;color:var(--lime);background:#080909dd;border:1px solid #d3f56b35;padding:10px 14px;transform:translateY(15px);opacity:0;transition:opacity .2s,transform .2s}.planet-entry:hover span,.planet-entry:focus-visible span{opacity:1;transform:translateY(0)}
@media(hover:none){.planet-entry span{opacity:1;transform:none;font-size:7px}}
/* Shared technical space: a quiet square grid and a perspective floor. */
body{isolation:isolate}.spatial-backdrop{--grid-tilt:61deg;--grid-shift:0px;position:fixed;inset:0;overflow:hidden;z-index:-1;pointer-events:none;background:radial-gradient(ellipse at 75% 45%,#29443222,transparent 65%),#080909;perspective:900px}
.grid-wall{position:absolute;inset:0;background-image:linear-gradient(#bfd8b610 1px,transparent 1px),linear-gradient(90deg,#bfd8b610 1px,transparent 1px);background-size:64px 64px;mask-image:linear-gradient(90deg,#0009,#0003 35%,#000 80%)}
.grid-floor{position:absolute;left:-40%;right:-40%;height:85%;bottom:-35%;background-image:linear-gradient(#b8d6a62a 1px,transparent 1px),linear-gradient(90deg,#b8d6a62a 1px,transparent 1px);background-size:64px 64px;transform:rotateX(var(--grid-tilt)) translateY(var(--grid-shift));transform-origin:center top;mask-image:linear-gradient(transparent,#000 35%,#0008)}
.adaptive-canvas{position:absolute;inset:0;width:100%;height:100%;opacity:.85;mask-image:linear-gradient(90deg,transparent 15%,#0007 45%,#000 75%)}
.scene-mode .scene-orbit{opacity:.35}.scene-mode .architecture{background:radial-gradient(ellipse at 52% 42%,#17201ba6,#080b09b3)}.scene-mode .pipeline-grid,.scene-mode .agent-card{background:#080b09ba}.scene-mode .hero-copy{position:relative;z-index:1}
@media(max-width:800px){.grid-wall,.grid-floor{background-size:40px 40px}.grid-wall{opacity:.65}.adaptive-canvas{opacity:.5;mask-image:linear-gradient(transparent 10%,#0006 40%,#000 75%)}.grid-floor{height:60%;bottom:-18%}}
HX_CSS

  mkdir -p "$BACKEND_DIR/site"
  cat > "$BACKEND_DIR/site/chat.html" <<'HX_CHAT'
<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="#08090a">
<meta id="hadix-csp" http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data: blob:; connect-src 'self' https: http://localhost:* http://127.0.0.1:* http://[::1]:*; base-uri 'none'; form-action 'none';">
<title>Hadix AI — Workspace</title>
<style>
:root{color-scheme:dark;--bg:#08090a;--panel:#12151a;--border:#262b33;--text:#e7ebee;--muted:#9ca6af;--lime:#d6ecc1;--blue:#85ddf4;font:14px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif;background:var(--bg);color:var(--text)}*{box-sizing:border-box}body{margin:0;min-width:300px;background:radial-gradient(ellipse at 80% 0%,#b9d99a07,transparent 60%)}body:before{content:'';position:fixed;inset:0;pointer-events:none;z-index:-1;background-image:linear-gradient(#d6ecc106 1px,transparent 1px),linear-gradient(90deg,#d6ecc106 1px,transparent 1px);background-size:48px 48px}button,input,textarea,select{font:inherit}button{cursor:pointer}button:disabled{cursor:default;opacity:.5}button,a,input,textarea,select{outline-offset:4px}:focus-visible{outline:2px solid var(--blue)}[hidden]{display:none!important}h1,h2,h3,p{margin:0}h1,h2,h3{font-weight:500;letter-spacing:-.035em}a{color:var(--blue)}button{color:var(--text);background:#171b21;border:1px solid var(--border);border-radius:9px;padding:9px 13px;transition:background .15s,border-color .15s}button:hover{border-color:#9cae89;background:#212720}.primary{background:var(--lime);color:#172013;border-color:var(--lime);font-weight:600}.primary:hover{background:#b9d99a}.danger{color:#ffb6b6}.ghost{background:transparent}.topbar{height:78px;border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between;padding:0 30px;gap:20px;background:#08090aee}.brand{font-size:25px;font-weight:650;letter-spacing:-1px;display:flex;align-items:center;gap:9px}.brand-mark{color:var(--lime);font-size:35px;line-height:1}.brand small{font-size:inherit;color:var(--muted);margin-left:-8px}.brand-label{font:10px ui-monospace,monospace;color:var(--muted);letter-spacing:2px;border-left:1px solid var(--border);margin-left:18px;padding-left:18px}.top-actions{display:flex;align-items:center;gap:12px}.status-pill{display:flex;align-items:center;gap:8px;border:1px solid var(--border);padding:7px 11px;border-radius:20px;font-size:11px;color:var(--muted)}.dot{height:6px;width:6px;border-radius:50%;background:var(--muted)}[data-status=ready] .dot{background:var(--lime);box-shadow:0 0 12px #b9d99a55}[data-status=busy] .dot{background:var(--blue)}[data-status=error] .dot{background:#f2a0a0}.layout{max-width:1720px;margin:0 auto;display:grid;grid-template-columns:230px minmax(320px,1fr) 266px;min-height:calc(100dvh - 78px)}.sidebar{padding:26px 18px;border-right:1px solid var(--border);display:flex;flex-direction:column;gap:22px;min-width:0}.label{font:10px/1.6 ui-monospace,monospace;letter-spacing:1.3px;text-transform:uppercase;color:var(--muted)}.sidebar-head{display:flex;align-items:center;justify-content:space-between}.sidebar-head span{color:var(--lime)}.wide{width:100%}.conversation-list{display:flex;flex-direction:column;gap:7px;max-height:48dvh;overflow:auto}.conversation-button{text-align:left;background:transparent;border-color:transparent;width:100%;padding:11px 12px;overflow:hidden}.conversation-button strong{font-weight:500;font-size:12px;display:block;text-overflow:ellipsis;overflow:hidden;white-space:nowrap}.conversation-button small{display:block;color:var(--muted);font-size:10px;margin-top:4px}.conversation-button[aria-current=true]{background:#d6ecc10b;border-color:#d6ecc12a}.conversation-button[aria-current=true] strong{color:var(--lime)}.model-box{border:1px solid var(--border);border-radius:12px;padding:16px;background:#101318}.model-box .model-name{font-size:13px;margin:12px 0 5px;overflow-wrap:anywhere}.model-box .model-icon{color:var(--lime);font-size:20px}.muted{color:var(--muted)}.small{font-size:11px}.sidebar-bottom{margin-top:auto;font-size:11px;color:var(--muted);line-height:1.8}.chat-main{min-width:0;padding:26px 28px 20px;display:flex;flex-direction:column;height:calc(100dvh - 78px)}.chat-heading{display:flex;justify-content:space-between;align-items:center;gap:15px;padding-bottom:22px;border-bottom:1px solid var(--border)}.chat-heading h1{font-size:23px;overflow-wrap:anywhere}.chat-heading .label{color:var(--lime);margin-bottom:5px}.chat-tools{display:flex;gap:7px}.chat-tools button{font-size:11px}.messages{flex:1;min-height:180px;overflow:auto;padding:25px 0;scrollbar-width:thin;scrollbar-color:#394231 transparent;overscroll-behavior:contain}.welcome{max-width:520px;margin:clamp(20px,6vh,85px) auto;text-align:center;padding:15px}.welcome .symbol{width:62px;height:62px;display:grid;place-items:center;border:1px solid #d6ecc12a;border-radius:16px;margin:0 auto 22px;color:var(--lime);font-size:36px;background:radial-gradient(#d6ecc110,transparent)}.welcome h2{font-size:clamp(28px,3vw,40px);line-height:1.14;margin-bottom:17px}.accent{color:var(--lime)}.welcome p{color:var(--muted);font-size:13px;max-width:360px;margin:auto}.suggestions{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:30px;text-align:left}.suggestions button{font-size:12px;text-align:left;padding:15px;background:#12151aaa}.suggestions button span{display:block;font-size:10px;color:var(--muted);margin-top:7px}.message{padding:18px;margin:0 0 16px;border:1px solid var(--border);border-radius:12px;background:#12151abf;overflow-wrap:anywhere}.message.user{margin-left:10%;background:#d6ecc108;border-color:#d6ecc126}.message-header{display:flex;gap:10px;align-items:center;margin-bottom:11px;color:var(--lime);font:10px ui-monospace,monospace;text-transform:uppercase;letter-spacing:.8px}.message.assistant .message-header{color:var(--blue)}.message-header button{margin-left:auto;padding:3px 8px;font:10px system-ui;text-transform:none;letter-spacing:0}.message-body{font-size:14px;line-height:1.75}.message-body p{margin:0 0 10px;white-space:pre-wrap}.message-body p:last-child{margin-bottom:0}.message-body h3{font-size:18px;margin:12px 0}.message-body ul{padding-left:22px}.message-body pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#08090a;padding:14px;border:1px solid var(--border);border-radius:8px;font:12px/1.7 ui-monospace,monospace}.message-body code{color:#c9e3bc;background:#08090a;padding:2px 4px;border-radius:3px}.message-note{color:var(--muted);font-size:12px;margin-top:10px}.message.error{border-color:#f2a0a044}.message.error .message-note{color:#ffb6b6}.loading{display:flex;align-items:center;gap:5px;padding:8px 0}.loading i{width:6px;height:6px;background:var(--blue);border-radius:50%;animation:pulse 1.2s infinite}.loading i:nth-child(2){animation-delay:.2s}.loading i:nth-child(3){animation-delay:.4s}@keyframes pulse{50%{opacity:.2;transform:translateY(-3px)}}.composer{padding:14px;background:#12151a;border:1px solid #d6ecc133;border-radius:14px;box-shadow:0 8px 40px #0002}.composer textarea{border:0;background:transparent;color:var(--text);width:100%;min-height:62px;max-height:160px;resize:vertical;padding:5px;outline-offset:0}.composer textarea::placeholder{color:#9ca6af}.composer-foot{display:flex;align-items:center;gap:10px;justify-content:space-between}.composer-hint{font-size:10px;color:var(--muted)}.composer-controls{display:flex;gap:8px}.composer-controls button{font-size:12px;padding:9px 17px}.under-composer{font-size:10px;text-align:center;color:var(--muted);padding-top:12px;min-height:28px}.session{padding:26px 18px;border-left:1px solid var(--border);display:flex;flex-direction:column;gap:16px}.session .card{padding:18px;border:1px solid var(--border);border-radius:12px;background:#12151acc}.session h2{font-size:16px;margin-bottom:16px}.session dl{margin:0;display:grid;gap:14px}.session dt{font-size:10px;color:var(--muted);margin-bottom:3px}.session dd{margin:0;font-size:12px;overflow-wrap:anywhere}.session .status-text{color:var(--lime)}.metric{font-size:29px;letter-spacing:-1px;color:var(--blue);margin:12px 0 5px}.session select{width:100%;margin:6px 0 12px}.session label{font-size:11px;color:var(--muted)}input,select{background:#0c0f12;border:1px solid #39414b;border-radius:8px;padding:11px;color:var(--text);min-width:0}input{width:100%}.export-button{width:100%;margin-top:4px}.notice{font-size:11px;color:var(--blue);white-space:pre-wrap;overflow-wrap:anywhere}.global-notice{max-width:900px;margin:0 auto;color:#ffcb9c}.connection-card{background:radial-gradient(ellipse at 100% 0,#d6ecc110,transparent 70%),#12151a!important}.connection-card p{font-size:12px;color:var(--muted);margin:10px 0 14px}.connection-card button{width:100%;font-size:12px}.login-dialog{color:var(--text);background:#12151a;border:1px solid #39414b;border-radius:16px;padding:28px;width:min(440px,calc(100% - 32px));max-height:90dvh;overflow:auto}.login-dialog::backdrop{background:#050608bb;backdrop-filter:blur(6px)}.login-dialog h2{font-size:25px;margin-bottom:8px}.login-dialog p{font-size:12px;color:var(--muted);margin-bottom:22px}.form-field{display:flex;flex-direction:column;gap:7px;margin-bottom:17px}.form-field label{font-size:12px;color:var(--muted)}.checkbox-row{display:flex;align-items:center;gap:8px;font-size:11px;color:var(--muted);margin-bottom:18px}.checkbox-row input{width:16px}.dialog-actions{display:flex;justify-content:flex-end;gap:10px;margin-top:18px}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}.badge{font:9px ui-monospace,monospace;border:1px solid var(--border);padding:3px 7px;border-radius:5px;color:var(--muted)}.session-top{display:flex;align-items:center;justify-content:space-between;margin-bottom:8px}.session-top button{padding:4px 7px;font-size:11px}.mobile-conversations{display:none}.storage-notice{padding:0 25px}.dashboard-footer{font-size:10px;color:var(--muted);margin-top:auto}.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:20;background:#202a21;border:1px solid #d6ecc155;padding:10px 20px;border-radius:10px;max-width:calc(100% - 32px);font-size:12px}
@media(min-width:1550px){.chat-main{padding-inline:45px}}@media(max-width:1150px){.layout{grid-template-columns:195px minmax(300px,1fr)}.session{grid-column:1/-1;border-left:0;border-top:1px solid var(--border);display:grid;grid-template-columns:repeat(3,1fr)}.session>.label,.dashboard-footer{display:none}.chat-main{height:calc(100dvh - 78px)}.brand-label{display:none}}@media(max-width:700px){.topbar{height:68px;padding:0 17px;gap:10px}.brand{font-size:22px}.brand-mark{font-size:30px}.top-actions{gap:7px}.top-actions .status-pill{display:none}.top-actions button{font-size:11px;padding:8px 10px}.layout{display:block}.sidebar{display:none;border:0;border-bottom:1px solid var(--border)}.sidebar.is-open{display:flex}.sidebar-bottom{display:none}.model-box{display:none}.mobile-conversations{display:inline-block}.chat-main{height:calc(100dvh - 68px);min-height:550px;padding:20px 17px}.chat-heading{gap:8px;padding-bottom:15px}.chat-heading h1{font-size:19px}.chat-heading .label{font-size:9px}.chat-tools button{padding:7px;font-size:10px}.welcome{margin:20px auto}.welcome h2{font-size:32px}.welcome .symbol{margin-bottom:16px}.suggestions{margin-top:22px}.suggestions button{padding:12px;font-size:11px}.message{padding:14px}.message.user{margin-left:5%}.message-body{font-size:13px}.composer-hint{max-width:150px;font-size:9px}.session{grid-template-columns:1fr;padding:20px 17px}.session>.label{display:block}.session .card{padding:20px}.session .connection-card{order:3}.session .export-card{order:2}.chat-tools .clear-label{display:none}.login-dialog{padding:23px}.composer textarea{max-height:110px}.message-header{font-size:9px}}
@media(prefers-reduced-motion:reduce){*,*:before,*:after{animation:none!important;transition:none!important;scroll-behavior:auto!important}}

body.auth-screen .layout,body.auth-screen .topbar{display:none}body.auth-screen{min-height:100dvh;background:radial-gradient(ellipse at 50% 20%,#b9d99a14,transparent 60%),#08090a}body.auth-screen .login-dialog{position:fixed;inset:0;margin:auto;padding:36px;width:min(460px,calc(100% - 32px));box-shadow:0 24px 100px #0008}body.auth-screen .login-dialog::backdrop{background:transparent;backdrop-filter:none}.login-brand{font-size:26px;font-weight:650;color:var(--lime);margin-bottom:28px}.login-back{display:block;text-align:center;margin-top:22px;font-size:12px;color:var(--muted)}body:not(.auth-screen) .login-back{display:none}.login-dialog .primary{min-width:150px}.service-alert{margin:12px 0 0;padding:13px 16px;border:1px solid #d6ecc13a;border-radius:10px;background:#171c14;color:var(--lime);font-size:12px}.service-alert button{margin-top:9px;display:block;font-size:11px}.messages>.message{max-width:820px;margin-right:auto}.messages>.message.user{margin-left:auto;max-width:680px}.composer{width:100%;max-width:860px;margin-inline:auto}.messages{padding-inline:6px}.chat-main{min-height:0}.sidebar .sidebar-bottom button{margin-top:16px;width:100%;text-align:left}.session-toggle{font-size:11px}.session-collapsed .layout{grid-template-columns:230px minmax(320px,1fr)}.session-collapsed .session{display:none}@media(max-width:700px){.session-collapsed .layout{display:block}.chat-heading h1{font-size:18px}.session-toggle{padding:6px!important}.login-dialog h2{font-size:26px}}
</style>
</head>
<body class="auth-screen">
<header class="topbar"><div class="brand"><span class="brand-mark" aria-hidden="true">✳</span>hadix<small>.ai</small><span class="brand-label">INTELLIGENCE WORKSPACE</span></div><div class="top-actions"><span id="topStatus" class="status-pill" data-status="offline"><i class="dot" aria-hidden="true"></i><span>Desconectada</span></span><button class="mobile-conversations ghost" id="toggleConversations" type="button" aria-expanded="false" aria-controls="sidebar">Conversas</button><button class="ghost" id="connectBtn" type="button">Conectar API ↗</button><button class="ghost" id="logoutBtn" type="button" hidden>Sair</button></div></header>
<div id="storageNotice" class="notice storage-notice" role="status"></div>
<main class="layout" id="dashboard">
<aside class="sidebar" id="sidebar" aria-label="Conversas e modelo"><div class="sidebar-head"><p class="label">Seu espaço</p><span aria-hidden="true">⌘</span></div><button class="primary wide" id="newConversation" type="button">+ Nova conversa</button><div><p class="label" style="margin-bottom:12px">Conversas recentes</p><div id="conversationList" class="conversation-list"></div></div><div class="model-box"><span class="model-icon" aria-hidden="true">✳</span><p class="model-name" id="sidebarModel">Conecte seu modelo</p><p class="small muted">Inteligência na sua infraestrutura.</p></div><div class="sidebar-bottom"><button id="sidebarLogout" class="ghost" type="button">↪ Sair da conta</button><br>Sinal vira decisão.<br>Seu contexto, suas possibilidades.<p class="badge" id="environmentBadge" style="margin-top:13px;display:inline-block">NAVEGADOR</p></div></aside>
<section class="chat-main" aria-label="Chat"><div class="chat-heading"><div><p class="label">HADIX / CONVERSAÇÃO</p><h1 id="conversationTitle">Nova conversa</h1></div><div class="chat-tools"><button id="toggleSession" class="session-toggle" type="button" aria-expanded="false">Sessão</button><button id="clearConversation" type="button" aria-label="Limpar conversa selecionada">Limpar<span class="clear-label"> conversa</span></button></div></div><div id="serviceAlert" class="service-alert" role="status" hidden><span id="serviceMessage"></span><button id="retryReady" type="button">Verificar novamente</button></div><div class="messages" id="messages" role="log" aria-label="Mensagens da conversa" aria-live="polite" aria-relevant="additions text"></div><form id="chatForm" class="composer"><label class="sr-only" for="chatInput">Sua mensagem</label><textarea id="chatInput" placeholder="Escreva seu próximo sinal…" rows="2" maxlength="8000" aria-describedby="composerHint"></textarea><div class="composer-foot"><span class="composer-hint" id="composerHint">Enter envia · Shift+Enter quebra a linha</span><div class="composer-controls"><button id="stopBtn" class="danger" type="button" hidden>Parar ■</button><button id="sendBtn" class="primary" type="submit">Enviar ↑</button></div></div></form><p class="under-composer" id="chatNotice" role="status">Conecte sua API para começar. O histórico fica neste dispositivo.</p></section>
<aside class="session" aria-label="Sessão e exportação"><p class="label">Visão da sessão</p><section class="card"><div class="session-top"><h2>Sessão atual</h2><button id="refreshStatus" type="button" aria-label="Atualizar status da API">↻</button></div><dl><div><dt>STATUS</dt><dd id="sessionStatus" class="status-text" role="status">Desconectada</dd></div><div><dt>MODELO</dt><dd id="sessionModel">—</dd></div><div><dt>ENDPOINT</dt><dd id="sessionBase">Não configurado</dd></div><div><dt>CONCORRÊNCIA</dt><dd id="sessionParallel">—</dd></div></dl><p class="label" style="margin-top:23px">Última resposta</p><p class="metric" id="latency">—</p><p class="small muted" id="lastChecked">Verificação a cada 30 segundos</p></section><section class="card export-card"><h2>Leve a conversa.</h2><label for="exportScope">O que exportar</label><select id="exportScope"><option value="conversation">Conversa selecionada</option><option value="dashboard">Dashboard completo</option><option value="session">Resumo da sessão</option></select><label for="exportFormat">Formato</label><select id="exportFormat"><option value="png">PNG · imagem</option><option value="svg">SVG · vetorial</option></select><button class="ghost export-button" id="exportBtn" type="button">Exportar imagem ↗</button><p class="notice" id="exportNotice" role="status" style="margin-top:10px"></p></section><section class="card connection-card"><p class="label">Seu ambiente</p><h2 style="margin:10px 0">Inteligência conectada.</h2><p>Conecte a API Hadix e transforme uma pergunta no próximo passo.</p><button id="settingsBtn" type="button">Configurar conexão</button><p class="small" id="transportNote" style="margin-bottom:0">Sem dependências externas.</p></section><p class="dashboard-footer">HADIX AI / 2026<br>Feito para continuar de onde você parou.</p></aside>
</main>
<dialog class="login-dialog" id="loginDialog" aria-labelledby="loginTitle"><div class="login-brand">✳ hadix.ai</div><h2 id="loginTitle">Entre no seu espaço.</h2><p>Suas conversas e próximos passos em um só lugar. Entre com seu token de acesso.</p><form id="loginForm"><div class="form-field"><label for="apiBase">URL da API</label><input id="apiBase" type="url" value="https://api.hadix.site" required spellcheck="false" autocomplete="url"></div><div class="form-field"><label for="apiToken">Token de acesso</label><input id="apiToken" type="password" autocomplete="off" spellcheck="false" placeholder="Bearer token"></div><label class="checkbox-row" id="rememberRow"><input id="rememberToken" type="checkbox">Lembrar conexão neste navegador</label><p class="small" id="credentialNote">Sem marcar, a conexão dura somente nesta aba.</p><p class="notice danger" id="loginError" role="alert"></p><div class="dialog-actions"><button id="cancelLogin" type="button">Agora não</button><button id="loginBtn" class="primary" type="submit">Entrar no Hadix ↗</button></div></form><a class="login-back" href="../index.html">← Voltar para a página inicial</a></dialog>
<dialog class="login-dialog" id="clearDialog" aria-labelledby="clearTitle"><h2 id="clearTitle">Limpar esta conversa?</h2><p>As mensagens desta conversa serão removidas deste dispositivo.</p><div class="dialog-actions"><button id="cancelClear" type="button">Cancelar</button><button id="confirmClear" class="danger" type="button">Limpar mensagens</button></div></dialog>
<div class="toast" id="toast" role="status" hidden></div>
<noscript><p>Ative JavaScript para conversar e exportar. O dashboard não precisa de CDNs.</p></noscript>
<!-- HADIX_HOST_CONFIG -->
<script>
'use strict';
(() => {
const $ = id => document.getElementById(id);
let host;
try { host = typeof acquireVsCodeApi === 'function' ? acquireVsCodeApi() : window.__VSCODE__; } catch { host = window.__VSCODE__; }
const isHost = !!host?.postMessage;
const hostConfig = window.__HADIX_HOST_CONFIG__ || {};
const useBridge = isHost && hostConfig.transport !== 'direct';
if(isHost)document.body.classList.remove('auth-screen');
document.body.classList.add('session-collapsed');
function screen(authenticated){
 if(isHost)return;
 document.body.classList.toggle('auth-screen',!authenticated);
 $('cancelLogin').hidden=!authenticated;
 if(location.protocol==='http:'||location.protocol==='https:'){
  const base=location.pathname.replace(/(?:app|login)\/(?:index\.html)?$|(?:dashboard|chat|index)\.html$/,'');
  history.replaceState(null,'',base+(authenticated?'app/':'login/'));
 }
}
function tabConnection(value){try{if(value)sessionStorage.setItem('hadix.session',JSON.stringify(value));else sessionStorage.removeItem('hadix.session');}catch{}}
$('toggleSession').addEventListener('click',()=>{const hidden=document.body.classList.toggle('session-collapsed');$('toggleSession').setAttribute('aria-expanded',String(!hidden));});
$('sidebarLogout').addEventListener('click',()=>$('logoutBtn').click());
$('retryReady').addEventListener('click',()=>void checkReady());
$('loginDialog').addEventListener('cancel',event=>{if(!connected&&!isHost)event.preventDefault();});
const pending = new Map();
let rpcId = 0, toastTimer, pollTimer, pollController, connected = false, inflight = null, epoch = 0;
let config = { model: '', maxParallel: 1 }, credentials = { base: 'https://api.hadix.site', token: '' };
let lastStatus = 'offline', latency = null, tokenForRedaction = '', storedHostToken = false;
let conversations = [], selected = '', clearTarget = '', initialized = false;
const uid = () => globalThis.crypto?.randomUUID?.() || Date.now().toString(36) + Math.random().toString(36).slice(2);
const storage = {
 get(key) { try { return JSON.parse(localStorage.getItem(key) || 'null'); } catch { return null; } },
 set(key, value) { try { localStorage.setItem(key, JSON.stringify(value)); return true; } catch { $('storageNotice').textContent = 'Armazenamento indisponível ou cheio. As alterações desta sessão ficam apenas na memória.'; return false; } },
 remove(key) { try { localStorage.removeItem(key); } catch {} }
};
function toast(text) { $('toast').textContent = text; $('toast').hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(() => $('toast').hidden = true, 3200); }
function errorMessage(err) {
 if (err?.name === 'AbortError') return 'Geração interrompida.';
 const messages = { unauthorized:'Token inválido ou expirado. Conecte novamente.', origin_not_allowed:'Esta origem não está autorizada na API. No VS Code, use o transporte pela extensão.', model_busy:'O modelo está ocupado. Aguarde e tente novamente.', rate_limited:'Limite de solicitações atingido. Aguarde um minuto.', model_missing:'O modelo ainda não está instalado no Ollama.', ollama_unavailable:'O Ollama está indisponível. Tente novamente em instantes.', inference_timeout:'O modelo demorou além do limite. Tente uma pergunta menor.', invalid_messages:'A mensagem excede os limites da API.', network:'Não foi possível acessar a API. Verifique o endereço, a rede e o CORS.', bridge_timeout:'A extensão não respondeu a tempo.', invalid_response:'A API devolveu uma resposta inesperada.' };
 return messages[err?.code] || (err?.status ? 'Não foi possível concluir a solicitação (HTTP ' + err.status + ').' : 'Não foi possível concluir a solicitação. Verifique a conexão.');
}
function normalizeBase(value) {
 const u = new URL(value.trim());
 const loopback = ['localhost','127.0.0.1','[::1]'].includes(u.hostname);
 if (u.username || u.password || u.search || u.hash || !(u.protocol === 'https:' || (u.protocol === 'http:' && loopback))) throw new Error('Use HTTPS ou HTTP em localhost, sem credenciais, parâmetros ou fragmentos na URL.');
 return u.href.replace(/\/+$/, '');
}
function rpc(type, data = {}, signal) {
 return new Promise((resolve, reject) => {
  const id = String(++rpcId);
  const finish = (fn, value) => { clearTimeout(timer); signal?.removeEventListener('abort', abort); pending.delete(id); fn(value); };
  const abort = () => { host.postMessage({ type:'abort', id }); finish(reject, new DOMException('Aborted','AbortError')); };
  const timer = setTimeout(() => { host.postMessage({type:'abort',id}); finish(reject, Object.assign(new Error(), {code:'bridge_timeout'})); }, 290000);
  pending.set(id, { resolve:v => finish(resolve,v), reject:e => finish(reject,e) });
  if (signal?.aborted) return abort();
  signal?.addEventListener('abort', abort, {once:true});
  host.postMessage({ type, id, ...data });
 });
}
window.addEventListener('message', event => {
 const m = event.data;
 if (!isHost || m?.type !== 'hadix:reply' || typeof m.id !== 'string') return;
 const p = pending.get(m.id); if (!p) return;
 if (m.error) p.reject(Object.assign(new Error(), {code:m.error.code, status:m.error.status})); else p.resolve(m.data);
});
async function api(path, options = {}) {
 if (useBridge) return rpc('request', {path, method:options.method || 'GET', body:options.body}, options.signal);
 let response;
 try {
  response = await fetch(credentials.base + path, { method:options.method || 'GET', signal:options.signal, redirect:'error', credentials:'omit', headers:{Authorization:'Bearer ' + credentials.token, ...(options.body ? {'Content-Type':'application/json'} : {})}, ...(options.body ? {body:JSON.stringify(options.body)} : {}) });
 } catch(err) { if(err.name === 'AbortError') throw err; throw Object.assign(new Error(), {code:'network'}); }
 const data = await response.json().catch(() => ({}));
 if (!response.ok) throw Object.assign(new Error(), {status:response.status, code:data.error || data.status});
 return data;
}
function hydrate(value) {
 const list = Array.isArray(value?.conversations) ? value.conversations : [];
 conversations = list.slice(0,50).filter(c => c && typeof c.id === 'string').map(c => ({ id:c.id, title:String(c.title || 'Conversa').slice(0,100), model:String(c.model || '').slice(0,100), created:Number(c.created)||Date.now(), updated:Number(c.updated)||Date.now(), messages:(Array.isArray(c.messages)?c.messages:[]).slice(-200).filter(m=>m && ['user','assistant','system'].includes(m.role) && typeof m.content === 'string').map(m=>({id:typeof m.id==='string'?m.id:uid(),role:m.role,content:m.content.slice(0,32000),state:m.state==='pending'?'stopped':['complete','error','stopped'].includes(m.state)?m.state:'complete',notice:m.state==='pending'?'Interrompida ao fechar a página.':typeof m.notice==='string'?m.notice.slice(0,300):''})) }));
 selected = conversations.some(c=>c.id===value?.selected) ? value.selected : conversations[0]?.id || '';
 if (!selected) newConversation(false);
}
function persist() {
 const data = {version:1, selected, conversations};
 if (isHost) { host.setState?.(data); host.postMessage({type:'persist',data}); }
 else storage.set('hadix.conversations.v1',data);
}
function currentConversation() { return conversations.find(c=>c.id===selected); }
function newConversation(save = true) {
 if (conversations.length >= 50) { toast('Limite de 50 conversas. Reutilize ou limpe uma conversa existente.'); return; }
 const c = {id:uid(),title:'Nova conversa',model:config.model || '',created:Date.now(),updated:Date.now(),messages:[]};
 conversations.unshift(c);selected=c.id;if(save)persist();render();
}
function inlineMarkdown(target, text) {
 const re = /(`[^`\n]+`|\*\*[^*\n]+\*\*|\*[^*\n]+\*)/g;
 let at=0;
 for(const match of text.matchAll(re)) { target.append(document.createTextNode(text.slice(at,match.index))); const s=match[0]; const el=document.createElement(s.startsWith('`')?'code':s.startsWith('**')?'strong':'em'); el.textContent=s.slice(s.startsWith('**')?2:1,s.startsWith('**')?-2:-1);target.append(el);at=match.index+s.length; }
 target.append(document.createTextNode(text.slice(at)));
}
function markdown(text) {
 const root=document.createElement('div');root.className='message-body';
 let code=null,list=null;
 for(const line of text.split('\n')) {
  if(line.trim().startsWith('```')) { if(code){code=null;}else{const pre=document.createElement('pre');code=document.createElement('code');pre.append(code);root.append(pre);}list=null;continue; }
  if(code){code.append(document.createTextNode(line+'\n'));continue;}
  const heading=line.match(/^#{1,3}\s+(.+)$/),bullet=line.match(/^\s*[-*]\s+(.+)$/);
  if(bullet){if(!list){list=document.createElement('ul');root.append(list);}const item=document.createElement('li');inlineMarkdown(item,bullet[1]);list.append(item);continue;}
  list=null;const element=document.createElement(heading?'h3':'p');inlineMarkdown(element,heading?heading[1]:line || ' ');root.append(element);
 }
 return root;
}
async function copyText(text) {
 try { if(isHost)await rpc('copy',{text});else if(navigator.clipboard?.writeText)await navigator.clipboard.writeText(text);else{const field=document.createElement('textarea');field.value=text;document.body.append(field);field.select();const ok=document.execCommand('copy');field.remove();if(!ok)throw new Error();}toast('Resposta copiada.'); }catch{toast('Não foi possível copiar. Selecione o texto para copiar manualmente.');}
}
function render() {
 const c=currentConversation();if(!c)return;
 $('conversationTitle').textContent=c.title;
 $('conversationList').replaceChildren();
 for(const conv of conversations){const button=document.createElement('button');button.type='button';button.className='conversation-button';button.setAttribute('aria-current',String(conv.id===selected));const title=document.createElement('strong'),small=document.createElement('small');title.textContent=conv.title;small.textContent=(conv.messages.length?conv.messages.length+' mensagens':'Novo começo')+(inflight?.conversationId===conv.id?' · gerando…':'');button.append(title,small);button.addEventListener('click',()=>{selected=conv.id;persist();render();$('sidebar').classList.remove('is-open');$('toggleConversations').setAttribute('aria-expanded','false');});$('conversationList').append(button);}
 const box=$('messages');box.replaceChildren();
 if(!c.messages.length){const welcome=document.createElement('div');welcome.className='welcome';welcome.innerHTML='<div class="symbol" aria-hidden="true">✳</div><h2>Sinal vira<br><span class="accent">decisão.</span></h2><p>Uma pergunta abre possibilidades.<br>O que vamos construir hoje?</p><div class="suggestions"><button type="button" data-prompt="Me ajude a transformar uma ideia em um plano de ação.">Organizar uma ideia ↗<span>Do primeiro sinal ao próximo passo.</span></button><button type="button" data-prompt="Me ajude a analisar um problema. Quais informações você precisa?">Explorar possibilidades ↗<span>Encontre contexto e novas direções.</span></button></div>';welcome.querySelectorAll('button').forEach(b=>b.addEventListener('click',()=>{$('chatInput').value=b.dataset.prompt;$('chatInput').focus();}));box.append(welcome);}
 for(const message of c.messages){const article=document.createElement('article');article.className='message '+message.role+(message.state==='error'?' error':'');const header=document.createElement('div');header.className='message-header';const who=document.createElement('span');who.textContent=message.role==='user'?'Você':'✳ Hadix AI';header.append(who);if(message.role==='assistant'&&message.state==='complete'){const copy=document.createElement('button');copy.type='button';copy.textContent='Copiar';copy.setAttribute('aria-label','Copiar resposta');copy.addEventListener('click',()=>copyText(message.content));header.append(copy);}article.append(header);if(message.state==='pending'){const loading=document.createElement('div');loading.className='loading';loading.setAttribute('aria-label','Gerando resposta');loading.innerHTML='<i></i><i></i><i></i>';article.append(loading);}else if(message.content)article.append(markdown(message.content));if(message.notice){const note=document.createElement('p');note.className='message-note';note.textContent=message.notice;article.append(note);}box.append(article);}
 box.scrollTop=box.scrollHeight;
 $('sendBtn').disabled=!!inflight||['model_missing','ollama_unavailable'].includes(lastStatus);
 $('stopBtn').hidden=!inflight;
 $('clearConversation').disabled=inflight?.conversationId===selected;
}
function updateSession() {
 const unavailable=connected&&['model_missing','ollama_unavailable'].includes(lastStatus);
 $('serviceAlert').hidden=!unavailable;
 $('serviceMessage').textContent=lastStatus==='model_missing'?'A API está conectada, mas o modelo '+config.model+' ainda não foi instalado no servidor. Peça ao administrador para instalar o modelo no Ollama.':'O serviço de IA está indisponível. Verifique novamente em instantes.';
 $('sendBtn').disabled=!!inflight||unavailable;
 const state=inflight?'busy':connected?lastStatus:'offline';
 const labels={offline:'Desconectada',checking:'Verificando…',ready:'Pronta',busy:'Ocupada · gerando',model_missing:'Sem modelo',ollama_unavailable:'Ollama indisponível',error:'API indisponível'};
 const text=labels[state]||labels.error;
 $('sessionStatus').textContent=text;$('topStatus').dataset.status=['ready','busy'].includes(state)?state:state==='offline'?'offline':'error';$('topStatus').lastElementChild.textContent=text;
 $('sidebarModel').textContent=config.model||'Conecte seu modelo';$('sessionModel').textContent=config.model||'—';$('sessionBase').textContent=credentials.base||'Não configurado';$('sessionParallel').textContent=connected?String(config.maxParallel||1)+' solicitação por vez':'—';$('latency').textContent=latency===null?'—':(latency/1000).toLocaleString('pt-BR',{maximumFractionDigits:1})+' s';$('logoutBtn').hidden=!connected;$('connectBtn').hidden=connected;
}
async function checkReady() {
 if(!connected||inflight||document.hidden||pollController)return;
 const generation=epoch;pollController=new AbortController();const controller=pollController;const timer=setTimeout(()=>controller.abort(),10000);
 try { const data=await api('/api/ready',{signal:controller.signal});if(generation!==epoch)return;lastStatus=data.status==='ready'?'ready':data.status==='busy'?'busy':'error'; }
 catch(err){if(generation!==epoch||err.name==='AbortError')return;if(err.status===401){expire();return;}lastStatus=['model_missing','ollama_unavailable'].includes(err.code)?err.code:err.code==='model_busy'?'busy':'error';}
 finally{clearTimeout(timer);if(pollController===controller)pollController=null;if(generation===epoch){$('lastChecked').textContent='Verificado às '+new Date().toLocaleTimeString('pt-BR',{hour:'2-digit',minute:'2-digit'});updateSession();}}
}
function stopPolling(){clearInterval(pollTimer);pollController?.abort();pollController=null;}
function activate(info){config=info;connected=true;screen(true);lastStatus='checking';$('loginDialog').close();$('apiToken').value='';$('chatNotice').textContent='Enter envia · Respostas podem conter imprecisões. Revise o que for importante.';stopPolling();checkReady();pollTimer=setInterval(checkReady,30000);updateSession();render();}
function openLogin(){if(!connected)screen(false); $('apiBase').value=credentials.base||'https://api.hadix.site';$('loginError').textContent='';$('apiToken').placeholder=useBridge&&storedHostToken?'Token já guardado na extensão':'Bearer token';if(!$('loginDialog').open)$('loginDialog').showModal(); }
function expire(){connected=false;credentials.token='';storage.remove('hadix.chat');tabConnection(null);stopPolling();if(!isHost)openLogin();$('chatNotice').textContent='A sessão expirou. Conecte novamente.';updateSession();}
async function login(){
 $('loginError').textContent='';let base;try{base=normalizeBase($('apiBase').value);}catch(err){$('loginError').textContent=err.message;return;}
 const token=$('apiToken').value.trim();if(!token && !(useBridge&&storedHostToken&&base===credentials.base)){$('loginError').textContent='Informe o token de acesso.';return;}
 $('loginBtn').disabled=true;
 const previous={...credentials};const generation=++epoch;stopPolling();
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),15000);
 try {
  let info;
  if(useBridge){const result=await rpc('connect',{base,token},controller.signal);info=result.config;storedHostToken=true;credentials={base,token:''};}
  else{credentials={base,token};info=await api('/api/config',{signal:controller.signal});if(isHost)await rpc('connect',{base,token},controller.signal);}
  if(generation!==epoch)return;
  if(typeof info.model!=='string')throw Object.assign(new Error(),{code:'invalid_response'});
  tokenForRedaction=token;
  if(!isHost){tabConnection({base,token});if($('rememberToken').checked)storage.set('hadix.chat',{base,token});else storage.remove('hadix.chat');}
  activate(info);
 }catch(err){if(generation===epoch){credentials=previous;$('loginError').textContent=errorMessage(err);if(connected){pollTimer=setInterval(checkReady,30000);checkReady();}}}
 finally{clearTimeout(timer);$('loginBtn').disabled=false;}
}
async function send(text) {
 text=String(text||'').trim();if(!text||inflight)return;
 if(!connected){openLogin();return;}
 if(['model_missing','ollama_unavailable'].includes(lastStatus)){updateSession();return;}
 if(text.length>8000){toast('A mensagem pode ter até 8.000 caracteres.');return;}
 const conversation=currentConversation();
 if(conversation.messages.length>=198){toast('Esta conversa atingiu 200 mensagens. Crie uma nova conversa para continuar.');return;}
 const user={id:uid(),role:'user',content:text,state:'complete'};
 const recent=conversation.messages.filter(m=>m.state==='complete').map(({role,content})=>({role,content:content.slice(-8000)}));recent.push({role:'user',content:text});
 // Keep displayed history intact while fitting the server context contract.
 while(recent.length>24 || recent.reduce((n,m)=>n+m.content.length,0)>16000)recent.shift();
 const assistant={id:uid(),role:'assistant',content:'',state:'pending',notice:''};
 if(!conversation.messages.length)conversation.title=text.slice(0,48);
 conversation.model=config.model;conversation.messages.push(user,assistant);conversation.updated=Date.now();
 const controller=new AbortController(),generation=epoch;
 const request={conversationId:conversation.id,controller,stopped:false};inflight=request;
 pollController?.abort();pollController=null;
 $('chatInput').value='';$('chatNotice').textContent='Enviando '+recent.length+' mensagens de contexto. Você pode parar a geração.';
 persist();render();updateSession();const started=performance.now();let timedOut=false;
 const timeout=setTimeout(()=>{timedOut=true;controller.abort();},270000);
 try {
  const data=await api('/api/chat',{method:'POST',body:{messages:recent},signal:controller.signal});
  if(controller.signal.aborted)throw new DOMException('Aborted','AbortError');
  if(typeof data.message?.content!=='string')throw Object.assign(new Error(),{code:'invalid_response'});
  assistant.content=data.message.content;assistant.state='complete';if(generation===epoch){latency=performance.now()-started;lastStatus='ready';}
 }catch(err){
  if(err.name==='AbortError'&&!timedOut){assistant.state='stopped';assistant.notice='Geração interrompida.';}
  else{assistant.state='error';assistant.notice=timedOut?'A resposta demorou além do limite. Tente uma pergunta menor.':errorMessage(err);if(generation===epoch){if(err.status===401)expire();else if(['model_busy','rate_limited'].includes(err.code))lastStatus='busy';else lastStatus=['model_missing','ollama_unavailable'].includes(err.code)?err.code:'error';}}
 }finally{
  clearTimeout(timeout);if(inflight===request)inflight=null;
  persist();render();updateSession();
  if(generation===epoch){$('chatNotice').textContent=assistant.state==='stopped'?'Geração interrompida. Você pode continuar a conversa.':assistant.state==='error'?assistant.notice:'Contexto enviado: '+recent.length+' mensagens · Histórico salvo neste dispositivo.';if(selected===conversation.id)$('chatInput').focus();}
 }
}
$('chatForm').addEventListener('submit', event=>{event.preventDefault();void send($('chatInput').value);});
$('chatInput').addEventListener('keydown', event=>{if(event.key==='Enter'&&!event.shiftKey&&!event.isComposing&&event.keyCode!==229){event.preventDefault();void send(event.currentTarget.value);}});
$('stopBtn').addEventListener('click',()=>inflight?.controller.abort());
$('loginForm').addEventListener('submit',event=>{event.preventDefault();void login();});
for(const id of ['connectBtn','settingsBtn'])$(id).addEventListener('click',openLogin);
$('cancelLogin').addEventListener('click',()=>{$('loginDialog').close();$('apiToken').value='';});
$('loginDialog').addEventListener('close',()=>{$('apiToken').value='';});
$('newConversation').addEventListener('click',()=>newConversation());
$('refreshStatus').addEventListener('click',checkReady);
$('toggleConversations').addEventListener('click',()=>{const open=$('sidebar').classList.toggle('is-open');$('toggleConversations').setAttribute('aria-expanded',String(open));});
$('clearConversation').addEventListener('click',()=>{clearTarget=selected;$('clearDialog').showModal();});
$('cancelClear').addEventListener('click',()=>$('clearDialog').close());
$('confirmClear').addEventListener('click',()=>{const c=conversations.find(c=>c.id===clearTarget);if(c&&inflight?.conversationId!==c.id){c.messages=[];c.title='Nova conversa';persist();render();}$('clearDialog').close();});
$('logoutBtn').addEventListener('click',async()=>{++epoch;connected=false;stopPolling();inflight?.controller.abort();credentials.token='';storedHostToken=false;storage.remove('hadix.chat');tabConnection(null);$('apiToken').value='';if(isHost)try{await rpc('logout');}catch{}config={model:'',maxParallel:1};lastStatus='offline';updateSession();$('chatNotice').textContent='Sessão encerrada. O histórico permanece neste dispositivo.';if(!isHost)openLogin();});
document.addEventListener('visibilitychange',()=>{if(!document.hidden)checkReady();});
window.addEventListener('pagehide',()=>{stopPolling();inflight?.controller.abort();});
// Draw export data, never the DOM or connection form. No foreignObject or remote fonts.
function exportPages(scope) {
 const measure=document.createElement('canvas').getContext('2d');
 const pages=[];let page,y;
 const width=scope==='dashboard'?1280:1000,left=scope==='dashboard'?255:44,right=width-44;
 const redact=text=>tokenForRedaction?String(text).split(tokenForRedaction).join('[token oculto]'):String(text);
 const text=(x,y,value,size=14,color='#e7ebee',weight=400)=>page.push({type:'text',x,y,text:redact(value),size,color,weight});
 const rect=(x,y,w,h,color)=>page.push({type:'rect',x,y,w,h,color});
 function fresh(){page=[];pages.push(page);rect(0,0,width,1800,'#08090a');for(let x=0;x<width;x+=48)rect(x,0,1,1800,'#12171a');for(let j=0;j<1800;j+=48)rect(0,j,width,1,'#12171a');rect(0,0,width,94,'#0b0d0f');text(36,52,'✳ hadix.ai',27,'#d6ecc1',600);text(245,51,'INTELLIGENCE WORKSPACE',11,'#9ca6af');text(width-165,51,'PÁGINA '+pages.length,11,'#9ca6af');y=130;if(scope==='dashboard'){rect(22,115,205,1590,'#12151a');text(40,147,'CONVERSAS',12,'#d6ecc1');let sy=183;for(const c of conversations.slice(0,18)){text(40,sy,c.title.slice(0,23),12,c.id===selected?'#d6ecc1':'#a6afb7');sy+=36;}text(40,1660,'CONTEXTO LOCAL',10,'#9ca6af');}}
 function lines(value,maxWidth,size){measure.font=`${size}px system-ui`;const output=[];for(const paragraph of redact(value).split('\n')){if(!paragraph){output.push('');continue;}let line='';for(const word of paragraph.split(/(\s+)/)){if(measure.measureText(line+word).width<=maxWidth){line+=word;continue;}if(line.trim()){output.push(line.trimEnd());line='';}if(measure.measureText(word).width>maxWidth){for(const char of word){if(measure.measureText(line+char).width>maxWidth){output.push(line);line='';}line+=char;}}else line=word.trimStart();}output.push(line);}return output;}
 function paragraph(value,{size=15,color='#e7ebee',weight=400,gap=12}={}){const wrapped=lines(value,right-left-32,size);for(const line of wrapped){if(y+size*1.65>1700)fresh();text(left+16,y,line,size,color,weight);y+=size*1.65;}y+=gap;}
 fresh();paragraph(scope==='session'?'Resumo da sessão':currentConversation().title,{size:26,color:'#d6ecc1',weight:600});
 paragraph('Modelo: '+(config.model||currentConversation().model||'Não conectado')+'  |  '+$('sessionStatus').textContent,{size:12,color:'#9ca6af'});
 if(scope==='session'||scope==='dashboard'){
  for(const [key,value] of [['Endpoint',credentials.base],['Latência',$('latency').textContent],['Concorrência',$('sessionParallel').textContent],['Conversa',currentConversation().title],['Mensagens',String(currentConversation().messages.length)],['Acesso','Token não incluído nesta imagem']])paragraph(key+': '+value,{size:13,color:'#c2ccd1',gap:6});y+=15;
 }
 if(scope!=='session'){
  const messages=currentConversation().messages;
  if(!messages.length)paragraph('Sinal vira decisão. Uma nova conversa começa aqui.',{color:'#9ca6af'});
  for(const m of messages){if(y>1590)fresh();rect(left,y-17,right-left,2,m.role==='user'?'#b9d99a':'#85ddf4');y+=12;paragraph(m.role==='user'?'VOCÊ':'HADIX AI',{size:11,color:m.role==='user'?'#d6ecc1':'#85ddf4',weight:600,gap:6});paragraph(m.state==='pending'?'Gerando resposta…':m.content||m.notice||'',{gap:25});}
 }
 const date=new Date().toLocaleString('pt-BR');
 pages.forEach((p,i)=>{page=p;text(36,1760,'Hadix AI · '+date+' · '+(i+1)+'/'+pages.length,11,'#9ca6af');});
 return {width,height:1800,pages};
}
function escapeXML(value){return String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&apos;'}[c]));}
async function encodePage(commands,width,height,format){
 if(format==='svg'){
  const shapes=commands.map(c=>c.type==='rect'?`<rect x="${c.x}" y="${c.y}" width="${c.w}" height="${c.h}" fill="${c.color}"/>`:`<text x="${c.x}" y="${c.y}" font-family="system-ui, sans-serif" font-size="${c.size}" font-weight="${c.weight}" fill="${c.color}" xml:space="preserve">${escapeXML(c.text)}</text>`).join('');
  return new Blob([`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">${shapes}</svg>`],{type:'image/svg+xml'});
 }
 const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;const ctx=canvas.getContext('2d');
 for(const c of commands){ctx.fillStyle=c.color;if(c.type==='rect')ctx.fillRect(c.x,c.y,c.w,c.h);else{ctx.font=`${c.weight} ${c.size}px system-ui`;ctx.fillText(c.text,c.x,c.y);}}
 return new Promise((resolve,reject)=>canvas.toBlob(blob=>blob?resolve(blob):reject(new Error('export')),'image/png'));
}
function crc32(bytes){let crc=0xffffffff;for(const b of bytes){crc^=b;for(let i=0;i<8;i++)crc=(crc>>>1)^((crc&1)?0xedb88320:0);}return (crc^0xffffffff)>>>0;}
async function zipFiles(files){
 const parts=[],central=[];let offset=0,centralSize=0;
 for(const file of files){const name=new TextEncoder().encode(file.name),bytes=new Uint8Array(await file.blob.arrayBuffer()),crc=crc32(bytes);const header=new Uint8Array(30+name.length),h=new DataView(header.buffer);h.setUint32(0,0x04034b50,true);h.setUint16(4,20,true);h.setUint16(6,0x800,true);h.setUint32(14,crc,true);h.setUint32(18,bytes.length,true);h.setUint32(22,bytes.length,true);h.setUint16(26,name.length,true);header.set(name,30);parts.push(header,bytes);const entry=new Uint8Array(46+name.length),e=new DataView(entry.buffer);e.setUint32(0,0x02014b50,true);e.setUint16(4,20,true);e.setUint16(6,20,true);e.setUint16(8,0x800,true);e.setUint32(16,crc,true);e.setUint32(20,bytes.length,true);e.setUint32(24,bytes.length,true);e.setUint16(28,name.length,true);e.setUint32(42,offset,true);entry.set(name,46);central.push(entry);centralSize+=entry.length;offset+=header.length+bytes.length;}
 const end=new Uint8Array(22),e=new DataView(end.buffer);e.setUint32(0,0x06054b50,true);e.setUint16(8,files.length,true);e.setUint16(10,files.length,true);e.setUint32(12,centralSize,true);e.setUint32(16,offset,true);return new Blob([...parts,...central,end],{type:'application/zip'});
}
function base64(bytes){let result='';for(let i=0;i<bytes.length;i+=16384)result+=String.fromCharCode(...bytes.subarray(i,i+16384));return btoa(result);}
async function exportImage(){
 $('exportBtn').disabled=true;$('exportNotice').textContent='Preparando imagem…';
 try {
  const format=$('exportFormat').value,scope=$('exportScope').value;
  const {pages,width,height}=exportPages(scope);
  const prefix='hadix-'+new Date().toISOString().replace(/[:.]/g,'-')+'-'+(config.model||'offline').replace(/[^a-zA-Z0-9_-]/g,'-').slice(0,45)+'-'+scope;
  const files=[];
  for(let i=0;i<pages.length;i++){files.push({name:prefix+(pages.length>1?'-'+String(i+1).padStart(3,'0'):'')+'.'+format,blob:await encodePage(pages[i],width,height,format)});}
  const file=files.length===1?files[0]:{name:prefix+'.zip',blob:await zipFiles(files)};
  if(file.blob.size>24*1024*1024)throw new Error('too_large');
  if(isHost){const result=await rpc('saveExport',{name:file.name,mime:file.blob.type,base64:base64(new Uint8Array(await file.blob.arrayBuffer()))});$('exportNotice').textContent=result.saved?'Imagem salva.':'Exportação cancelada.';}
  else{const url=URL.createObjectURL(file.blob),link=document.createElement('a');link.href=url;link.download=file.name;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),30000);$('exportNotice').textContent=files.length===1?'Imagem exportada.':files.length+' páginas exportadas em um ZIP.';}
 }catch{$('exportNotice').textContent='Não foi possível exportar. Tente um bloco menor ou o formato SVG.';}
 finally{$('exportBtn').disabled=false;}
}
$('exportBtn').addEventListener('click',exportImage);
async function boot(){
 let saved,autoconnect=false;
 if(isHost){
  $('environmentBadge').textContent='VS CODE';$('rememberRow').hidden=true;$('credentialNote').textContent='O token é guardado no armazenamento seguro da extensão.';$('transportNote').textContent=useBridge?'Conexão pelo host do VS Code.':'Conexão direta da Webview (requer CORS).';
  try { const data=await rpc('bootstrap');credentials={base:data.base||credentials.base,token:useBridge?'':data.token||''};storedHostToken=!!data.hasToken;saved=data.state||host.getState?.();autoconnect=useBridge?storedHostToken:!!credentials.token;tokenForRedaction=credentials.token; }
  catch{$('storageNotice').textContent='A ponte da extensão não respondeu. Reabra o dashboard no VS Code.';saved=host.getState?.();}
 }else{
  saved=storage.get('hadix.conversations.v1');let previous=storage.get('hadix.chat');const remembered=!!previous;try{previous=previous||JSON.parse(sessionStorage.getItem('hadix.session')||'null');}catch{}
  if(previous?.base&&previous?.token){try{credentials={base:normalizeBase(previous.base),token:String(previous.token)};tokenForRedaction=credentials.token;autoconnect=true;$('rememberToken').checked=remembered;}catch{storage.remove('hadix.chat');}}
 }
 hydrate(saved);initialized=true;render();updateSession();
 if(autoconnect){const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),15000);try{const info=await api('/api/config',{signal:controller.signal});if(typeof info.model!=='string')throw Object.assign(new Error(),{code:'invalid_response'});activate(info);}catch(err){if(err.status===401)expire();$('chatNotice').textContent=errorMessage(err);}finally{clearTimeout(timer);}}
 if(!connected&&!isHost)openLogin();
}
void boot();
})();
</script>
</body>
</html>
HX_CHAT
  # HADIX_DASHBOARD_ROUTES
  mkdir -p "$BACKEND_DIR/site/login" "$BACKEND_DIR/site/app"
  cp "$BACKEND_DIR/site/chat.html" "$BACKEND_DIR/site/login/index.html"
  cp "$BACKEND_DIR/site/chat.html" "$BACKEND_DIR/site/app/index.html"
  cp "$BACKEND_DIR/site/chat.html" "$BACKEND_DIR/site/dashboard.html"

  mkdir -p "$BACKEND_DIR/site/assets/js"
  cat > "$BACKEND_DIR/site/assets/js/planet3d.js" <<'HX_JS_PLANET'
// Local, procedural WebGL planet. No textures, fetch or module imports: file:// safe.
window.createPortalPlanet = function () {
  if (!window.THREE) return null;
  const T = window.THREE, main = document.getElementById('main'), anchor = document.querySelector('.globe-stage');
  const canvas = document.createElement('canvas');canvas.className='planet-canvas';canvas.setAttribute('aria-hidden','true');
  let renderer;
  try { renderer = new T.WebGLRenderer({canvas,alpha:true,antialias:true,powerPreference:'low-power'}); } catch { return null; }
  main.append(canvas);
  renderer.setPixelRatio(Math.min(devicePixelRatio,1.6));renderer.setClearColor(0x080909,0);
  const scene = new T.Scene(), camera = new T.PerspectiveCamera(38,1,.03,60);
  const root = new T.Group(), globe = new T.Group();root.add(globe);scene.add(root);
  const sphere = new T.Mesh(new T.SphereGeometry(1,64,48),new T.MeshPhongMaterial({color:0x101c19,emissive:0x020806,shininess:35,transparent:true,opacity:.97}));globe.add(sphere);
  scene.add(new T.AmbientLight(0x7baca0,.9));
  const key=new T.DirectionalLight(0xb6e6a1,2.2);key.position.set(-3,3,4);scene.add(key);
  const rim=new T.DirectionalLight(0x65bad4,1.6);rim.position.set(3,-1,-2);scene.add(rim);
  const gridMat=new T.LineBasicMaterial({color:0x8fb498,transparent:true,opacity:.32});
  const v=(lat,lon,r=1.008)=>{const a=lat*Math.PI/180,b=lon*Math.PI/180;return new T.Vector3(r*Math.cos(a)*Math.sin(b),r*Math.sin(a),r*Math.cos(a)*Math.cos(b));};
  function line(points,material,parent=globe){const line=new T.Line(new T.BufferGeometry().setFromPoints(points),material);parent.add(line);return line;}
  for(let lat=-75;lat<=75;lat+=15){const points=[];for(let lon=0;lon<=360;lon+=3)points.push(v(lat,lon));line(points,gridMat);}
  for(let lon=0;lon<360;lon+=20){const points=[];for(let lat=-90;lat<=90;lat+=3)points.push(v(lat,lon));line(points,gridMat);}
  const continents=[[[37,-8],[32,12],[31,33],[12,44],[8,50],[-12,40],[-34,19],[-25,14],[4,8],[8,-15],[24,-17],[37,-8]],[[36,-9],[44,-9],[49,1],[56,8],[70,25],[65,35],[55,30],[50,55],[42,40],[37,24],[44,14],[42,3],[36,-9]],[[12,-81],[9,-65],[0,-50],[-5,-35],[-22,-42],[-35,-57],[-54,-68],[-44,-74],[-18,-70],[-5,-81],[12,-81]],[[70,-150],[59,-135],[49,-125],[30,-115],[18,-100],[22,-87],[30,-81],[44,-66],[52,-55],[60,-67],[68,-90],[70,-150]],[[70,30],[73,95],[62,140],[45,140],[25,120],[7,105],[22,90],[8,78],[26,62],[35,40]], [[-12,115],[-11,138],[-20,151],[-38,146],[-34,116],[-12,115]]];
  const landMat=new T.LineBasicMaterial({color:0xbacbb2,transparent:true,opacity:.7});
  continents.forEach(poly=>line(poly.map(([a,b])=>v(a,b,1.014)),landMat));
  const hubs=[[51,0],[40,-74],[-23,-46],[30,31],[6,3],[48,17],[15,-17],[-1,37],[35,110]];
  const hubMat=new T.MeshBasicMaterial({color:0xd3f56b}), dotGeometry=new T.SphereGeometry(.015,8,8);
  hubs.forEach(([a,b])=>{const dot=new T.Mesh(dotGeometry,hubMat);dot.position.copy(v(a,b,1.03));globe.add(dot);});
  const routeMat=new T.LineBasicMaterial({color:0xd3f56b,transparent:true,opacity:.55});
  [[0,1],[0,3],[0,5],[1,2],[2,4],[4,6],[3,7],[5,8]].forEach(([a,b])=>{const points=[],p=v(...hubs[a]),q=v(...hubs[b]);for(let i=0;i<=48;i++){const t=i/48;points.push(p.clone().lerp(q,t).normalize().multiplyScalar(1.025+Math.sin(t*Math.PI)*.17));}line(points,routeMat);});
  const atmosphere=new T.Mesh(new T.SphereGeometry(1.035,48,32),new T.ShaderMaterial({transparent:true,depthWrite:false,blending:T.AdditiveBlending,uniforms:{},vertexShader:'varying vec3 n;varying vec3 e;void main(){vec4 p=modelViewMatrix*vec4(position,1.);n=normalize(normalMatrix*normal);e=normalize(-p.xyz);gl_Position=projectionMatrix*p;}',fragmentShader:'varying vec3 n;varying vec3 e;void main(){float rim=pow(1.-max(dot(normalize(n),normalize(e)),0.),3.);gl_FragColor=vec4(.32,.72,.58,rim*.45);}'}));globe.add(atmosphere);
  const rings=new T.Group();root.add(rings);
  [1.3,1.5].forEach((r,i)=>{const points=[];for(let j=0;j<=128;j++){const a=j/128*Math.PI*2;points.push(new T.Vector3(Math.cos(a)*r,Math.sin(a)*r,0));}const ring=line(points,new T.LineBasicMaterial({color:i?0x8ea985:0xbee69b,transparent:true,opacity:.22}),rings);ring.rotation.set(.9+i*.6,.4,i*.7);});
  const portal=new T.Mesh(new T.TorusGeometry(1.035,.009,8,128),new T.MeshBasicMaterial({color:0xbcebb0,transparent:true,opacity:0,blending:T.AdditiveBlending,depthTest:false}));root.add(portal);
  const state={progress:0};let enabled=false,failed=false,frame=0,time=0,last=0,home={x:0,y:0,scale:1},reduced=matchMedia('(prefers-reduced-motion: reduce)');
  function resize(){const r=main.getBoundingClientRect(),a=anchor.getBoundingClientRect();renderer.setSize(r.width,r.height,false);camera.aspect=r.width/r.height;camera.updateProjectionMatrix();const height=2*Math.tan(19*Math.PI/180)*5.8;home={x:((a.left+a.width/2-r.left)/r.width-.5)*height*camera.aspect,y:(.5-(a.top+a.height/2-r.top)/r.height)*height,scale:a.width*.39/r.height*height};draw();}
  function draw(){if(failed)return;const p=state.progress,center=T.MathUtils.smoothstep(p,0,.58);root.position.set(home.x*(1-center),home.y*(1-center),0);root.scale.setScalar(home.scale);camera.position.set(0,0,5.8+(home.scale*.25-5.8)*p);globe.rotation.set(.15,time*.065-.4,-.15);rings.rotation.z=time*.025;portal.material.opacity=Math.sin(p*Math.PI)*.8;portal.scale.setScalar(1+p*.15);renderer.render(scene,camera);}
  function tick(now){frame=0;if(!enabled||document.hidden||failed)return;const dt=Math.min((now-last)/1000||0,.04);last=now;if(!reduced.matches)time+=dt;draw();if(!reduced.matches)frame=requestAnimationFrame(tick);}
  function setEnabled(value){enabled=value&&!failed;canvas.style.visibility=enabled?'visible':'hidden';if(frame)cancelAnimationFrame(frame);frame=0;if(enabled){last=performance.now();draw();if(!reduced.matches)frame=requestAnimationFrame(tick);}}
  canvas.addEventListener('webglcontextlost',event=>{event.preventDefault();failed=true;setEnabled(false);document.body.classList.remove('planet-ready');});
  const observer=new ResizeObserver(resize);observer.observe(main);observer.observe(anchor);
  document.getElementById('hero').addEventListener('scroll',resize,{passive:true});
  document.addEventListener('visibilitychange',()=>setEnabled(enabled));reduced.addEventListener('change',()=>setEnabled(enabled));
  resize();document.body.classList.add('planet-ready');
  return {canvas,state,draw,resize,setEnabled,get ready(){return !failed;}};
};
HX_JS_PLANET

  mkdir -p "$BACKEND_DIR/site/assets/img"
  cat > "$BACKEND_DIR/site/assets/img/network.svg" <<'HX_SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 640"><defs><radialGradient id="g"><stop stop-color="#22281d" stop-opacity=".5"/><stop offset="1" stop-color="#080909" stop-opacity="0"/></radialGradient></defs><circle cx="320" cy="320" r="280" fill="url(#g)"/><g fill="none" stroke="#9eaa8e" stroke-width=".7"><circle cx="320" cy="320" r="222" opacity=".6"/><path d="M351.88,532.96 L350.06,533.41 L348.27,533.84 L346.51,534.28 L344.77,534.70 L343.07,535.12 L341.40,535.53 L339.76,535.93 L338.17,536.32 L336.61,536.70 L335.10,537.07 L333.63,537.43 L332.20,537.78 L330.82,538.11 L329.50,538.44 L328.22,538.75 L326.99,539.05 L325.82,539.34 L324.70,539.61 L323.64,539.87 L322.64,540.12 L321.69,540.35 L320.81,540.56 L319.99,540.77 L319.22,540.95 L318.53,541.12 L317.89,541.28 L317.32,541.42 L316.82,541.54 L316.38,541.65 L316.01,541.74 L315.70,541.81 L315.47,541.87 L315.30,541.91 L315.19,541.94" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M426.75,514.64 L426.65,514.66 L426.48,514.71 L426.24,514.76 L425.93,514.84 L425.56,514.93 L425.13,515.04 L424.62,515.16 L424.05,515.30 L423.42,515.46 L422.72,515.63 L421.96,515.81 L421.13,516.01 L420.25,516.23 L419.31,516.46 L418.30,516.71 L417.24,516.97 L416.12,517.24 L414.95,517.53 L413.73,517.83 L412.45,518.14 L411.12,518.46 L409.74,518.80 L408.32,519.15 L406.85,519.51 L405.33,519.88 L403.78,520.26 L402.18,520.65 L400.55,521.05 L398.88,521.46 L397.17,521.88 L395.44,522.30 L393.67,522.73 L391.88,523.17 L390.06,523.62 L388.22,524.07 L386.36,524.52 L384.47,524.99 L382.58,525.45 L380.66,525.92 L378.74,526.39 L376.81,526.86 L374.87,527.34 L372.92,527.81 L370.97,528.29 L369.02,528.77 L367.08,529.24 L365.14,529.72 L363.20,530.19 L361.28,530.66 L359.37,531.13 L357.47,531.59 L355.59,532.05 L353.73,532.51 L351.88,532.96" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M315.16,541.95 L315.19,541.94 L315.30,541.91 L315.47,541.87 L315.70,541.81 L316.01,541.74 L316.38,541.65 L316.82,541.54 L317.32,541.42 L317.89,541.28 L318.53,541.12 L319.22,540.95 L319.99,540.77 L320.81,540.56 L321.69,540.35 L322.64,540.12 L323.64,539.87 L324.70,539.61 L325.82,539.34 L326.99,539.05 L328.22,538.75 L329.50,538.44 L330.82,538.11 L332.20,537.78 L333.63,537.43 L335.10,537.07 L336.61,536.70 L338.17,536.32 L339.76,535.93 L341.40,535.53 L343.07,535.12 L344.77,534.70 L346.51,534.28 L348.27,533.84 L350.06,533.41 L351.88,532.96 L353.73,532.51 L355.59,532.05 L357.47,531.59 L359.37,531.13 L361.28,530.66 L363.20,530.19 L365.14,529.72 L367.08,529.24 L369.02,528.77 L370.97,528.29 L372.92,527.81 L374.87,527.34 L376.81,526.86 L378.74,526.39 L380.66,525.92 L382.58,525.45 L384.47,524.99 L386.36,524.52 L388.22,524.07 L390.06,523.62 L391.88,523.17 L393.67,522.73 L395.44,522.30 L397.17,521.88 L398.88,521.46 L400.55,521.05 L402.18,520.65 L403.78,520.26 L405.33,519.88 L406.85,519.51 L408.32,519.15 L409.74,518.80 L411.12,518.46 L412.45,518.14 L413.73,517.83 L414.95,517.53 L416.12,517.24 L417.24,516.97 L418.30,516.71 L419.31,516.46 L420.25,516.23 L421.13,516.01 L421.96,515.81 L422.72,515.63 L423.42,515.46 L424.05,515.30 L424.62,515.16 L425.13,515.04 L425.56,514.93 L425.93,514.84 L426.24,514.76 L426.48,514.71 L426.65,514.66 L426.75,514.64 L426.78,514.63" fill="none" stroke="#acb49f" stroke-opacity="0.36" stroke-width="0.7"/><path d="M328.82,515.77 L325.31,516.63 L321.85,517.48 L318.44,518.31 L315.08,519.13 L311.79,519.94 L308.57,520.73 L305.41,521.50 L302.33,522.26 L299.32,522.99 L296.40,523.71 L293.56,524.40 L290.80,525.08 L288.14,525.73 L285.58,526.36 L283.11,526.96 L280.74,527.54 L278.47,528.09 L276.31,528.62 L274.26,529.12 L272.33,529.60 L270.50,530.04 L268.79,530.46 L267.20,530.85 L265.73,531.21 L264.38,531.54 L263.16,531.84 L262.06,532.11 L261.08,532.35 L260.24,532.56 L259.52,532.73 L258.93,532.88 L258.47,532.99 L258.14,533.07 L257.95,533.12" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M473.45,480.38 L473.26,480.43 L472.93,480.51 L472.47,480.62 L471.88,480.76 L471.16,480.94 L470.32,481.15 L469.34,481.38 L468.24,481.65 L467.02,481.95 L465.67,482.28 L464.20,482.64 L462.61,483.03 L460.90,483.45 L459.07,483.90 L457.14,484.37 L455.09,484.87 L452.93,485.40 L450.66,485.96 L448.29,486.54 L445.82,487.14 L443.26,487.77 L440.60,488.42 L437.84,489.09 L435.00,489.79 L432.08,490.50 L429.07,491.24 L425.99,491.99 L422.84,492.77 L419.61,493.55 L416.32,494.36 L412.96,495.18 L409.55,496.02 L406.09,496.86 L402.58,497.72 L399.02,498.59 L395.42,499.47 L391.78,500.36 L388.12,501.26 L384.42,502.17 L380.71,503.08 L376.97,503.99 L373.22,504.91 L369.46,505.83 L365.70,506.75 L361.94,507.67 L358.18,508.59 L354.43,509.51 L350.69,510.42 L346.98,511.33 L343.28,512.23 L339.62,513.13 L335.98,514.02 L332.38,514.90 L328.82,515.77" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M257.88,533.13 L257.95,533.12 L258.14,533.07 L258.47,532.99 L258.93,532.88 L259.52,532.73 L260.24,532.56 L261.08,532.35 L262.06,532.11 L263.16,531.84 L264.38,531.54 L265.73,531.21 L267.20,530.85 L268.79,530.46 L270.50,530.04 L272.33,529.60 L274.26,529.12 L276.31,528.62 L278.47,528.09 L280.74,527.54 L283.11,526.96 L285.58,526.36 L288.14,525.73 L290.80,525.08 L293.56,524.40 L296.40,523.71 L299.32,522.99 L302.33,522.26 L305.41,521.50 L308.57,520.73 L311.79,519.94 L315.08,519.13 L318.44,518.31 L321.85,517.48 L325.31,516.63 L328.82,515.77 L332.38,514.90 L335.98,514.02 L339.62,513.13 L343.28,512.23 L346.98,511.33 L350.69,510.42 L354.43,509.51 L358.18,508.59 L361.94,507.67 L365.70,506.75 L369.46,505.83 L373.22,504.91 L376.97,503.99 L380.71,503.08 L384.42,502.17 L388.12,501.26 L391.78,500.36 L395.42,499.47 L399.02,498.59 L402.58,497.72 L406.09,496.86 L409.55,496.02 L412.96,495.18 L416.32,494.36 L419.61,493.55 L422.84,492.77 L425.99,491.99 L429.07,491.24 L432.08,490.50 L435.00,489.79 L437.84,489.09 L440.60,488.42 L443.26,487.77 L445.82,487.14 L448.29,486.54 L450.66,485.96 L452.93,485.40 L455.09,484.87 L457.14,484.37 L459.07,483.90 L460.90,483.45 L462.61,483.03 L464.20,482.64 L465.67,482.28 L467.02,481.95 L468.24,481.65 L469.34,481.38 L470.32,481.15 L471.16,480.94 L471.88,480.76 L472.47,480.62 L472.93,480.51 L473.26,480.43 L473.45,480.38 L473.52,480.36" fill="none" stroke="#acb49f" stroke-opacity="0.36" stroke-width="0.7"/><path d="M305.16,485.24 L300.19,486.46 L295.30,487.66 L290.47,488.84 L285.73,490.00 L281.07,491.14 L276.51,492.25 L272.05,493.34 L267.69,494.41 L263.44,495.45 L259.30,496.46 L255.29,497.45 L251.39,498.40 L247.63,499.32 L244.00,500.21 L240.51,501.06 L237.16,501.88 L233.96,502.67 L230.90,503.41 L228.00,504.12 L225.26,504.79 L222.68,505.42 L220.27,506.02 L218.02,506.57 L215.94,507.08 L214.03,507.54 L212.30,507.97 L210.74,508.35 L209.36,508.68 L208.17,508.98 L207.15,509.23 L206.32,509.43 L205.67,509.59 L205.21,509.70 L204.93,509.77" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M509.70,435.19 L509.42,435.26 L508.96,435.37 L508.31,435.53 L507.48,435.73 L506.46,435.98 L505.26,436.27 L503.89,436.61 L502.33,436.99 L500.60,437.41 L498.69,437.88 L496.61,438.39 L494.36,438.94 L491.94,439.53 L489.36,440.16 L486.62,440.83 L483.72,441.54 L480.67,442.29 L477.47,443.07 L474.12,443.89 L470.63,444.75 L467.00,445.64 L463.23,446.56 L459.34,447.51 L455.33,448.49 L451.19,449.51 L446.94,450.55 L442.58,451.61 L438.12,452.70 L433.55,453.82 L428.90,454.96 L424.16,456.12 L419.33,457.30 L414.43,458.50 L409.46,459.72 L404.43,460.95 L399.34,462.19 L394.20,463.45 L389.02,464.72 L383.79,466.00 L378.53,467.29 L373.25,468.58 L367.95,469.88 L362.64,471.18 L357.31,472.48 L351.99,473.78 L346.68,475.08 L341.38,476.38 L336.09,477.67 L330.84,478.96 L325.61,480.24 L320.43,481.51 L315.29,482.76 L310.20,484.01 L305.16,485.24" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M204.84,509.79 L204.93,509.77 L205.21,509.70 L205.67,509.59 L206.32,509.43 L207.15,509.23 L208.17,508.98 L209.36,508.68 L210.74,508.35 L212.30,507.97 L214.03,507.54 L215.94,507.08 L218.02,506.57 L220.27,506.02 L222.68,505.42 L225.26,504.79 L228.00,504.12 L230.90,503.41 L233.96,502.67 L237.16,501.88 L240.51,501.06 L244.00,500.21 L247.63,499.32 L251.39,498.40 L255.29,497.45 L259.30,496.46 L263.44,495.45 L267.69,494.41 L272.05,493.34 L276.51,492.25 L281.07,491.14 L285.73,490.00 L290.47,488.84 L295.30,487.66 L300.19,486.46 L305.16,485.24 L310.20,484.01 L315.29,482.76 L320.43,481.51 L325.61,480.24 L330.84,478.96 L336.09,477.67 L341.38,476.38 L346.68,475.08 L351.99,473.78 L357.31,472.48 L362.64,471.18 L367.95,469.88 L373.25,468.58 L378.53,467.29 L383.79,466.00 L389.02,464.72 L394.20,463.45 L399.34,462.19 L404.43,460.95 L409.46,459.72 L414.43,458.50 L419.33,457.30 L424.16,456.12 L428.90,454.96 L433.55,453.82 L438.12,452.70 L442.58,451.61 L446.94,450.55 L451.19,449.51 L455.33,448.49 L459.34,447.51 L463.23,446.56 L467.00,445.64 L470.63,444.75 L474.12,443.89 L477.47,443.07 L480.67,442.29 L483.72,441.54 L486.62,440.83 L489.36,440.16 L491.94,439.53 L494.36,438.94 L496.61,438.39 L498.69,437.88 L500.60,437.41 L502.33,436.99 L503.89,436.61 L505.26,436.27 L506.46,435.98 L507.48,435.73 L508.31,435.53 L508.96,435.37 L509.42,435.26 L509.70,435.19 L509.79,435.16" fill="none" stroke="#acb49f" stroke-opacity="0.36" stroke-width="0.7"/><path d="M282.51,443.45 L276.43,444.94 L270.43,446.41 L264.52,447.85 L258.71,449.27 L253.01,450.67 L247.42,452.04 L241.96,453.37 L236.62,454.68 L231.41,455.95 L226.35,457.19 L221.43,458.40 L216.66,459.56 L212.05,460.69 L207.60,461.78 L203.33,462.83 L199.23,463.83 L195.30,464.79 L191.56,465.71 L188.01,466.57 L184.66,467.40 L181.50,468.17 L178.54,468.89 L175.78,469.57 L173.24,470.19 L170.90,470.76 L168.78,471.28 L166.87,471.75 L165.19,472.16 L163.72,472.52 L162.47,472.82 L161.46,473.07 L160.66,473.27 L160.09,473.41 L159.75,473.49" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M533.02,382.15 L532.68,382.23 L532.11,382.37 L531.31,382.56 L530.30,382.81 L529.05,383.12 L527.58,383.48 L525.90,383.89 L523.99,384.36 L521.87,384.87 L519.53,385.45 L516.99,386.07 L514.23,386.74 L511.27,387.47 L508.11,388.24 L504.76,389.06 L501.21,389.93 L497.47,390.85 L493.54,391.81 L489.44,392.81 L485.17,393.86 L480.72,394.94 L476.11,396.07 L471.34,397.24 L466.42,398.44 L461.36,399.68 L456.15,400.96 L450.81,402.26 L445.35,403.60 L439.76,404.97 L434.06,406.36 L428.25,407.78 L422.34,409.23 L416.34,410.70 L410.26,412.19 L404.09,413.70 L397.86,415.22 L391.56,416.76 L385.21,418.32 L378.81,419.88 L372.38,421.46 L365.91,423.04 L359.41,424.63 L352.90,426.22 L346.38,427.82 L339.87,429.41 L333.36,431.01 L326.86,432.60 L320.39,434.18 L313.96,435.75 L307.56,437.32 L301.21,438.87 L294.91,440.42 L288.68,441.94 L282.51,443.45" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M159.64,473.52 L159.75,473.49 L160.09,473.41 L160.66,473.27 L161.46,473.07 L162.47,472.82 L163.72,472.52 L165.19,472.16 L166.87,471.75 L168.78,471.28 L170.90,470.76 L173.24,470.19 L175.78,469.57 L178.54,468.89 L181.50,468.17 L184.66,467.40 L188.01,466.57 L191.56,465.71 L195.30,464.79 L199.23,463.83 L203.33,462.83 L207.60,461.78 L212.05,460.69 L216.66,459.56 L221.43,458.40 L226.35,457.19 L231.41,455.95 L236.62,454.68 L241.96,453.37 L247.42,452.04 L253.01,450.67 L258.71,449.27 L264.52,447.85 L270.43,446.41 L276.43,444.94 L282.51,443.45 L288.68,441.94 L294.91,440.42 L301.21,438.87 L307.56,437.32 L313.96,435.75 L320.39,434.18 L326.86,432.60 L333.36,431.01 L339.87,429.41 L346.38,427.82 L352.90,426.22 L359.41,424.63 L365.91,423.04 L372.38,421.46 L378.81,419.88 L385.21,418.32 L391.56,416.76 L397.86,415.22 L404.09,413.70 L410.26,412.19 L416.34,410.70 L422.34,409.23 L428.25,407.78 L434.06,406.36 L439.76,404.97 L445.35,403.60 L450.81,402.26 L456.15,400.96 L461.36,399.68 L466.42,398.44 L471.34,397.24 L476.11,396.07 L480.72,394.94 L485.17,393.86 L489.44,392.81 L493.54,391.81 L497.47,390.85 L501.21,389.93 L504.76,389.06 L508.11,388.24 L511.27,387.47 L514.23,386.74 L516.99,386.07 L519.53,385.45 L521.87,384.87 L523.99,384.36 L525.90,383.89 L527.58,383.48 L529.05,383.12 L530.30,382.81 L531.31,382.56 L532.11,382.37 L532.68,382.23 L533.02,382.15 L533.13,382.12" fill="none" stroke="#acb49f" stroke-opacity="0.36" stroke-width="0.7"/><path d="M262.42,393.24 L255.63,394.91 L248.94,396.54 L242.35,398.16 L235.87,399.74 L229.51,401.30 L223.28,402.82 L217.18,404.31 L211.23,405.77 L205.42,407.19 L199.77,408.58 L194.29,409.92 L188.97,411.22 L183.83,412.48 L178.87,413.69 L174.10,414.86 L169.52,415.98 L165.15,417.05 L160.98,418.07 L157.02,419.04 L153.27,419.95 L149.75,420.82 L146.45,421.62 L143.38,422.38 L140.54,423.07 L137.93,423.71 L135.56,424.29 L133.44,424.81 L131.56,425.27 L129.92,425.67 L128.53,426.01 L127.40,426.29 L126.51,426.50 L125.88,426.66 L125.50,426.75" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M541.82,324.87 L541.44,324.96 L540.81,325.12 L539.92,325.34 L538.78,325.61 L537.40,325.95 L535.76,326.35 L533.88,326.81 L531.75,327.33 L529.39,327.91 L526.78,328.55 L523.94,329.25 L520.87,330.00 L517.57,330.81 L514.04,331.67 L510.30,332.58 L506.34,333.55 L502.17,334.57 L497.79,335.64 L493.22,336.76 L488.45,337.93 L483.49,339.14 L478.35,340.40 L473.03,341.70 L467.54,343.05 L461.89,344.43 L456.09,345.85 L450.13,347.31 L444.03,348.80 L437.80,350.33 L431.44,351.88 L424.97,353.47 L418.38,355.08 L411.68,356.72 L404.90,358.38 L398.02,360.06 L391.07,361.76 L384.05,363.48 L376.96,365.21 L369.83,366.96 L362.65,368.72 L355.43,370.48 L348.19,372.26 L340.93,374.03 L333.66,375.81 L326.39,377.59 L319.13,379.37 L311.89,381.14 L304.67,382.90 L297.49,384.66 L290.35,386.41 L283.27,388.14 L276.25,389.86 L269.29,391.56 L262.42,393.24" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M125.37,426.78 L125.50,426.75 L125.88,426.66 L126.51,426.50 L127.40,426.29 L128.53,426.01 L129.92,425.67 L131.56,425.27 L133.44,424.81 L135.56,424.29 L137.93,423.71 L140.54,423.07 L143.38,422.38 L146.45,421.62 L149.75,420.82 L153.27,419.95 L157.02,419.04 L160.98,418.07 L165.15,417.05 L169.52,415.98 L174.10,414.86 L178.87,413.69 L183.83,412.48 L188.97,411.22 L194.29,409.92 L199.77,408.58 L205.42,407.19 L211.23,405.77 L217.18,404.31 L223.28,402.82 L229.51,401.30 L235.87,399.74 L242.35,398.16 L248.94,396.54 L255.63,394.91 L262.42,393.24 L269.29,391.56 L276.25,389.86 L283.27,388.14 L290.35,386.41 L297.49,384.66 L304.67,382.90 L311.89,381.14 L319.13,379.37 L326.39,377.59 L333.66,375.81 L340.93,374.03 L348.19,372.26 L355.43,370.48 L362.65,368.72 L369.83,366.96 L376.96,365.21 L384.05,363.48 L391.07,361.76 L398.02,360.06 L404.90,358.38 L411.68,356.72 L418.38,355.08 L424.97,353.47 L431.44,351.88 L437.80,350.33 L444.03,348.80 L450.13,347.31 L456.09,345.85 L461.89,344.43 L467.54,343.05 L473.03,341.70 L478.35,340.40 L483.49,339.14 L488.45,337.93 L493.22,336.76 L497.79,335.64 L502.17,334.57 L506.34,333.55 L510.30,332.58 L514.04,331.67 L517.57,330.81 L520.87,330.00 L523.94,329.25 L526.78,328.55 L529.39,327.91 L531.75,327.33 L533.88,326.81 L535.76,326.35 L537.40,325.95 L538.78,325.61 L539.92,325.34 L540.81,325.12 L541.44,324.96 L541.82,324.87 L541.95,324.84" fill="none" stroke="#acb49f" stroke-opacity="0.36" stroke-width="0.7"/><path d="M246.25,338.05 L239.22,339.77 L232.29,341.46 L225.47,343.13 L218.76,344.77 L212.18,346.38 L205.73,347.96 L199.42,349.51 L193.25,351.02 L187.24,352.49 L181.39,353.92 L175.71,355.31 L170.21,356.66 L164.88,357.96 L159.75,359.22 L154.81,360.42 L150.08,361.58 L145.55,362.69 L141.23,363.75 L137.13,364.75 L133.25,365.70 L129.60,366.59 L126.19,367.43 L123.01,368.21 L120.06,368.93 L117.37,369.59 L114.92,370.19 L112.72,370.73 L110.77,371.20 L109.08,371.62 L107.64,371.97 L106.46,372.26 L105.54,372.48 L104.89,372.64 L104.49,372.74" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M535.51,267.26 L535.11,267.36 L534.46,267.52 L533.54,267.74 L532.36,268.03 L530.92,268.38 L529.23,268.80 L527.28,269.27 L525.08,269.81 L522.63,270.41 L519.94,271.07 L516.99,271.79 L513.81,272.57 L510.40,273.41 L506.75,274.30 L502.87,275.25 L498.77,276.25 L494.45,277.31 L489.92,278.42 L485.19,279.58 L480.25,280.78 L475.12,282.04 L469.79,283.34 L464.29,284.69 L458.61,286.08 L452.76,287.51 L446.75,288.98 L440.58,290.49 L434.27,292.04 L427.82,293.62 L421.24,295.23 L414.53,296.87 L407.71,298.54 L400.78,300.23 L393.75,301.95 L386.64,303.69 L379.44,305.45 L372.17,307.23 L364.83,309.03 L357.44,310.84 L350.01,312.66 L342.54,314.48 L335.04,316.32 L327.53,318.16 L320.00,320.00 L312.47,321.84 L304.96,323.68 L297.46,325.52 L289.99,327.34 L282.56,329.16 L275.17,330.97 L267.83,332.77 L260.56,334.55 L253.36,336.31 L246.25,338.05" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M104.36,372.77 L104.49,372.74 L104.89,372.64 L105.54,372.48 L106.46,372.26 L107.64,371.97 L109.08,371.62 L110.77,371.20 L112.72,370.73 L114.92,370.19 L117.37,369.59 L120.06,368.93 L123.01,368.21 L126.19,367.43 L129.60,366.59 L133.25,365.70 L137.13,364.75 L141.23,363.75 L145.55,362.69 L150.08,361.58 L154.81,360.42 L159.75,359.22 L164.88,357.96 L170.21,356.66 L175.71,355.31 L181.39,353.92 L187.24,352.49 L193.25,351.02 L199.42,349.51 L205.73,347.96 L212.18,346.38 L218.76,344.77 L225.47,343.13 L232.29,341.46 L239.22,339.77 L246.25,338.05 L253.36,336.31 L260.56,334.55 L267.83,332.77 L275.17,330.97 L282.56,329.16 L289.99,327.34 L297.46,325.52 L304.96,323.68 L312.47,321.84 L320.00,320.00 L327.53,318.16 L335.04,316.32 L342.54,314.48 L350.01,312.66 L357.44,310.84 L364.83,309.03 L372.17,307.23 L379.44,305.45 L386.64,303.69 L393.75,301.95 L400.78,300.23 L407.71,298.54 L414.53,296.87 L421.24,295.23 L427.82,293.62 L434.27,292.04 L440.58,290.49 L446.75,288.98 L452.76,287.51 L458.61,286.08 L464.29,284.69 L469.79,283.34 L475.12,282.04 L480.25,280.78 L485.19,279.58 L489.92,278.42 L494.45,277.31 L498.77,276.25 L502.87,275.25 L506.75,274.30 L510.40,273.41 L513.81,272.57 L516.99,271.79 L519.94,271.07 L522.63,270.41 L525.08,269.81 L527.28,269.27 L529.23,268.80 L530.92,268.38 L532.36,268.03 L533.54,267.74 L534.46,267.52 L535.11,267.36 L535.51,267.26 L535.64,267.23" fill="none" stroke="#acb49f" stroke-opacity="0.36" stroke-width="0.7"/><path d="M235.10,281.62 L228.32,283.28 L221.62,284.92 L215.03,286.53 L208.56,288.12 L202.20,289.67 L195.97,291.20 L189.87,292.69 L183.91,294.15 L178.11,295.57 L172.46,296.95 L166.97,298.30 L161.65,299.60 L156.51,300.86 L151.55,302.07 L146.78,303.24 L142.21,304.36 L137.83,305.43 L133.66,306.45 L129.70,307.42 L125.96,308.33 L122.43,309.19 L119.13,310.00 L116.06,310.75 L113.22,311.45 L110.61,312.09 L108.25,312.67 L106.12,313.19 L104.24,313.65 L102.60,314.05 L101.22,314.39 L100.08,314.66 L99.19,314.88 L98.56,315.04 L98.18,315.13" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M514.50,213.25 L514.12,213.34 L513.49,213.50 L512.60,213.71 L511.47,213.99 L510.08,214.33 L508.44,214.73 L506.56,215.19 L504.44,215.71 L502.07,216.29 L499.46,216.93 L496.62,217.62 L493.55,218.38 L490.25,219.18 L486.73,220.05 L482.98,220.96 L479.02,221.93 L474.85,222.95 L470.48,224.02 L465.90,225.14 L461.13,226.31 L456.17,227.52 L451.03,228.78 L445.71,230.08 L440.23,231.42 L434.58,232.81 L428.77,234.23 L422.82,235.69 L416.72,237.18 L410.49,238.70 L404.13,240.26 L397.65,241.84 L391.06,243.46 L384.37,245.09 L377.58,246.76 L370.71,248.44 L363.75,250.14 L356.73,251.86 L349.65,253.59 L342.51,255.34 L335.33,257.10 L328.11,258.86 L320.87,260.63 L313.61,262.41 L306.34,264.19 L299.07,265.97 L291.81,267.74 L284.57,269.52 L277.35,271.28 L270.17,273.04 L263.04,274.79 L255.95,276.52 L248.93,278.24 L241.98,279.94 L235.10,281.62" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M98.05,315.16 L98.18,315.13 L98.56,315.04 L99.19,314.88 L100.08,314.66 L101.22,314.39 L102.60,314.05 L104.24,313.65 L106.12,313.19 L108.25,312.67 L110.61,312.09 L113.22,311.45 L116.06,310.75 L119.13,310.00 L122.43,309.19 L125.96,308.33 L129.70,307.42 L133.66,306.45 L137.83,305.43 L142.21,304.36 L146.78,303.24 L151.55,302.07 L156.51,300.86 L161.65,299.60 L166.97,298.30 L172.46,296.95 L178.11,295.57 L183.91,294.15 L189.87,292.69 L195.97,291.20 L202.20,289.67 L208.56,288.12 L215.03,286.53 L221.62,284.92 L228.32,283.28 L235.10,281.62 L241.98,279.94 L248.93,278.24 L255.95,276.52 L263.04,274.79 L270.17,273.04 L277.35,271.28 L284.57,269.52 L291.81,267.74 L299.07,265.97 L306.34,264.19 L313.61,262.41 L320.87,260.63 L328.11,258.86 L335.33,257.10 L342.51,255.34 L349.65,253.59 L356.73,251.86 L363.75,250.14 L370.71,248.44 L377.58,246.76 L384.37,245.09 L391.06,243.46 L397.65,241.84 L404.13,240.26 L410.49,238.70 L416.72,237.18 L422.82,235.69 L428.77,234.23 L434.58,232.81 L440.23,231.42 L445.71,230.08 L451.03,228.78 L456.17,227.52 L461.13,226.31 L465.90,225.14 L470.48,224.02 L474.85,222.95 L479.02,221.93 L482.98,220.96 L486.73,220.05 L490.25,219.18 L493.55,218.38 L496.62,217.62 L499.46,216.93 L502.07,216.29 L504.44,215.71 L506.56,215.19 L508.44,214.73 L510.08,214.33 L511.47,213.99 L512.60,213.71 L513.49,213.50 L514.12,213.34 L514.50,213.25 L514.63,213.22" fill="none" stroke="#acb49f" stroke-opacity="0.36" stroke-width="0.7"/><path d="M229.74,227.81 L223.66,229.30 L217.66,230.77 L211.75,232.22 L205.94,233.64 L200.24,235.03 L194.65,236.40 L189.19,237.74 L183.85,239.04 L178.64,240.32 L173.58,241.56 L168.66,242.76 L163.89,243.93 L159.28,245.06 L154.83,246.14 L150.56,247.19 L146.46,248.19 L142.53,249.15 L138.79,250.07 L135.24,250.94 L131.89,251.76 L128.73,252.53 L125.77,253.26 L123.01,253.93 L120.47,254.55 L118.13,255.13 L116.01,255.64 L114.10,256.11 L112.42,256.52 L110.95,256.88 L109.70,257.19 L108.69,257.44 L107.89,257.63 L107.32,257.77 L106.98,257.85" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M480.25,166.51 L479.91,166.59 L479.34,166.73 L478.54,166.93 L477.53,167.18 L476.28,167.48 L474.81,167.84 L473.13,168.25 L471.22,168.72 L469.10,169.24 L466.76,169.81 L464.22,170.43 L461.46,171.11 L458.50,171.83 L455.34,172.60 L451.99,173.43 L448.44,174.29 L444.70,175.21 L440.77,176.17 L436.67,177.17 L432.40,178.22 L427.95,179.31 L423.34,180.44 L418.57,181.60 L413.65,182.81 L408.59,184.05 L403.38,185.32 L398.04,186.63 L392.58,187.96 L386.99,189.33 L381.29,190.73 L375.48,192.15 L369.57,193.59 L363.57,195.06 L357.49,196.55 L351.32,198.06 L345.09,199.58 L338.79,201.13 L332.44,202.68 L326.04,204.25 L319.61,205.82 L313.14,207.40 L306.64,208.99 L300.13,210.59 L293.62,212.18 L287.10,213.78 L280.59,215.37 L274.09,216.96 L267.62,218.54 L261.19,220.12 L254.79,221.68 L248.44,223.24 L242.14,224.78 L235.91,226.30 L229.74,227.81" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M106.87,257.88 L106.98,257.85 L107.32,257.77 L107.89,257.63 L108.69,257.44 L109.70,257.19 L110.95,256.88 L112.42,256.52 L114.10,256.11 L116.01,255.64 L118.13,255.13 L120.47,254.55 L123.01,253.93 L125.77,253.26 L128.73,252.53 L131.89,251.76 L135.24,250.94 L138.79,250.07 L142.53,249.15 L146.46,248.19 L150.56,247.19 L154.83,246.14 L159.28,245.06 L163.89,243.93 L168.66,242.76 L173.58,241.56 L178.64,240.32 L183.85,239.04 L189.19,237.74 L194.65,236.40 L200.24,235.03 L205.94,233.64 L211.75,232.22 L217.66,230.77 L223.66,229.30 L229.74,227.81 L235.91,226.30 L242.14,224.78 L248.44,223.24 L254.79,221.68 L261.19,220.12 L267.62,218.54 L274.09,216.96 L280.59,215.37 L287.10,213.78 L293.62,212.18 L300.13,210.59 L306.64,208.99 L313.14,207.40 L319.61,205.82 L326.04,204.25 L332.44,202.68 L338.79,201.13 L345.09,199.58 L351.32,198.06 L357.49,196.55 L363.57,195.06 L369.57,193.59 L375.48,192.15 L381.29,190.73 L386.99,189.33 L392.58,187.96 L398.04,186.63 L403.38,185.32 L408.59,184.05 L413.65,182.81 L418.57,181.60 L423.34,180.44 L427.95,179.31 L432.40,178.22 L436.67,177.17 L440.77,176.17 L444.70,175.21 L448.44,174.29 L451.99,173.43 L455.34,172.60 L458.50,171.83 L461.46,171.11 L464.22,170.43 L466.76,169.81 L469.10,169.24 L471.22,168.72 L473.13,168.25 L474.81,167.84 L476.28,167.48 L477.53,167.18 L478.54,166.93 L479.34,166.73 L479.91,166.59 L480.25,166.51 L480.36,166.48" fill="none" stroke="#acb49f" stroke-opacity="0.36" stroke-width="0.7"/><path d="M230.54,180.28 L225.57,181.50 L220.67,182.70 L215.84,183.88 L211.10,185.04 L206.45,186.18 L201.88,187.30 L197.42,188.39 L193.06,189.45 L188.81,190.49 L184.67,191.51 L180.66,192.49 L176.77,193.44 L173.00,194.36 L169.37,195.25 L165.88,196.11 L162.53,196.93 L159.33,197.71 L156.28,198.46 L153.38,199.17 L150.64,199.84 L148.06,200.47 L145.64,201.06 L143.39,201.61 L141.31,202.12 L139.40,202.59 L137.67,203.01 L136.11,203.39 L134.74,203.73 L133.54,204.02 L132.52,204.27 L131.69,204.47 L131.04,204.63 L130.58,204.74 L130.30,204.81" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M435.07,130.23 L434.79,130.30 L434.33,130.41 L433.68,130.57 L432.85,130.77 L431.83,131.02 L430.64,131.32 L429.26,131.65 L427.70,132.03 L425.97,132.46 L424.06,132.92 L421.98,133.43 L419.73,133.98 L417.32,134.58 L414.74,135.21 L412.00,135.88 L409.10,136.59 L406.04,137.33 L402.84,138.12 L399.49,138.94 L396.00,139.79 L392.37,140.68 L388.61,141.60 L384.71,142.55 L380.70,143.54 L376.56,144.55 L372.31,145.59 L367.95,146.66 L363.49,147.75 L358.93,148.86 L354.27,150.00 L349.53,151.16 L344.70,152.34 L339.81,153.54 L334.84,154.76 L329.80,155.99 L324.71,157.24 L319.57,158.49 L314.39,159.76 L309.16,161.04 L303.91,162.33 L298.62,163.62 L293.32,164.92 L288.01,166.22 L282.69,167.52 L277.36,168.82 L272.05,170.12 L266.75,171.42 L261.47,172.71 L256.21,174.00 L250.98,175.28 L245.80,176.55 L240.66,177.81 L235.57,179.05 L230.54,180.28" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M130.21,204.84 L130.30,204.81 L130.58,204.74 L131.04,204.63 L131.69,204.47 L132.52,204.27 L133.54,204.02 L134.74,203.73 L136.11,203.39 L137.67,203.01 L139.40,202.59 L141.31,202.12 L143.39,201.61 L145.64,201.06 L148.06,200.47 L150.64,199.84 L153.38,199.17 L156.28,198.46 L159.33,197.71 L162.53,196.93 L165.88,196.11 L169.37,195.25 L173.00,194.36 L176.77,193.44 L180.66,192.49 L184.67,191.51 L188.81,190.49 L193.06,189.45 L197.42,188.39 L201.88,187.30 L206.45,186.18 L211.10,185.04 L215.84,183.88 L220.67,182.70 L225.57,181.50 L230.54,180.28 L235.57,179.05 L240.66,177.81 L245.80,176.55 L250.98,175.28 L256.21,174.00 L261.47,172.71 L266.75,171.42 L272.05,170.12 L277.36,168.82 L282.69,167.52 L288.01,166.22 L293.32,164.92 L298.62,163.62 L303.91,162.33 L309.16,161.04 L314.39,159.76 L319.57,158.49 L324.71,157.24 L329.80,155.99 L334.84,154.76 L339.81,153.54 L344.70,152.34 L349.53,151.16 L354.27,150.00 L358.93,148.86 L363.49,147.75 L367.95,146.66 L372.31,145.59 L376.56,144.55 L380.70,143.54 L384.71,142.55 L388.61,141.60 L392.37,140.68 L396.00,139.79 L399.49,138.94 L402.84,138.12 L406.04,137.33 L409.10,136.59 L412.00,135.88 L414.74,135.21 L417.32,134.58 L419.73,133.98 L421.98,133.43 L424.06,132.92 L425.97,132.46 L427.70,132.03 L429.26,131.65 L430.64,131.32 L431.83,131.02 L432.85,130.77 L433.68,130.57 L434.33,130.41 L434.79,130.30 L435.07,130.23 L435.16,130.21" fill="none" stroke="#acb49f" stroke-opacity="0.36" stroke-width="0.7"/><path d="M237.42,142.28 L233.91,143.14 L230.45,143.98 L227.04,144.82 L223.68,145.64 L220.39,146.45 L217.16,147.23 L214.01,148.01 L210.93,148.76 L207.92,149.50 L205.00,150.21 L202.16,150.91 L199.40,151.58 L196.74,152.23 L194.18,152.86 L191.71,153.46 L189.34,154.04 L187.07,154.60 L184.91,155.13 L182.86,155.63 L180.93,156.10 L179.10,156.55 L177.39,156.97 L175.80,157.36 L174.33,157.72 L172.98,158.05 L171.76,158.35 L170.66,158.62 L169.68,158.85 L168.84,159.06 L168.12,159.24 L167.53,159.38 L167.07,159.49 L166.74,159.57 L166.55,159.62" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M382.05,106.88 L381.86,106.93 L381.53,107.01 L381.07,107.12 L380.48,107.27 L379.76,107.44 L378.92,107.65 L377.94,107.89 L376.84,108.16 L375.62,108.46 L374.27,108.79 L372.80,109.15 L371.21,109.54 L369.50,109.96 L367.67,110.40 L365.74,110.88 L363.69,111.38 L361.53,111.91 L359.26,112.46 L356.89,113.04 L354.42,113.64 L351.86,114.27 L349.20,114.92 L346.44,115.60 L343.60,116.29 L340.68,117.01 L337.67,117.74 L334.59,118.50 L331.43,119.27 L328.21,120.06 L324.92,120.87 L321.56,121.69 L318.15,122.52 L314.69,123.37 L311.18,124.23 L307.62,125.10 L304.02,125.98 L300.38,126.87 L296.72,127.77 L293.02,128.67 L289.31,129.58 L285.57,130.49 L281.82,131.41 L278.06,132.33 L274.30,133.25 L270.54,134.17 L266.78,135.09 L263.03,136.01 L259.29,136.92 L255.58,137.83 L251.88,138.74 L248.22,139.64 L244.58,140.53 L240.98,141.41 L237.42,142.28" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M166.48,159.64 L166.55,159.62 L166.74,159.57 L167.07,159.49 L167.53,159.38 L168.12,159.24 L168.84,159.06 L169.68,158.85 L170.66,158.62 L171.76,158.35 L172.98,158.05 L174.33,157.72 L175.80,157.36 L177.39,156.97 L179.10,156.55 L180.93,156.10 L182.86,155.63 L184.91,155.13 L187.07,154.60 L189.34,154.04 L191.71,153.46 L194.18,152.86 L196.74,152.23 L199.40,151.58 L202.16,150.91 L205.00,150.21 L207.92,149.50 L210.93,148.76 L214.01,148.01 L217.16,147.23 L220.39,146.45 L223.68,145.64 L227.04,144.82 L230.45,143.98 L233.91,143.14 L237.42,142.28 L240.98,141.41 L244.58,140.53 L248.22,139.64 L251.88,138.74 L255.58,137.83 L259.29,136.92 L263.03,136.01 L266.78,135.09 L270.54,134.17 L274.30,133.25 L278.06,132.33 L281.82,131.41 L285.57,130.49 L289.31,129.58 L293.02,128.67 L296.72,127.77 L300.38,126.87 L304.02,125.98 L307.62,125.10 L311.18,124.23 L314.69,123.37 L318.15,122.52 L321.56,121.69 L324.92,120.87 L328.21,120.06 L331.43,119.27 L334.59,118.50 L337.67,117.74 L340.68,117.01 L343.60,116.29 L346.44,115.60 L349.20,114.92 L351.86,114.27 L354.42,113.64 L356.89,113.04 L359.26,112.46 L361.53,111.91 L363.69,111.38 L365.74,110.88 L367.67,110.40 L369.50,109.96 L371.21,109.54 L372.80,109.15 L374.27,108.79 L375.62,108.46 L376.84,108.16 L377.94,107.89 L378.92,107.65 L379.76,107.44 L380.48,107.27 L381.07,107.12 L381.53,107.01 L381.86,106.93 L382.05,106.88 L382.12,106.87" fill="none" stroke="#acb49f" stroke-opacity="0.36" stroke-width="0.7"/><path d="M249.94,116.38 L248.12,116.83 L246.33,117.27 L244.56,117.70 L242.83,118.12 L241.12,118.54 L239.45,118.95 L237.82,119.35 L236.22,119.74 L234.67,120.12 L233.15,120.49 L231.68,120.85 L230.26,121.20 L228.88,121.54 L227.55,121.86 L226.27,122.17 L225.05,122.47 L223.88,122.76 L222.76,123.03 L221.70,123.29 L220.69,123.54 L219.75,123.77 L218.87,123.99 L218.04,124.19 L217.28,124.37 L216.58,124.54 L215.95,124.70 L215.38,124.84 L214.87,124.96 L214.44,125.07 L214.07,125.16 L213.76,125.24 L213.52,125.29 L213.35,125.34 L213.25,125.36" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M324.81,98.06 L324.70,98.09 L324.53,98.13 L324.30,98.19 L323.99,98.26 L323.62,98.35 L323.18,98.46 L322.68,98.58 L322.11,98.72 L321.47,98.88 L320.78,99.05 L320.01,99.23 L319.19,99.44 L318.31,99.65 L317.36,99.88 L316.36,100.13 L315.30,100.39 L314.18,100.66 L313.01,100.95 L311.78,101.25 L310.50,101.56 L309.18,101.89 L307.80,102.22 L306.37,102.57 L304.90,102.93 L303.39,103.30 L301.83,103.68 L300.24,104.07 L298.60,104.47 L296.93,104.88 L295.23,105.30 L293.49,105.72 L291.73,106.16 L289.94,106.59 L288.12,107.04 L286.27,107.49 L284.41,107.95 L282.53,108.41 L280.63,108.87 L278.72,109.34 L276.80,109.81 L274.86,110.28 L272.92,110.76 L270.98,111.23 L269.03,111.71 L267.08,112.19 L265.13,112.66 L263.19,113.14 L261.26,113.61 L259.34,114.08 L257.42,114.55 L255.53,115.01 L253.64,115.48 L251.78,115.93 L249.94,116.38" fill="none" stroke="#acb49f" stroke-opacity="0.1" stroke-width="0.7"/><path d="M213.22,125.37 L213.25,125.36 L213.35,125.34 L213.52,125.29 L213.76,125.24 L214.07,125.16 L214.44,125.07 L214.87,124.96 L215.38,124.84 L215.95,124.70 L216.58,124.54 L217.28,124.37 L218.04,124.19 L218.87,123.99 L219.75,123.77 L220.69,123.54 L221.70,123.29 L222.76,123.03 L223.88,122.76 L225.05,122.47 L226.27,122.17 L227.55,121.86 L228.88,121.54 L230.26,121.20 L231.68,120.85 L233.15,120.49 L234.67,120.12 L236.22,119.74 L237.82,119.35 L239.45,118.95 L241.12,118.54 L242.83,118.12 L244.56,117.70 L246.33,117.27 L248.12,116.83 L249.94,116.38 L251.78,115.93 L253.64,115.48 L255.53,115.01 L257.42,114.55 L259.34,114.08 L261.26,113.61 L263.19,113.14 L265.13,112.66 L267.08,112.19 L269.03,111.71 L270.98,111.23 L272.92,110.76 L274.86,110.28 L276.80,109.81 L278.72,109.34 L280.63,108.87 L282.53,108.41 L284.41,107.95 L286.27,107.49 L288.12,107.04 L289.94,106.59 L291.73,106.16 L293.49,105.72 L295.23,105.30 L296.93,104.88 L298.60,104.47 L300.24,104.07 L301.83,103.68 L303.39,103.30 L304.90,102.93 L306.37,102.57 L307.80,102.22 L309.18,101.89 L310.50,101.56 L311.78,101.25 L313.01,100.95 L314.18,100.66 L315.30,100.39 L316.36,100.13 L317.36,99.88 L318.31,99.65 L319.19,99.44 L320.01,99.23 L320.78,99.05 L321.47,98.88 L322.11,98.72 L322.68,98.58 L323.18,98.46 L323.62,98.35 L323.99,98.26 L324.30,98.19 L324.53,98.13 L324.70,98.09 L324.81,98.06 L324.84,98.05" fill="none" stroke="#acb49f" stroke-opacity="0.36" stroke-width="0.7"/><path d="M372.77,535.64 L370.16,536.14 L367.50,536.37 L364.77,536.34 L361.99,536.05 L359.16,535.50 L356.28,534.68 L353.36,533.60 L350.40,532.26 L347.40,530.66 L344.36,528.81 L341.30,526.70 L338.21,524.34 L335.10,521.73 L331.97,518.87 L328.82,515.77 L325.67,512.43 L322.51,508.86 L319.34,505.06 L316.18,501.04 L313.02,496.79 L309.87,492.33 L306.73,487.65 L303.60,482.78 L300.50,477.70 L297.42,472.43 L294.37,466.98 L291.35,461.35 L288.37,455.55 L285.42,449.58 L282.51,443.45 L279.65,437.17 L276.84,430.75 L274.09,424.20 L271.39,417.51 L268.74,410.71 L266.16,403.80 L263.65,396.79 L261.20,389.68 L258.83,382.49 L256.53,375.22 L254.31,367.88 L252.17,360.49 L250.11,353.05 L248.13,345.56 L246.25,338.05 L244.45,330.51 L242.75,322.96 L241.14,315.41 L239.62,307.86 L238.20,300.33 L236.89,292.82 L235.67,285.34 L234.56,277.91 L233.55,270.53 L232.65,263.21 L231.85,255.96 L231.16,248.78 L230.58,241.69 L230.11,234.70 L229.74,227.81 L229.49,221.04 L229.35,214.38 L229.32,207.85 L229.39,201.46 L229.58,195.22 L229.88,189.12 L230.29,183.19 L230.81,177.42 L231.43,171.83 L232.17,166.41 L233.01,161.19 L233.96,156.15 L235.01,151.32 L236.17,146.69 L237.42,142.28 L238.78,138.08 L240.24,134.10 L241.79,130.35 L243.44,126.83 L245.19,123.54 L247.02,120.49 L248.95,117.69 L250.96,115.13 L253.05,112.83 L255.22,110.77 L257.48,108.97 L259.81,107.43 L262.21,106.15 L264.69,105.12 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.09" stroke-width="0.7"/><path d="M372.77,535.64 L368.42,536.56 L364.01,537.22 L359.55,537.62 L355.04,537.75 L350.49,537.62 L345.90,537.22 L341.28,536.55 L336.63,535.63 L331.97,534.44 L327.29,532.98 L322.59,531.27 L317.90,529.31 L313.21,527.08 L308.53,524.61 L303.86,521.88 L299.21,518.91 L294.58,515.70 L289.99,512.24 L285.44,508.56 L280.92,504.64 L276.45,500.50 L272.04,496.14 L267.69,491.57 L263.39,486.78 L259.17,481.80 L255.02,476.61 L250.95,471.24 L246.97,465.68 L243.07,459.94 L239.27,454.03 L235.57,447.96 L231.97,441.73 L228.47,435.36 L225.09,428.84 L221.82,422.19 L218.68,415.42 L215.65,408.53 L212.76,401.54 L209.99,394.44 L207.36,387.25 L204.86,379.98 L202.51,372.64 L200.30,365.24 L198.23,357.77 L196.32,350.27 L194.55,342.72 L192.94,335.15 L191.48,327.56 L190.18,319.96 L189.03,312.36 L188.05,304.77 L187.22,297.20 L186.56,289.66 L186.06,282.15 L185.73,274.69 L185.55,267.28 L185.55,259.94 L185.70,252.68 L186.02,245.49 L186.50,238.39 L187.15,231.40 L187.95,224.51 L188.92,217.74 L190.05,211.09 L191.33,204.58 L192.77,198.20 L194.37,191.98 L196.12,185.91 L198.02,180.00 L200.07,174.27 L202.27,168.71 L204.61,163.34 L207.09,158.15 L209.71,153.17 L212.46,148.39 L215.34,143.81 L218.35,139.46 L221.49,135.32 L224.74,131.40 L228.11,127.72 L231.59,124.27 L235.18,121.06 L238.88,118.09 L242.67,115.37 L246.55,112.89 L250.53,110.67 L254.59,108.71 L258.73,107.00 L262.95,105.55 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.09" stroke-width="0.7"/><path d="M372.77,535.64 L366.97,536.92 L361.12,537.93 L355.21,538.68 L349.27,539.16 L343.28,539.38 L337.27,539.33 L331.24,539.01 L325.19,538.43 L319.14,537.57 L313.09,536.46 L307.05,535.08 L301.02,533.44 L295.02,531.53 L289.04,529.37 L283.11,526.96 L277.22,524.29 L271.38,521.38 L265.60,518.21 L259.88,514.81 L254.24,511.17 L248.68,507.30 L243.21,503.20 L237.83,498.87 L232.55,494.33 L227.38,489.58 L222.32,484.61 L217.38,479.45 L212.56,474.10 L207.88,468.55 L203.33,462.83 L198.92,456.93 L194.66,450.86 L190.56,444.64 L186.61,438.26 L182.82,431.74 L179.20,425.08 L175.76,418.30 L172.49,411.39 L169.39,404.37 L166.49,397.25 L163.76,390.04 L161.23,382.74 L158.90,375.37 L156.75,367.93 L154.81,360.42 L153.07,352.87 L151.53,345.28 L150.20,337.66 L149.08,330.02 L148.16,322.37 L147.45,314.71 L146.95,307.06 L146.67,299.42 L146.59,291.81 L146.73,284.23 L147.07,276.70 L147.63,269.22 L148.40,261.80 L149.37,254.46 L150.56,247.19 L151.95,240.01 L153.54,232.93 L155.34,225.96 L157.34,219.10 L159.54,212.36 L161.93,205.75 L164.52,199.28 L167.29,192.96 L170.25,186.80 L173.40,180.80 L176.72,174.96 L180.21,169.31 L183.88,163.83 L187.71,158.55 L191.71,153.46 L195.86,148.58 L200.16,143.91 L204.60,139.45 L209.19,135.21 L213.91,131.19 L218.77,127.41 L223.74,123.86 L228.84,120.55 L234.04,117.48 L239.35,114.66 L244.75,112.09 L250.25,109.77 L255.84,107.71 L261.50,105.91 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.09" stroke-width="0.7"/><path d="M372.77,535.64 L365.92,537.17 L359.01,538.45 L352.05,539.45 L345.06,540.19 L338.03,540.67 L330.98,540.87 L323.92,540.80 L316.86,540.47 L309.79,539.86 L302.75,538.99 L295.72,537.85 L288.72,536.45 L281.76,534.78 L274.84,532.85 L267.98,530.66 L261.19,528.21 L254.46,525.52 L247.82,522.57 L241.26,519.37 L234.80,515.93 L228.45,512.25 L222.20,508.34 L216.07,504.20 L210.07,499.83 L204.21,495.25 L198.48,490.45 L192.91,485.44 L187.49,480.23 L182.23,474.83 L177.13,469.24 L172.22,463.46 L167.48,457.51 L162.93,451.40 L158.57,445.12 L154.40,438.69 L150.44,432.12 L146.68,425.41 L143.14,418.57 L139.81,411.61 L136.70,404.54 L133.81,397.37 L131.15,390.10 L128.72,382.75 L126.53,375.32 L124.57,367.83 L122.84,360.27 L121.36,352.67 L120.12,345.02 L119.12,337.35 L118.37,329.65 L117.87,321.95 L117.61,314.24 L117.59,306.54 L117.82,298.85 L118.30,291.19 L119.03,283.56 L120.00,275.98 L121.21,268.46 L122.67,260.99 L124.36,253.60 L126.30,246.29 L128.47,239.07 L130.87,231.94 L133.51,224.93 L136.37,218.03 L139.45,211.25 L142.76,204.61 L146.28,198.11 L150.01,191.75 L153.95,185.55 L158.10,179.52 L162.44,173.66 L166.97,167.97 L171.68,162.47 L176.58,157.17 L181.66,152.06 L186.90,147.15 L192.30,142.46 L197.86,137.98 L203.57,133.72 L209.42,129.70 L215.41,125.90 L221.52,122.34 L227.75,119.02 L234.10,115.94 L240.54,113.12 L247.09,110.54 L253.73,108.22 L260.44,106.16 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.09" stroke-width="0.7"/><path d="M372.77,535.64 L365.33,537.32 L357.83,538.74 L350.28,539.89 L342.70,540.77 L335.09,541.39 L327.46,541.73 L319.83,541.80 L312.19,541.61 L304.56,541.14 L296.96,540.41 L289.38,539.40 L281.83,538.13 L274.34,536.59 L266.90,534.79 L259.52,532.73 L252.22,530.41 L245.00,527.83 L237.87,525.00 L230.84,521.92 L223.92,518.59 L217.12,515.02 L210.44,511.22 L203.90,507.18 L197.50,502.91 L191.24,498.42 L185.15,493.71 L179.21,488.79 L173.45,483.67 L167.87,478.34 L162.47,472.82 L157.27,467.12 L152.26,461.24 L147.46,455.18 L142.87,448.96 L138.49,442.59 L134.34,436.06 L130.41,429.39 L126.71,422.59 L123.25,415.67 L120.03,408.62 L117.05,401.47 L114.32,394.22 L111.84,386.88 L109.61,379.46 L107.64,371.97 L105.93,364.41 L104.48,356.80 L103.29,349.14 L102.36,341.45 L101.70,333.73 L101.31,326.00 L101.18,318.26 L101.32,310.52 L101.73,302.79 L102.40,295.08 L103.33,287.41 L104.54,279.77 L106.00,272.18 L107.72,264.65 L109.70,257.19 L111.94,249.80 L114.44,242.50 L117.18,235.29 L120.17,228.19 L123.40,221.20 L126.87,214.33 L130.58,207.59 L134.52,200.98 L138.69,194.52 L143.07,188.22 L147.67,182.07 L152.49,176.09 L157.50,170.29 L162.71,164.67 L168.12,159.24 L173.71,154.00 L179.48,148.97 L185.42,144.14 L191.52,139.53 L197.78,135.14 L204.19,130.98 L210.74,127.04 L217.42,123.34 L224.23,119.88 L231.16,116.66 L238.19,113.69 L245.32,110.98 L252.55,108.51 L259.85,106.31 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.09" stroke-width="0.7"/><path d="M372.77,535.64 L365.24,537.34 L357.66,538.78 L350.03,539.95 L342.36,540.85 L334.67,541.49 L326.95,541.85 L319.23,541.95 L311.51,541.77 L303.81,541.33 L296.12,540.61 L288.46,539.63 L280.83,538.38 L273.26,536.86 L265.74,535.08 L258.29,533.03 L250.92,530.73 L243.62,528.17 L236.43,525.35 L229.33,522.29 L222.34,518.98 L215.48,515.43 L208.74,511.63 L202.13,507.61 L195.67,503.36 L189.36,498.88 L183.21,494.18 L177.23,489.28 L171.42,484.16 L165.79,478.85 L160.35,473.34 L155.10,467.65 L150.06,461.78 L145.22,455.73 L140.59,449.52 L136.19,443.15 L132.00,436.63 L128.05,429.97 L124.33,423.17 L120.85,416.25 L117.61,409.22 L114.62,402.07 L111.88,394.82 L109.39,387.48 L107.16,380.06 L105.18,372.57 L103.47,365.01 L102.03,357.40 L100.84,349.74 L99.93,342.05 L99.28,334.33 L98.91,326.59 L98.80,318.84 L98.96,311.10 L99.39,303.36 L100.09,295.65 L101.06,287.96 L102.29,280.32 L103.79,272.72 L105.55,265.18 L107.58,257.71 L109.86,250.31 L112.40,243.00 L115.19,235.78 L118.23,228.67 L121.52,221.66 L125.05,214.78 L128.82,208.02 L132.82,201.40 L137.04,194.93 L141.49,188.60 L146.16,182.44 L151.04,176.45 L156.13,170.63 L161.41,164.99 L166.89,159.54 L172.56,154.28 L178.40,149.23 L184.42,144.39 L190.60,139.76 L196.94,135.35 L203.43,131.16 L210.06,127.21 L216.83,123.49 L223.72,120.00 L230.73,116.77 L237.85,113.78 L245.06,111.04 L252.37,108.56 L259.77,106.33 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.35" stroke-width="0.7"/><path d="M372.77,535.64 L365.67,537.24 L358.51,538.57 L351.30,539.64 L344.06,540.44 L336.78,540.97 L329.49,541.23 L322.18,541.23 L314.87,540.95 L307.57,540.41 L300.28,539.59 L293.02,538.51 L285.79,537.16 L278.60,535.55 L271.46,533.68 L264.38,531.54 L257.37,529.15 L250.44,526.50 L243.59,523.60 L236.83,520.45 L230.17,517.06 L223.63,513.43 L217.20,509.56 L210.90,505.46 L204.72,501.14 L198.69,496.60 L192.81,491.83 L187.08,486.87 L181.52,481.69 L176.12,476.32 L170.90,470.76 L165.86,465.02 L161.01,459.10 L156.35,453.01 L151.89,446.76 L147.64,440.35 L143.59,433.80 L139.76,427.10 L136.15,420.28 L132.77,413.34 L129.61,406.28 L126.68,399.12 L123.99,391.86 L121.54,384.51 L119.33,377.08 L117.37,369.59 L115.65,362.03 L114.18,354.42 L112.96,346.78 L112.00,339.09 L111.28,331.39 L110.82,323.67 L110.62,315.95 L110.67,308.23 L110.98,300.53 L111.54,292.84 L112.35,285.20 L113.42,277.59 L114.74,270.04 L116.31,262.55 L118.13,255.13 L120.19,247.78 L122.50,240.53 L125.05,233.37 L127.83,226.32 L130.85,219.38 L134.10,212.56 L137.58,205.88 L141.28,199.33 L145.20,192.93 L149.33,186.69 L153.66,180.60 L158.20,174.69 L162.94,168.96 L167.87,163.41 L172.98,158.05 L178.28,152.88 L183.74,147.92 L189.37,143.17 L195.17,138.64 L201.11,134.33 L207.20,130.24 L213.42,126.38 L219.78,122.76 L226.25,119.38 L232.84,116.25 L239.54,113.36 L246.34,110.73 L253.22,108.35 L260.19,106.22 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.35" stroke-width="0.7"/><path d="M372.77,535.64 L366.57,537.01 L360.32,538.13 L354.02,538.97 L347.67,539.55 L341.30,539.87 L334.89,539.91 L328.47,539.69 L322.04,539.20 L315.60,538.44 L309.17,537.42 L302.76,536.13 L296.36,534.58 L290.00,532.76 L283.67,530.69 L277.38,528.36 L271.15,525.78 L264.97,522.94 L258.87,519.86 L252.83,516.54 L246.88,512.97 L241.02,509.17 L235.26,505.14 L229.59,500.89 L224.04,496.41 L218.61,491.72 L213.29,486.82 L208.11,481.72 L203.07,476.42 L198.17,470.93 L193.41,465.25 L188.81,459.40 L184.37,453.38 L180.10,447.20 L175.99,440.86 L172.06,434.37 L168.31,427.75 L164.75,420.99 L161.37,414.11 L158.19,407.12 L155.21,400.01 L152.42,392.82 L149.84,385.53 L147.47,378.16 L145.31,370.73 L143.36,363.23 L141.63,355.67 L140.11,348.08 L138.81,340.45 L137.74,332.80 L136.88,325.12 L136.25,317.45 L135.84,309.78 L135.66,302.11 L135.70,294.48 L135.96,286.87 L136.45,279.30 L137.17,271.78 L138.10,264.32 L139.26,256.93 L140.64,249.62 L142.24,242.39 L144.05,235.25 L146.08,228.22 L148.32,221.30 L150.77,214.50 L153.42,207.83 L156.28,201.30 L159.34,194.91 L162.59,188.67 L166.03,182.60 L169.67,176.69 L173.48,170.95 L177.48,165.40 L181.64,160.04 L185.98,154.87 L190.48,149.90 L195.14,145.14 L199.95,140.59 L204.90,136.26 L210.00,132.15 L215.23,128.27 L220.59,124.63 L226.06,121.23 L231.66,118.06 L237.36,115.15 L243.16,112.48 L249.06,110.06 L255.04,107.90 L261.10,106.00 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.35" stroke-width="0.7"/><path d="M372.77,535.64 L367.90,536.69 L362.97,537.48 L357.99,538.00 L352.97,538.26 L347.90,538.25 L342.80,537.98 L337.67,537.44 L332.52,536.63 L327.35,535.56 L322.18,534.23 L317.00,532.64 L311.83,530.79 L306.67,528.68 L301.52,526.32 L296.40,523.71 L291.30,520.85 L286.24,517.74 L281.22,514.39 L276.25,510.81 L271.33,506.99 L266.47,502.95 L261.67,498.68 L256.95,494.19 L252.30,489.50 L247.74,484.59 L243.26,479.49 L238.88,474.19 L234.60,468.70 L230.42,463.04 L226.35,457.19 L222.39,451.18 L218.55,445.02 L214.84,438.69 L211.25,432.23 L207.80,425.63 L204.48,418.90 L201.31,412.04 L198.27,405.08 L195.39,398.01 L192.66,390.85 L190.08,383.60 L187.67,376.27 L185.41,368.88 L183.32,361.42 L181.39,353.92 L179.63,346.37 L178.05,338.80 L176.63,331.19 L175.40,323.58 L174.33,315.96 L173.45,308.35 L172.74,300.75 L172.22,293.17 L171.87,285.62 L171.70,278.12 L171.72,270.67 L171.91,263.28 L172.29,255.96 L172.84,248.71 L173.58,241.56 L174.49,234.50 L175.58,227.54 L176.85,220.69 L178.29,213.97 L179.90,207.38 L181.68,200.92 L183.64,194.61 L185.75,188.45 L188.04,182.45 L190.48,176.62 L193.08,170.96 L195.84,165.48 L198.74,160.20 L201.80,155.10 L205.00,150.21 L208.33,145.53 L211.81,141.06 L215.41,136.80 L219.15,132.77 L223.01,128.97 L226.98,125.40 L231.07,122.07 L235.27,118.97 L239.56,116.13 L243.96,113.53 L248.45,111.18 L253.03,109.09 L257.69,107.25 L262.42,105.68 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.35" stroke-width="0.7"/><path d="M372.77,535.64 L369.56,536.28 L366.28,536.67 L362.96,536.79 L359.57,536.64 L356.14,536.23 L352.67,535.56 L349.16,534.63 L345.61,533.43 L342.03,531.97 L338.42,530.26 L334.79,528.29 L331.14,526.07 L327.48,523.59 L323.81,520.87 L320.13,517.90 L316.46,514.69 L312.79,511.24 L309.13,507.56 L305.48,503.65 L301.85,499.52 L298.24,495.17 L294.65,490.61 L291.10,485.84 L287.59,480.86 L284.11,475.69 L280.68,470.33 L277.29,464.79 L273.96,459.07 L270.68,453.18 L267.46,447.13 L264.31,440.93 L261.22,434.57 L258.21,428.08 L255.27,421.46 L252.41,414.71 L249.63,407.85 L246.94,400.88 L244.34,393.81 L241.83,386.65 L239.42,379.41 L237.10,372.10 L234.88,364.72 L232.77,357.29 L230.77,349.81 L228.87,342.30 L227.08,334.76 L225.41,327.21 L223.85,319.64 L222.41,312.07 L221.09,304.52 L219.89,296.98 L218.81,289.47 L217.85,282.00 L217.02,274.57 L216.32,267.20 L215.74,259.90 L215.28,252.67 L214.96,245.52 L214.76,238.46 L214.69,231.50 L214.75,224.64 L214.94,217.91 L215.26,211.29 L215.70,204.81 L216.27,198.48 L216.97,192.28 L217.79,186.25 L218.73,180.38 L219.80,174.67 L221.00,169.15 L222.31,163.81 L223.74,158.65 L225.29,153.70 L226.96,148.95 L228.73,144.40 L230.62,140.07 L232.62,135.96 L234.73,132.08 L236.93,128.42 L239.24,125.00 L241.65,121.81 L244.15,118.86 L246.75,116.16 L249.44,113.71 L252.21,111.51 L255.06,109.57 L257.99,107.88 L261.00,106.44 L264.08,105.27 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.35" stroke-width="0.7"/><path d="M372.77,535.64 L371.43,535.83 L370.03,535.75 L368.57,535.41 L367.05,534.81 L365.47,533.95 L363.83,532.83 L362.14,531.45 L360.40,529.81 L358.62,527.91 L356.78,525.77 L354.90,523.37 L352.98,520.72 L351.01,517.83 L349.01,514.70 L346.98,511.33 L344.91,507.73 L342.81,503.90 L340.68,499.84 L338.53,495.57 L336.35,491.08 L334.16,486.38 L331.95,481.48 L329.72,476.39 L327.48,471.10 L325.24,465.63 L322.98,459.98 L320.72,454.16 L318.47,448.18 L316.21,442.04 L313.96,435.75 L311.71,429.33 L309.48,422.77 L307.26,416.08 L305.05,409.28 L302.86,402.36 L300.69,395.35 L298.55,388.25 L296.43,381.06 L294.34,373.80 L292.29,366.47 L290.26,359.09 L288.28,351.65 L286.33,344.18 L284.42,336.68 L282.56,329.16 L280.74,321.63 L278.97,314.10 L277.24,306.57 L275.58,299.06 L273.96,291.58 L272.40,284.13 L270.90,276.72 L269.46,269.37 L268.08,262.08 L266.76,254.86 L265.51,247.72 L264.33,240.66 L263.21,233.71 L262.16,226.86 L261.19,220.12 L260.28,213.50 L259.45,207.01 L258.69,200.67 L258.00,194.46 L257.40,188.41 L256.86,182.52 L256.41,176.80 L256.03,171.25 L255.73,165.88 L255.51,160.70 L255.36,155.72 L255.30,150.93 L255.31,146.35 L255.41,141.99 L255.58,137.83 L255.83,133.91 L256.16,130.20 L256.56,126.73 L257.05,123.50 L257.61,120.50 L258.24,117.75 L258.95,115.24 L259.74,112.99 L260.60,110.98 L261.53,109.23 L262.53,107.74 L263.61,106.50 L264.75,105.53 L265.96,104.81 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.35" stroke-width="0.7"/><path d="M372.77,535.64 L373.39,535.35 L373.95,534.79 L374.45,533.98 L374.87,532.90 L375.23,531.56 L375.52,529.97 L375.75,528.12 L375.91,526.02 L375.99,523.66 L376.02,521.06 L375.97,518.21 L375.85,515.12 L375.67,511.80 L375.42,508.24 L375.10,504.45 L374.71,500.43 L374.26,496.20 L373.74,491.75 L373.15,487.09 L372.50,482.23 L371.79,477.17 L371.01,471.92 L370.18,466.49 L369.28,460.87 L368.32,455.09 L367.30,449.14 L366.22,443.03 L365.09,436.77 L363.90,430.37 L362.66,423.84 L361.37,417.17 L360.02,410.40 L358.63,403.51 L357.19,396.51 L355.71,389.43 L354.18,382.26 L352.61,375.02 L351.00,367.70 L349.35,360.33 L347.67,352.92 L345.96,345.46 L344.21,337.97 L342.43,330.45 L340.62,322.93 L338.79,315.40 L336.94,307.88 L335.07,300.37 L333.18,292.89 L331.27,285.43 L329.35,278.03 L327.41,270.67 L325.47,263.37 L323.52,256.14 L321.57,248.99 L319.61,241.93 L317.66,234.96 L315.71,228.09 L313.76,221.34 L311.82,214.70 L309.89,208.20 L307.97,201.83 L306.07,195.60 L304.19,189.53 L302.32,183.62 L300.48,177.87 L298.66,172.29 L296.86,166.90 L295.10,161.69 L293.36,156.67 L291.66,151.86 L289.99,147.24 L288.36,142.84 L286.76,138.66 L285.21,134.69 L283.70,130.95 L282.23,127.44 L280.81,124.17 L279.44,121.14 L278.11,118.34 L276.84,115.79 L275.62,113.50 L274.45,111.45 L273.34,109.66 L272.29,108.12 L271.30,106.84 L270.36,105.82 L269.48,105.06 L268.67,104.57 L267.92,104.33 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.35" stroke-width="0.7"/><path d="M372.77,535.64 L375.31,534.88 L377.79,533.85 L380.19,532.57 L382.52,531.03 L384.78,529.23 L386.95,527.17 L389.04,524.87 L391.05,522.31 L392.98,519.51 L394.81,516.46 L396.56,513.17 L398.21,509.65 L399.76,505.90 L401.22,501.92 L402.58,497.72 L403.83,493.31 L404.99,488.68 L406.04,483.85 L406.99,478.81 L407.83,473.59 L408.57,468.17 L409.19,462.58 L409.71,456.81 L410.12,450.88 L410.42,444.78 L410.61,438.54 L410.68,432.15 L410.65,425.62 L410.51,418.96 L410.26,412.19 L409.89,405.30 L409.42,398.31 L408.84,391.22 L408.15,384.04 L407.35,376.79 L406.45,369.47 L405.44,362.09 L404.33,354.66 L403.11,347.18 L401.80,339.67 L400.38,332.14 L398.86,324.59 L397.25,317.04 L395.55,309.49 L393.75,301.95 L391.87,294.44 L389.89,286.95 L387.83,279.51 L385.69,272.12 L383.47,264.78 L381.17,257.51 L378.80,250.32 L376.35,243.21 L373.84,236.20 L371.26,229.29 L368.61,222.49 L365.91,215.80 L363.16,209.25 L360.35,202.83 L357.49,196.55 L354.58,190.42 L351.63,184.45 L348.65,178.65 L345.63,173.02 L342.58,167.57 L339.50,162.30 L336.40,157.22 L333.27,152.35 L330.13,147.67 L326.98,143.21 L323.82,138.96 L320.66,134.94 L317.49,131.14 L314.33,127.57 L311.18,124.23 L308.03,121.13 L304.90,118.27 L301.79,115.66 L298.70,113.30 L295.64,111.19 L292.60,109.34 L289.60,107.74 L286.64,106.40 L283.72,105.32 L280.84,104.50 L278.01,103.95 L275.23,103.66 L272.50,103.63 L269.84,103.86 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.35" stroke-width="0.7"/><path d="M372.77,535.64 L377.05,534.45 L381.27,533.00 L385.41,531.29 L389.47,529.33 L393.45,527.11 L397.33,524.63 L401.12,521.91 L404.82,518.94 L408.41,515.73 L411.89,512.28 L415.26,508.60 L418.51,504.68 L421.65,500.54 L424.66,496.19 L427.54,491.61 L430.29,486.83 L432.91,481.85 L435.39,476.66 L437.73,471.29 L439.93,465.73 L441.98,460.00 L443.88,454.09 L445.63,448.02 L447.23,441.80 L448.67,435.42 L449.95,428.91 L451.08,422.26 L452.05,415.49 L452.85,408.60 L453.50,401.61 L453.98,394.51 L454.30,387.32 L454.45,380.06 L454.45,372.72 L454.27,365.31 L453.94,357.85 L453.44,350.34 L452.78,342.80 L451.95,335.23 L450.97,327.64 L449.82,320.04 L448.52,312.44 L447.06,304.85 L445.45,297.28 L443.68,289.73 L441.77,282.23 L439.70,274.76 L437.49,267.36 L435.14,260.02 L432.64,252.75 L430.01,245.56 L427.24,238.46 L424.35,231.47 L421.32,224.58 L418.18,217.81 L414.91,211.16 L411.53,204.64 L408.03,198.27 L404.43,192.04 L400.73,185.97 L396.93,180.06 L393.03,174.32 L389.05,168.76 L384.98,163.39 L380.83,158.20 L376.61,153.22 L372.31,148.43 L367.96,143.86 L363.55,139.50 L359.08,135.36 L354.56,131.44 L350.01,127.76 L345.42,124.30 L340.79,121.09 L336.14,118.12 L331.47,115.39 L326.79,112.92 L322.10,110.69 L317.41,108.73 L312.71,107.02 L308.03,105.56 L303.37,104.37 L298.72,103.45 L294.10,102.78 L289.51,102.38 L284.96,102.25 L280.45,102.38 L275.99,102.78 L271.58,103.44 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.35" stroke-width="0.7"/><path d="M372.77,535.64 L378.50,534.09 L384.16,532.29 L389.75,530.23 L395.25,527.91 L400.65,525.34 L405.96,522.52 L411.16,519.45 L416.26,516.14 L421.23,512.59 L426.09,508.81 L430.81,504.79 L435.40,500.55 L439.84,496.09 L444.14,491.42 L448.29,486.54 L452.29,481.45 L456.12,476.17 L459.79,470.69 L463.28,465.04 L466.60,459.20 L469.75,453.20 L472.71,447.04 L475.48,440.72 L478.07,434.25 L480.46,427.64 L482.66,420.90 L484.66,414.04 L486.46,407.07 L488.05,399.99 L489.44,392.81 L490.63,385.54 L491.60,378.20 L492.37,370.78 L492.93,363.30 L493.27,355.77 L493.41,348.19 L493.33,340.58 L493.05,332.94 L492.55,325.29 L491.84,317.63 L490.92,309.98 L489.80,302.34 L488.47,294.72 L486.93,287.13 L485.19,279.58 L483.25,272.07 L481.10,264.63 L478.77,257.26 L476.24,249.96 L473.51,242.75 L470.61,235.63 L467.51,228.61 L464.24,221.70 L460.80,214.92 L457.18,208.26 L453.39,201.74 L449.44,195.36 L445.34,189.14 L441.08,183.07 L436.67,177.17 L432.12,171.45 L427.44,165.90 L422.62,160.55 L417.68,155.39 L412.62,150.42 L407.45,145.67 L402.17,141.13 L396.79,136.80 L391.32,132.70 L385.76,128.83 L380.12,125.19 L374.40,121.79 L368.62,118.62 L362.78,115.71 L356.89,113.04 L350.96,110.63 L344.98,108.47 L338.98,106.56 L332.95,104.92 L326.91,103.54 L320.86,102.43 L314.81,101.57 L308.76,100.99 L302.73,100.67 L296.72,100.62 L290.73,100.84 L284.79,101.32 L278.88,102.07 L273.03,103.08 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.35" stroke-width="0.7"/><path d="M372.77,535.64 L379.56,533.84 L386.27,531.78 L392.91,529.46 L399.46,526.88 L405.90,524.06 L412.25,520.98 L418.48,517.66 L424.59,514.10 L430.58,510.30 L436.43,506.28 L442.14,502.02 L447.70,497.54 L453.10,492.85 L458.34,487.94 L463.42,482.83 L468.32,477.53 L473.03,472.03 L477.56,466.34 L481.90,460.48 L486.05,454.45 L489.99,448.25 L493.72,441.89 L497.24,435.39 L500.55,428.75 L503.63,421.97 L506.49,415.07 L509.13,408.06 L511.53,400.93 L513.70,393.71 L515.64,386.40 L517.33,379.01 L518.79,371.54 L520.00,364.02 L520.97,356.44 L521.70,348.81 L522.18,341.15 L522.41,333.46 L522.39,325.76 L522.13,318.05 L521.63,310.35 L520.88,302.65 L519.88,294.98 L518.64,287.33 L517.16,279.73 L515.43,272.17 L513.47,264.68 L511.28,257.25 L508.85,249.90 L506.19,242.63 L503.30,235.46 L500.19,228.39 L496.86,221.43 L493.32,214.59 L489.56,207.88 L485.60,201.31 L481.43,194.88 L477.07,188.60 L472.52,182.49 L467.78,176.54 L462.87,170.76 L457.77,165.17 L452.51,159.77 L447.09,154.56 L441.52,149.55 L435.79,144.75 L429.93,140.17 L423.93,135.80 L417.80,131.66 L411.55,127.75 L405.20,124.07 L398.74,120.63 L392.18,117.43 L385.54,114.48 L378.81,111.79 L372.02,109.34 L365.16,107.15 L358.24,105.22 L351.28,103.55 L344.28,102.15 L337.25,101.01 L330.21,100.14 L323.14,99.53 L316.08,99.20 L309.02,99.13 L301.97,99.33 L294.94,99.81 L287.95,100.55 L280.99,101.55 L274.08,102.83 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.35" stroke-width="0.7"/><path d="M372.77,535.64 L380.15,533.69 L387.45,531.49 L394.68,529.02 L401.81,526.31 L408.84,523.34 L415.77,520.12 L422.58,516.66 L429.26,512.96 L435.81,509.02 L442.22,504.86 L448.48,500.47 L454.58,495.86 L460.52,491.03 L466.29,486.00 L471.88,480.76 L477.29,475.33 L482.50,469.71 L487.51,463.91 L492.33,457.93 L496.93,451.78 L501.31,445.48 L505.48,439.02 L509.42,432.41 L513.13,425.67 L516.60,418.80 L519.83,411.81 L522.82,404.71 L525.56,397.50 L528.06,390.20 L530.30,382.81 L532.28,375.35 L534.00,367.82 L535.46,360.23 L536.67,352.59 L537.60,344.92 L538.27,337.21 L538.68,329.48 L538.82,321.74 L538.69,314.00 L538.30,306.27 L537.64,298.55 L536.71,290.86 L535.52,283.20 L534.07,275.59 L532.36,268.03 L530.39,260.54 L528.16,253.12 L525.68,245.78 L522.95,238.53 L519.97,231.38 L516.75,224.33 L513.29,217.41 L509.59,210.61 L505.66,203.94 L501.51,197.41 L497.13,191.04 L492.54,184.82 L487.74,178.76 L482.73,172.88 L477.53,167.18 L472.13,161.66 L466.55,156.33 L460.79,151.21 L454.85,146.29 L448.76,141.58 L442.50,137.09 L436.10,132.82 L429.56,128.78 L422.88,124.98 L416.08,121.41 L409.16,118.08 L402.13,115.00 L395.00,112.17 L387.78,109.59 L380.48,107.27 L373.10,105.21 L365.66,103.41 L358.17,101.87 L350.62,100.60 L343.04,99.59 L335.44,98.86 L327.81,98.39 L320.17,98.20 L312.54,98.27 L304.91,98.61 L297.30,99.23 L289.72,100.11 L282.17,101.26 L274.67,102.68 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.35" stroke-width="0.7"/><path d="M372.77,535.64 L380.23,533.67 L387.63,531.44 L394.94,528.96 L402.15,526.22 L409.27,523.23 L416.28,520.00 L423.17,516.51 L429.94,512.79 L436.57,508.84 L443.06,504.65 L449.40,500.24 L455.58,495.61 L461.60,490.77 L467.44,485.72 L473.11,480.46 L478.59,475.01 L483.87,469.37 L488.96,463.55 L493.84,457.56 L498.51,451.40 L502.96,445.07 L507.18,438.60 L511.18,431.98 L514.95,425.22 L518.48,418.34 L521.77,411.33 L524.81,404.22 L527.60,397.00 L530.14,389.69 L532.42,382.29 L534.45,374.82 L536.21,367.28 L537.71,359.68 L538.94,352.04 L539.91,344.35 L540.61,336.64 L541.04,328.90 L541.20,321.16 L541.09,313.41 L540.72,305.67 L540.07,297.95 L539.16,290.26 L537.97,282.60 L536.53,274.99 L534.82,267.43 L532.84,259.94 L530.61,252.52 L528.12,245.18 L525.38,237.93 L522.39,230.78 L519.15,223.75 L515.67,216.83 L511.95,210.03 L508.00,203.37 L503.81,196.85 L499.41,190.48 L494.78,184.27 L489.94,178.22 L484.90,172.35 L479.65,166.66 L474.21,161.15 L468.58,155.84 L462.77,150.72 L456.79,145.82 L450.64,141.12 L444.33,136.64 L437.87,132.39 L431.26,128.37 L424.52,124.57 L417.66,121.02 L410.67,117.71 L403.57,114.65 L396.38,111.83 L389.08,109.27 L381.71,106.97 L374.26,104.92 L366.74,103.14 L359.17,101.62 L351.54,100.37 L343.88,99.39 L336.19,98.67 L328.49,98.23 L320.77,98.05 L313.05,98.15 L305.33,98.51 L297.64,99.15 L289.97,100.05 L282.34,101.22 L274.76,102.66 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.09" stroke-width="0.7"/><path d="M372.77,535.64 L379.81,533.78 L386.78,531.65 L393.66,529.27 L400.46,526.64 L407.16,523.75 L413.75,520.62 L420.22,517.24 L426.58,513.62 L432.80,509.76 L438.89,505.67 L444.83,501.36 L450.63,496.83 L456.26,492.08 L461.72,487.12 L467.02,481.95 L472.13,476.59 L477.06,471.04 L481.80,465.31 L486.34,459.40 L490.67,453.31 L494.80,447.07 L498.72,440.67 L502.42,434.12 L505.90,427.44 L509.15,420.62 L512.17,413.68 L514.95,406.63 L517.50,399.47 L519.81,392.22 L521.87,384.87 L523.69,377.45 L525.26,369.96 L526.58,362.41 L527.65,354.80 L528.46,347.16 L529.02,339.47 L529.33,331.77 L529.38,324.05 L529.18,316.33 L528.72,308.61 L528.00,300.91 L527.04,293.22 L525.82,285.58 L524.35,277.97 L522.63,270.41 L520.67,262.92 L518.46,255.49 L516.01,248.14 L513.32,240.88 L510.39,233.72 L507.23,226.66 L503.85,219.72 L500.24,212.90 L496.41,206.20 L492.36,199.65 L488.11,193.24 L483.65,186.99 L478.99,180.90 L474.14,174.98 L469.10,169.24 L463.88,163.68 L458.48,158.31 L452.92,153.13 L447.19,148.17 L441.31,143.40 L435.28,138.86 L429.10,134.54 L422.80,130.44 L416.37,126.57 L409.83,122.94 L403.17,119.55 L396.41,116.40 L389.56,113.50 L382.63,110.85 L375.62,108.46 L368.54,106.32 L361.40,104.45 L354.21,102.84 L346.98,101.49 L339.72,100.41 L332.43,99.59 L325.13,99.05 L317.82,98.77 L310.51,98.77 L303.22,99.03 L295.94,99.56 L288.70,100.36 L281.49,101.43 L274.33,102.76 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.09" stroke-width="0.7"/><path d="M372.77,535.64 L378.90,534.00 L384.96,532.10 L390.94,529.94 L396.84,527.52 L402.64,524.85 L408.34,521.94 L413.94,518.77 L419.41,515.37 L424.77,511.73 L430.00,507.85 L435.10,503.74 L440.05,499.41 L444.86,494.86 L449.52,490.10 L454.02,485.13 L458.36,479.96 L462.52,474.60 L466.52,469.05 L470.33,463.31 L473.97,457.40 L477.41,451.33 L480.66,445.09 L483.72,438.70 L486.58,432.17 L489.23,425.50 L491.68,418.70 L493.92,411.78 L495.95,404.75 L497.76,397.61 L499.36,390.38 L500.74,383.07 L501.90,375.68 L502.83,368.22 L503.55,360.70 L504.04,353.13 L504.30,345.52 L504.34,337.89 L504.16,330.22 L503.75,322.55 L503.12,314.88 L502.26,307.20 L501.19,299.55 L499.89,291.92 L498.37,284.33 L496.64,276.77 L494.69,269.27 L492.53,261.84 L490.16,254.47 L487.58,247.18 L484.79,239.99 L481.81,232.88 L478.63,225.89 L475.25,219.01 L471.69,212.25 L467.94,205.63 L464.01,199.14 L459.90,192.80 L455.63,186.62 L451.19,180.60 L446.59,174.75 L441.83,169.07 L436.93,163.58 L431.89,158.28 L426.71,153.18 L421.39,148.28 L415.96,143.59 L410.41,139.11 L404.74,134.86 L398.98,130.83 L393.12,127.03 L387.17,123.46 L381.13,120.14 L375.03,117.06 L368.85,114.22 L362.62,111.64 L356.33,109.31 L350.00,107.24 L343.64,105.42 L337.24,103.87 L330.83,102.58 L324.40,101.56 L317.96,100.80 L311.53,100.31 L305.11,100.09 L298.70,100.13 L292.33,100.45 L285.98,101.03 L279.68,101.87 L273.43,102.99 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.09" stroke-width="0.7"/><path d="M372.77,535.64 L377.58,534.32 L382.31,532.75 L386.97,530.91 L391.55,528.82 L396.04,526.47 L400.44,523.87 L404.73,521.03 L408.93,517.93 L413.02,514.60 L416.99,511.03 L420.85,507.23 L424.59,503.20 L428.19,498.94 L431.67,494.47 L435.00,489.79 L438.20,484.90 L441.26,479.80 L444.16,474.52 L446.92,469.04 L449.52,463.38 L451.96,457.55 L454.25,451.55 L456.36,445.39 L458.32,439.08 L460.10,432.62 L461.71,426.03 L463.15,419.31 L464.42,412.46 L465.51,405.50 L466.42,398.44 L467.16,391.29 L467.71,384.04 L468.09,376.72 L468.28,369.33 L468.30,361.88 L468.13,354.38 L467.78,346.83 L467.26,339.25 L466.55,331.65 L465.67,324.04 L464.60,316.42 L463.37,308.81 L461.95,301.20 L460.37,293.63 L458.61,286.08 L456.68,278.58 L454.59,271.12 L452.33,263.73 L449.92,256.40 L447.34,249.15 L444.61,241.99 L441.73,234.92 L438.69,227.96 L435.52,221.10 L432.20,214.37 L428.75,207.77 L425.16,201.31 L421.45,194.98 L417.61,188.82 L413.65,182.81 L409.58,176.96 L405.40,171.30 L401.12,165.81 L396.74,160.51 L392.26,155.41 L387.70,150.50 L383.05,145.81 L378.33,141.32 L373.53,137.05 L368.67,133.01 L363.75,129.19 L358.78,125.61 L353.76,122.26 L348.70,119.15 L343.60,116.29 L338.48,113.68 L333.33,111.32 L328.17,109.21 L323.00,107.36 L317.82,105.77 L312.65,104.44 L307.48,103.37 L302.33,102.56 L297.20,102.02 L292.10,101.75 L287.03,101.74 L282.01,102.00 L277.03,102.52 L272.10,103.31 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.09" stroke-width="0.7"/><path d="M372.77,535.64 L375.92,534.73 L379.00,533.56 L382.01,532.12 L384.94,530.43 L387.79,528.49 L390.56,526.29 L393.25,523.84 L395.85,521.14 L398.35,518.19 L400.76,515.00 L403.07,511.58 L405.27,507.92 L407.38,504.04 L409.38,499.93 L411.27,495.60 L413.04,491.05 L414.71,486.30 L416.26,481.35 L417.69,476.19 L419.00,470.85 L420.20,465.33 L421.27,459.62 L422.21,453.75 L423.03,447.72 L423.73,441.52 L424.30,435.19 L424.74,428.71 L425.06,422.09 L425.25,415.36 L425.31,408.50 L425.24,401.54 L425.04,394.48 L424.72,387.33 L424.26,380.10 L423.68,372.80 L422.98,365.43 L422.15,358.00 L421.19,350.53 L420.11,343.02 L418.91,335.48 L417.59,327.93 L416.15,320.36 L414.59,312.79 L412.92,305.24 L411.13,297.70 L409.23,290.19 L407.23,282.71 L405.12,275.28 L402.90,267.90 L400.58,260.59 L398.17,253.35 L395.66,246.19 L393.06,239.12 L390.37,232.15 L387.59,225.29 L384.73,218.54 L381.79,211.92 L378.78,205.43 L375.69,199.07 L372.54,192.87 L369.32,186.82 L366.04,180.93 L362.71,175.21 L359.32,169.67 L355.89,164.31 L352.41,159.14 L348.90,154.16 L345.35,149.39 L341.76,144.83 L338.15,140.48 L334.52,136.35 L330.87,132.44 L327.21,128.76 L323.54,125.31 L319.87,122.10 L316.19,119.13 L312.52,116.41 L308.86,113.93 L305.21,111.71 L301.58,109.74 L297.97,108.03 L294.39,106.57 L290.84,105.37 L287.33,104.44 L283.86,103.77 L280.43,103.36 L277.04,103.21 L273.72,103.33 L270.44,103.72 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.09" stroke-width="0.7"/><path d="M372.77,535.64 L374.04,535.19 L375.25,534.47 L376.39,533.50 L377.47,532.26 L378.47,530.77 L379.40,529.02 L380.26,527.01 L381.05,524.76 L381.76,522.25 L382.39,519.50 L382.95,516.50 L383.44,513.27 L383.84,509.80 L384.17,506.09 L384.42,502.17 L384.59,498.01 L384.69,493.65 L384.70,489.07 L384.64,484.28 L384.49,479.30 L384.27,474.12 L383.97,468.75 L383.59,463.20 L383.14,457.48 L382.60,451.59 L382.00,445.54 L381.31,439.33 L380.55,432.99 L379.72,426.50 L378.81,419.88 L377.84,413.14 L376.79,406.29 L375.67,399.34 L374.49,392.28 L373.24,385.14 L371.92,377.92 L370.54,370.63 L369.10,363.28 L367.60,355.87 L366.04,348.42 L364.42,340.94 L362.76,333.43 L361.03,325.90 L359.26,318.37 L357.44,310.84 L355.58,303.32 L353.67,295.82 L351.72,288.35 L349.74,280.91 L347.71,273.53 L345.66,266.20 L343.57,258.94 L341.45,251.75 L339.31,244.65 L337.14,237.64 L334.95,230.72 L332.74,223.92 L330.52,217.23 L328.29,210.67 L326.04,204.25 L323.79,197.96 L321.53,191.82 L319.28,185.84 L317.02,180.02 L314.76,174.37 L312.52,168.90 L310.28,163.61 L308.05,158.52 L305.84,153.62 L303.65,148.92 L301.47,144.43 L299.32,140.16 L297.19,136.10 L295.09,132.27 L293.02,128.67 L290.99,125.30 L288.99,122.17 L287.02,119.28 L285.10,116.63 L283.22,114.23 L281.38,112.09 L279.60,110.19 L277.86,108.55 L276.17,107.17 L274.53,106.05 L272.95,105.19 L271.43,104.59 L269.97,104.25 L268.57,104.17 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.09" stroke-width="0.7"/><path d="M372.77,535.64 L372.08,535.67 L371.33,535.43 L370.52,534.94 L369.64,534.18 L368.70,533.16 L367.71,531.88 L366.66,530.34 L365.55,528.55 L364.38,526.50 L363.16,524.21 L361.89,521.66 L360.56,518.86 L359.19,515.83 L357.77,512.56 L356.30,509.05 L354.79,505.31 L353.24,501.34 L351.64,497.16 L350.01,492.76 L348.34,488.14 L346.64,483.33 L344.90,478.31 L343.14,473.10 L341.34,467.71 L339.52,462.13 L337.68,456.38 L335.81,450.47 L333.93,444.40 L332.03,438.17 L330.11,431.80 L328.18,425.30 L326.24,418.66 L324.29,411.91 L322.34,405.04 L320.39,398.07 L318.43,391.01 L316.48,383.86 L314.53,376.63 L312.59,369.33 L310.65,361.97 L308.73,354.57 L306.82,347.11 L304.93,339.63 L303.06,332.12 L301.21,324.60 L299.38,317.07 L297.57,309.55 L295.79,302.03 L294.04,294.54 L292.33,287.08 L290.65,279.67 L289.00,272.30 L287.39,264.98 L285.82,257.74 L284.29,250.57 L282.81,243.49 L281.37,236.49 L279.98,229.60 L278.63,222.83 L277.34,216.16 L276.10,209.63 L274.91,203.23 L273.78,196.97 L272.70,190.86 L271.68,184.91 L270.72,179.13 L269.82,173.51 L268.99,168.08 L268.21,162.83 L267.50,157.77 L266.85,152.91 L266.26,148.25 L265.74,143.80 L265.29,139.57 L264.90,135.55 L264.58,131.76 L264.33,128.20 L264.15,124.88 L264.03,121.79 L263.98,118.94 L264.01,116.34 L264.09,113.98 L264.25,111.88 L264.48,110.03 L264.77,108.44 L265.13,107.10 L265.55,106.02 L266.05,105.21 L266.61,104.65 L267.23,104.36" fill="none" stroke="#acb49f" stroke-opacity="0.09" stroke-width="0.7"/></g><path d="M101.28,276.50 L99.80,287.89 L99.15,303.10 L103.51,305.86 L110.60,292.72 L114.97,276.80 L117.22,254.83 L127.87,252.23 L144.68,224.74 L171.09,196.96 L199.56,178.86 L195.28,164.79 L197.51,151.15 L192.68,143.09 L197.23,134.31" fill="none" stroke="#c3c9b9" stroke-opacity="0.55" stroke-width="1"/><path d="M123.67,320.31 L132.73,333.88 L154.78,320.56 L175.34,327.42 L211.70,346.50 L268.77,352.55 L265.60,392.73 L267.88,418.76 L252.71,451.26 L243.04,486.40 L268.27,518.39 L245.04,511.61 L200.72,463.98 L165.82,424.85 L135.89,385.06 L123.67,320.31" fill="none" stroke="#c3c9b9" stroke-opacity="0.55" stroke-width="1"/><path d="M332.52,185.25 L374.59,168.47 L421.80,173.43 L440.98,172.15 L490.91,214.89 L509.69,229.77 L511.25,273.20 L514.51,320.13 L498.72,376.91 L462.07,416.92 L454.58,394.85 L444.95,352.70 L435.76,311.68 L419.99,275.52 L382.06,284.80 L329.39,277.84 L310.65,236.28 L332.52,185.25" fill="none" stroke="#c3c9b9" stroke-opacity="0.55" stroke-width="1"/><path d="M322.28,184.50 L312.91,162.26 L318.12,149.85 L331.55,141.30 L334.91,128.29 L323.56,124.43 L321.94,114.97 L322.57,103.64 L346.95,105.34 L357.06,112.11 L382.46,112.17 L405.76,118.10 L421.33,132.86 L423.94,140.95 L408.60,147.70 L405.94,157.63 L372.55,147.66 L363.06,152.89 L378.72,158.06 L345.75,157.13 L322.28,184.50" fill="none" stroke="#c3c9b9" stroke-opacity="0.55" stroke-width="1"/><path d="M228.32,143.61 L256.76,122.61 L268.15,108.13 L258.36,107.22 L237.44,115.64 L223.45,135.56 L228.32,143.61" fill="none" stroke="#c3c9b9" stroke-opacity="0.55" stroke-width="1"/><path d="M315.43,145.25 L306.64,135.21 L308.61,128.09 L320.66,134.10 L315.43,145.25" fill="none" stroke="#c3c9b9" stroke-opacity="0.55" stroke-width="1"/><path d="M382.46,112.17 L349.23,99.98" fill="none" stroke="#c3c9b9" stroke-opacity="0.55" stroke-width="1"/><path d="M493.16,180.60 L467.43,169.13 L423.94,140.95" fill="none" stroke="#c3c9b9" stroke-opacity="0.55" stroke-width="1"/><path d="M528.96,320.51 L529.40,347.28 L520.32,368.00 L521.68,337.77 L528.96,320.51" fill="none" stroke="#c3c9b9" stroke-opacity="0.55" stroke-width="1"/><path d="M150.18 212.66 Q217.83 150.65 325.48 138.64" fill="none" stroke="#d3f56b" stroke-opacity=".5" stroke-width=".85"/><path d="M150.18 212.66 Q181.44 294.82 252.71 426.98" fill="none" stroke="#d3f56b" stroke-opacity=".5" stroke-width=".85"/><path d="M325.48 138.64 Q302.71 133.02 319.93 177.40" fill="none" stroke="#d3f56b" stroke-opacity=".5" stroke-width=".85"/><path d="M325.48 138.64 Q326.87 112.34 368.26 136.05" fill="none" stroke="#d3f56b" stroke-opacity=".5" stroke-width=".85"/><path d="M319.93 177.40 Q298.57 194.07 317.21 260.73" fill="none" stroke="#d3f56b" stroke-opacity=".5" stroke-width=".85"/><path d="M319.93 177.40 Q339.64 201.89 399.34 276.37" fill="none" stroke="#d3f56b" stroke-opacity=".5" stroke-width=".85"/><path d="M399.34 276.37 Q306.02 326.67 252.71 426.98" fill="none" stroke="#d3f56b" stroke-opacity=".5" stroke-width=".85"/><path d="M399.34 276.37 Q399.84 200.55 440.35 174.73" fill="none" stroke="#d3f56b" stroke-opacity=".5" stroke-width=".85"/><path d="M440.35 174.73 Q452.27 201.85 504.20 278.97" fill="none" stroke="#d3f56b" stroke-opacity=".5" stroke-width=".85"/><path d="M368.26 136.05 Q343.05 101.26 357.83 116.47" fill="none" stroke="#d3f56b" stroke-opacity=".5" stroke-width=".85"/><circle cx="150.18" cy="212.66" r="8" fill="#080909" stroke="#d3f56b" stroke-opacity=".6" stroke-width=".7"/><circle cx="150.18" cy="212.66" r="2.2" fill="#d3f56b"/><circle cx="325.48" cy="138.64" r="5" fill="#080909" stroke="#d3f56b" stroke-opacity=".6" stroke-width=".7"/><circle cx="325.48" cy="138.64" r="2.2" fill="#d3f56b"/><circle cx="319.93" cy="177.40" r="5" fill="#080909" stroke="#d3f56b" stroke-opacity=".6" stroke-width=".7"/><circle cx="319.93" cy="177.40" r="2.2" fill="#d3f56b"/><circle cx="252.71" cy="426.98" r="8" fill="#080909" stroke="#d3f56b" stroke-opacity=".6" stroke-width=".7"/><circle cx="252.71" cy="426.98" r="2.2" fill="#d3f56b"/><circle cx="399.34" cy="276.37" r="5" fill="#080909" stroke="#d3f56b" stroke-opacity=".6" stroke-width=".7"/><circle cx="399.34" cy="276.37" r="2.2" fill="#d3f56b"/><circle cx="440.35" cy="174.73" r="5" fill="#080909" stroke="#d3f56b" stroke-opacity=".6" stroke-width=".7"/><circle cx="440.35" cy="174.73" r="2.2" fill="#d3f56b"/><circle cx="368.26" cy="136.05" r="8" fill="#080909" stroke="#d3f56b" stroke-opacity=".6" stroke-width=".7"/><circle cx="368.26" cy="136.05" r="2.2" fill="#d3f56b"/><circle cx="357.83" cy="116.47" r="5" fill="#080909" stroke="#d3f56b" stroke-opacity=".6" stroke-width=".7"/><circle cx="357.83" cy="116.47" r="2.2" fill="#d3f56b"/><circle cx="317.21" cy="260.73" r="5" fill="#080909" stroke="#d3f56b" stroke-opacity=".6" stroke-width=".7"/><circle cx="317.21" cy="260.73" r="2.2" fill="#d3f56b"/><circle cx="504.20" cy="278.97" r="8" fill="#080909" stroke="#d3f56b" stroke-opacity=".6" stroke-width=".7"/><circle cx="504.20" cy="278.97" r="2.2" fill="#d3f56b"/><g fill="none" stroke="#8c9978" stroke-width=".65"><ellipse cx="320" cy="320" rx="295" ry="65" transform="rotate(-35 320 320)" opacity=".28"/><ellipse cx="320" cy="320" rx="265" ry="79" transform="rotate(63 320 320)" opacity=".18"/></g><g fill="#a8b199" font-family="monospace" font-size="8"><text x="110" y="181">01 / SIGNAL</text><text x="385" y="529">02 / CONTEXT</text></g></svg>
HX_SVG



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
AI_DOMAIN="$AI_DOMAIN"
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
    read_value AI_DOMAIN       "Dominio do site  (registro A -> IP da VPS)"
    read_value ALLOWED_ORIGINS "Origens CORS, separadas por virgula (vazio = nenhuma)"
    [ -n "${API_DOMAIN:-}" ] && [ -n "${DRIVE_DOMAIN:-}" ] && [ -n "${AI_DOMAIN:-}" ] || die "Preencha os dominios."
  else
    for v in ACME_EMAIL API_DOMAIN DRIVE_DOMAIN AI_DOMAIN; do
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
INSTALL_DIR="$INSTALL_DIR"
BACKEND="\$INSTALL_DIR/backend"
ENV_FILE="\$BACKEND/.env"
UPDATE_URL="\${HADIX_UPDATE_URL:-$UPDATE_URL_DEFAULT}"

cd "\$BACKEND"

require_root() {
  [ "\$(id -u)" -eq 0 ] || { echo "Execute com sudo." >&2; exit 1; }
}

case "\${1:-help}" in
  start)   require_root; docker compose up -d --build ;;
  stop)    require_root; docker compose down ;;
  restart) require_root; docker compose restart ;;
  status|ps) docker compose ps ;;
  logs)    docker compose logs -f --tail=200 "\${2:-api}" ;;
  env)     require_root; cat .env ;;
  model)
    require_root
    model=""
    [ -f "\$ENV_FILE" ] && model="\$(grep '^OLLAMA_MODEL=' "\$ENV_FILE" | head -1 | cut -d= -f2 | tr -d '\"' || true)"
    docker compose exec -T ollama ollama pull "\${2:-\${model:-qwen3:4b}}" ;;
  update)
    require_root
    src="\${2:-}"
    if [ -z "\$src" ]; then src="\$UPDATE_URL"; fi
    if [ -f "\$src" ]; then
      installer="\$src"
    else
      tmp="\$(mktemp)"
      echo "Baixando o instalador: \$src"
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL "\$src" -o "\$tmp" || { echo "Falha ao baixar (repo privado? arquivo nao encontrado?)." >&2; rm -f "\$tmp"; exit 1; }
      elif command -v wget >/dev/null 2>&1; then
        wget -qO "\$tmp" "\$src" || { echo "Falha ao baixar (repo privado? arquivo nao encontrado?)." >&2; rm -f "\$tmp"; exit 1; }
      else
        echo "curl ou wget necessario." >&2; exit 1
      fi
      [ -s "\$tmp" ] || { echo "Instalador baixado vazio — repo privado?" >&2; rm -f "\$tmp"; exit 1; }
      grep -q 'Hadix AI' "\$tmp" || { echo "Arquivo baixado nao parece o instalador Hadix." >&2; rm -f "\$tmp"; exit 1; }
      installer="\$tmp"
    fi
    echo "Rodando o instalador novo (reusa o .env existente)..."
    HADIX_DIR="\$INSTALL_DIR" bash "\$installer" -y
    [ "\$installer" = "\$tmp" ] && rm -f "\$tmp"
    ;;
  help|*)  cat <<'EOF'
Hadix AI — gerenciador do backend
  sudo hadix start          sobe a stack
  sudo hadix stop           derruba a stack
  sudo hadix restart        reinicia os containers
  sudo hadix status         status dos containers
  sudo hadix logs [servico] logs (padrao: api)
  sudo hadix env            mostra o .env
  sudo hadix model [nome]   baixa um modelo no Ollama
  sudo hadix update [url|file]
                            atualiza o backend/painel (padrao: URL configurada)
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
  echo "          painel: https://$API_DOMAIN/painel/"
  echo "  Drive : https://$DRIVE_DOMAIN"
  echo "          admin: hadix-admin / (sua NEXTCLOUD_ADMIN_PASSWORD)"
  echo "  Site  : https://$AI_DOMAIN"
  echo "          login/chat: https://$AI_DOMAIN/chat.html (URL da API + API_TOKEN)"
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
