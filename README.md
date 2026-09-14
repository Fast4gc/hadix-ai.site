# Hadix AI

Landing page estática + backend completo para VPS, orquestrado com Docker Compose.

```
hadix-ai.site/
├── index.html          # Landing page (front estático)
├── assets/             # CSS, JS e imagens do front
└── backend/            # Stack Docker Compose
    ├── compose.yaml
    ├── caddy/Caddyfile
    ├── api/            # API custom (Node 24 + Express 5)
    └── scripts/setup-drive.php   # (fora do git — ver nota)
```

---

## Elementos usados no backend

| Serviço | Imagem | Função |
| --- | --- | --- |
| `caddy` | `caddy:2.11.4-alpine` | Reverse proxy na borda + TLS automático (ACME). Publica as portas 80/443 e roteia `API_DOMAIN` → `api:3000` e `DRIVE_DOMAIN` → `nextcloud:80`. |
| `api` | build local (`build: ./api`) | API REST em **Node 24 + Express 5** (`helmet`, `express-rate-limit`). Valida token Bearer, define CORS, limita 12 req/min e encaminha `/api/chat` para o Ollama. |
| `ollama` | `ollama/ollama:0.34.0` | Motor de inferência local de LLMs. Modelo padrão: `qwen3:4b`. |
| `postgres` | `postgres:17-alpine` | Banco de dados do Nextcloud. |
| `redis` | `redis:8-alpine` | Cache/session do Nextcloud (limitado a 192 MB). |
| `nextcloud` | `nextcloud:32.0.15-apache` | Drive de arquivos do Hadix. |
| `cron` | `nextcloud:32.0.15-apache` | Executa o cron do Nextcloud (`/cron.sh`). |

### Redes

- `edge` — `172.30.50.0/24`: recebe `caddy`, `api` e `nextcloud`. **Somente o Caddy expõe portas no host** (`80`, `443`, `443/udp`); API, Ollama e banco não têm porta publicada.
- `inference` — conecta `api` ↔ `ollama` (com egress para baixar modelos).
- `data` — `internal: true`: conecta `postgres`, `redis` e `nextcloud`, sem acesso à internet.

---

## Pré-requisitos da VPS

- **Docker Engine 24+** com **Docker Compose v2**.
- **Hardware**: mínimo 16 GB de RAM e 6 vCPU; recomendado **32 GB / 8 vCPU** (o `compose.yaml` define limites de memória: ollama 12 GB, nextcloud 3 GB, postgres 1 GB). Disco SSD de ~40 GB (modelo `qwen3:4b` ocupa ~4 GB).
- **Domínio com 2 subdomínios** apontando (registro A) para o IP público da VPS:
  - `API_DOMAIN` (ex.: `api.hadix-ai.site`) → IP da VPS
  - `DRIVE_DOMAIN` (ex.: `drive.hadix-ai.site`) → IP da VPS
- **Firewall**: liberar `80/tcp`, `443/tcp` e `443/udp` (HTTP/3).

---

## Instalação

### Via SSH (PowerShell)

```powershell
ssh root@SEU-IP "wget -qO- https://raw.githubusercontent.com/Fast4gc/hadix-ai.site/main/install.sh | bash"
```

### Via wget no VPS

```bash
wget -qO- https://raw.githubusercontent.com/Fast4gc/hadix-ai.site/main/install.sh | sudo bash
```

### Local (dentro do repositório)

```bash
cd hadix-ai.site
sudo ./install.sh
```

> **Nota:** o repositório precisa estar **público** no GitHub para o `wget`/`curl` funcionar (repo privado retorna 404/arquivo vazio). Em GitHub → Settings → Danger Zone → Change visibility → Make public.

O script é **autossuficiente** (não depende do clone do repositório): ele gera toda a stack em `/opt/hadix/backend` e instala o comando `hadix`. Passos que ele executa:
- Instala Docker/Compose (se necessário)
- Gera os arquivos do backend (`compose.yaml`, Caddyfile, API, `Dockerfile`, `setup-drive.php`)
- Gera o `.env` interativamente (ou via variáveis de ambiente com `-y`)
- Instala o comando **`hadix`** em `/usr/local/bin/hadix`
- Sobe a stack completa, baixa o modelo do Ollama e cria o usuário do drive

### Flags

```
-y, --yes            Não interativo (define tudo via variáveis de ambiente)
-d, --dir <caminho>  Diretório de instalação (padrão: /opt/hadix)
-h, --help           Mostra a ajuda
```

> Para instalar em outro diretório: `sudo bash install.sh -d /srv/hadix`

### Comando `hadix`

Após a instalação, gerencie a stack com `sudo`:

```
sudo hadix start          sobe a stack
sudo hadix stop           derruba a stack
sudo hadix restart        reinicia os containers
sudo hadix status         status dos containers
sudo hadix logs [serviço] logs (padrão: api)
sudo hadix env            mostra o .env
sudo hadix model [nome]   baixa um modelo no Ollama
sudo hadix update [url|file]   atualiza backend + painel (reusa o .env)
sudo hadix help           mostra esta ajuda
```

> Se a instalação for feita em outro diretório (`-d`), passe `HADIX_DIR` ao instalar para o comando `hadix` apontar para o lugar certo: `HADIX_DIR=/srv/hadix sudo bash install.sh`.

### Atualização (`hadix update`)

O `hadix update` baixa o `install.sh` mais recente e o executa em modo não interativo, **reutilizando o `.env` existente**. Ele regrava o backend (compose, Caddyfile, API, painel) e sobe a stack de novo.

```bash
sudo hadix update                      # baixa da URL padrão (raw do GitHub)
sudo hadix update https://DOMINIO/install.sh   # de outra URL
sudo hadix update /caminho/install.sh  # de um arquivo local (ex.: scp)
```

> A URL padrão aponta para `raw.githubusercontent.com` — como o repositório é **privado**, o download retorna vazio. Para usar o update sem ficar copiando o script manualmente: torne o repo público, ou passe um arquivo/URL própria:
>
> ```bash
> HADIX_UPDATE_URL=https://SEU_HOST/install.sh sudo hadix update
> ```
>
> Exemplo com scp do Windows:
>
> ```powershell
> scp E:\xampp\htdocs\hadix-ai.site\install.sh ubuntu@SEU_IP:~/
> ```
> ```bash
> # no VPS
> sudo hadix update /home/ubuntu/install.sh
> ```

### Painel (Bootstrap)

O painel é servido pelo Caddy em `https://$API_DOMAIN/painel/` (gerado pelo instalador em `backend/panel/index.html`). Ele lê `/healthz`, `/api/config`, `/api/ready` e conversa via `/api/chat` usando o `API_TOKEN`. A origem do painel é o mesmo domínio da API (sem CORS).

**Importante:** para o painel conseguir chamar a API por navegador, o `API_TOKEN` fica salvo no `localStorage` do navegador — use o token de um usuário com privilégios limitados se desejar.

### 3. Subir a stack

```bash
docker compose up -d --build
```

Na primeira execução:

- o `compose.yaml` monta `./scripts/setup-drive.php` dentro do contêiner do Nextcloud. **Este arquivo é esperado mas não está versionado** — ele cria o usuário do drive (`HADIX_DRIVE_USER`) com a quota `DRIVE_QUOTA`. O `install.sh` gera uma versão padrão automaticamente quando o arquivo não existe; na instalação manual, crie-o antes do `up` (sem ele a criação do serviço `nextcloud` falha). Veja a nota no fim do documento.
- Os certificados HTTPS são emitidos automaticamente pelo Caddy via ACME (e-mail em `ACME_EMAIL`).

### 4. Baixar o modelo no Ollama

```bash
docker compose exec ollama ollama pull qwen3:4b   # ou $OLLAMA_MODEL
```

Se o modelo não estiver presente, a API responde `status: model_missing` em `/api/ready` e `model_missing` (503) em `/api/chat`. A imagem do Ollama só baixa o modelo quando você executa `ollama pull` — não é feito no `up`. Para prever este passo:

```bash
docker compose exec ollama ollama run qwen3:4b 'oi'   # testa e deixa o modelo carregado
```

### 5. Verificar a instalação

```bash
docker compose ps                       # todos os serviços "running"/"healthy"
curl -s https://$API_DOMAIN/healthz     # {"status":"ok"} — público, sem token
curl -s -H "Authorization: Bearer $API_TOKEN" https://$API_DOMAIN/api/ready
# e: curl -s -H "Authorization: Bearer $API_TOKEN" https://$API_DOMAIN/api/config
```

### 6. Acessar o drive

Abra `https://$DRIVE_DOMAIN`. Admin criado automaticamente: `hadix-admin` / `NEXTCLOUD_ADMIN_PASSWORD`. O usuário do drive `hadix` (para uploads via API do Nextcloud) é criado pelo `setup-drive.php`.

---

## Variáveis de ambiente

| Variável | Obrigatória? | Descrição |
| --- | --- | --- |
| `ACME_EMAIL` | sim | E-mail usado pelo Caddy para emissão/renovação de certificados TLS. |
| `API_DOMAIN` | sim | Subdomínio da API (ex.: `api.hadix-ai.site`). |
| `DRIVE_DOMAIN` | sim | Subdomínio do drive/Nextcloud (ex.: `drive.hadix-ai.site`). |
| `API_TOKEN` | sim | Token Bearer de acesso à API. Mínimo de 32 caracteres. |
| `POSTGRES_PASSWORD` | sim | Senha do banco Postgres (`nextcloud`). |
| `NEXTCLOUD_ADMIN_PASSWORD` | sim | Senha do admin `hadix-admin` do Nextcloud. |
| `DRIVE_PASSWORD` | sim | Senha do usuário `hadix` do drive (usada pelo `setup-drive.php`). |
| `OLLAMA_MODEL` | não | Modelo do Ollama (padrão: `qwen3:4b`). |
| `DRIVE_QUOTA` | não | Quota do usuário do drive (padrão: `20 GB`). |
| `ALLOWED_ORIGINS` | não | Origens permitidas no CORS, separadas por vírgula (ex.: `https://hadix-ai.site`). Vazio = sem origem permitida. |

---

## API

Todas as rotas `/api/*` exigem o header `Authorization: Bearer $API_TOKEN` (rotas `/healthz` não exigem). Com base nisso:

| Rota | Método | Descrição |
| --- | --- | --- |
| `/healthz` | GET | Healthcheck do serviço (público). |
| `/api/config` | GET | Modelo ativo e URL do drive. |
| `/api/ready` | GET | `200 ready` se o modelo está carregado; `503 model_missing`/`ollama_unavailable` caso contrário. |
| `/api/chat` | POST | Envia `{ "messages": [{ role, content }] }` (1–24 msgs, máx. 16.000 chars) e retorna a resposta do modelo. Processa uma requisição por vez. |

---

## Manutenção

### Logs

```bash
docker compose logs -f --tail=200 api      # logs da API
docker compose logs -f --tail=100 ollama   # logs de inferência
```

### Atualizar

```bash
git pull
docker compose pull            # imagens (caddy, ollama, postgres, ...)
docker compose build --pull api
docker compose up -d --remove-orphans
```

### Backup

Os dados vivem nos volumes `postgres_data`, `nextcloud_data`, `ollama_data`, `caddy_data` e `caddy_config`. Dump do banco:

```bash
docker compose exec -T postgres pg_dump -U nextcloud nextcloud > backup-$(date +%F).sql
```

Para o Nextcloud, use `occ` para suspender/resumir e copie o volume `nextcloud_data`.

### Recuperar de falha do `nextcloud`

Se o contêiner não subir, verifique se `backend/scripts/setup-drive.php` existe (montagem com `:ro` — arquivo inexistente vira um diretório e quebra o contêiner):

```bash
ls -l scripts/setup-drive.php
docker compose logs nextcloud | tail -50
```

---

## Segurança (resumo)

- API, Ollama, Postgres e Redis **não publicam portas no host**; só o Caddy expõe 80/443.
- Contêiner `api` roda `read_only`, sem capabilities (`cap_drop: ALL`) e com `no-new-privileges`.
- Token da API comparado com `timingSafeEqual`; CORS restrito via `ALLOWED_ORIGINS`.
- Rede `data` é `internal: true` (sem egress).