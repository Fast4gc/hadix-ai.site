#!/usr/bin/env bash
set -euo pipefail
# Execute na VPS: bash scripts/repair-model.sh /caminho/do/projeto/backend
cd "${1:-$(cd "$(dirname "$0")/../backend" && pwd)}"
test -f compose.yaml || { echo 'Diretório sem compose.yaml.' >&2; exit 1; }
docker compose up -d ollama
ready=false
for attempt in {1..30}; do
  if docker compose exec -T ollama ollama list >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
"$ready" || { echo 'Ollama não iniciou. Verifique docker compose logs ollama.' >&2; exit 1; }
# Use a configuração efetiva da API, evitando baixar um modelo diferente.
model="$(docker compose exec -T api printenv OLLAMA_MODEL | tr -d '\r\n')"
test -n "$model" || { echo 'OLLAMA_MODEL não está configurado na API.' >&2; exit 1; }
printf 'Instalando o modelo configurado: %s\n' "$model"
docker compose exec -T ollama ollama pull "$model"
docker compose exec -T ollama ollama show "$model" >/dev/null
echo 'Modelo instalado. No dashboard, clique em Verificar novamente.'
