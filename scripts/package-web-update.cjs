const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const root = path.resolve(__dirname, '..');
cp.execFileSync(process.execPath, [path.join(__dirname, 'sync-dashboard.cjs')]);
const out = path.join(root, 'artifacts');
fs.mkdirSync(out, { recursive: true });
const archive = path.join(out, 'hadix-web-update.tar.gz');
cp.execFileSync('tar', ['-czf', archive, '-C', path.join(root, 'backend'), 'site/index.html', 'site/landing.html', 'site/dashboard.html', 'site/chat.html', 'site/login', 'site/app', 'site/assets']);
const payload = fs.readFileSync(archive).toString('base64').match(/.{1,76}/g).join('\n');
const script = `#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo 'Execute com sudo.' >&2; exit 1; }
backend="$(realpath -e "\${1:-/opt/hadix/backend}")"
test -f "$backend/compose.yaml" || { echo 'Diretorio sem compose.yaml.' >&2; exit 1; }
test -d "$backend/site" || { echo 'Diretorio do site nao encontrado.' >&2; exit 1; }
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
base64 --decode > "$stage/site.tar.gz" <<'HADIX_WEB_PAYLOAD'
${payload}
HADIX_WEB_PAYLOAD
tar -xzf "$stage/site.tar.gz" -C "$stage"
grep -q 'async function send(text)' "$stage/site/chat.html"
grep -q 'href="login/"' "$stage/site/index.html"
test -s "$stage/site/login/index.html"
test -s "$stage/site/app/index.html"
backup_dir="$(dirname "$backend")/backups"
mkdir -p "$backup_dir"
backup="$(mktemp "$backup_dir/site-$(date +%Y%m%d-%H%M%S)-XXXXXX.tar.gz")"
tar -czf "$backup" -C "$backend" site
cp -R "$stage/site/." "$backend/site/"
find "$backend/site" -type d -exec chmod 755 {} +
find "$backend/site" -type f -exec chmod 644 {} +
echo "Site atualizado. Backup: $backup"
echo 'Abra https://ai.hadix.site/ e use Ctrl+Shift+R.'
echo 'Fluxo: pagina inicial -> Entrar na IA -> login -> dashboard.'
echo 'Ollama, API, .env e volumes nao foram alterados.'
`;
fs.writeFileSync(path.join(out, 'hadix-web-update.sh'), script);
console.log('Atualizador gerado em artifacts/hadix-web-update.sh');
