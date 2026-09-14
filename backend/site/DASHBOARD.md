# Hadix AI — dashboard

## Mudanças

`dashboard.html` é a fonte autocontida, com CSS e JavaScript inline, sem CDN ou build obrigatório. O tema da landing agora envolve login, múltiplas conversas, chat e resumo da sessão. A landing anterior está em `landing.html`.

Enter chama `send(text)` diretamente; o formulário cancela o submit nativo. Shift+Enter quebra linha e Parar cancela a geração sem mensagem de erro. O histórico permanece separado por conversa; somente o contexto recente dentro dos limites da API é enviado. Markdown usa elementos e texto seguros, sem interpretar HTML da resposta.

Após editar a fonte, execute na raiz do repositório:

```powershell
node scripts/sync-dashboard.cjs
```

Isso atualiza `index.html`, `chat.html`, `app/index.html` e a cópia da extensão. O servidor estático existente atende `/`, `/chat.html` e `/app/`; publique esses arquivos no volume do site para atualizar a VPS. Nenhum arquivo da API, Docker ou Caddy foi alterado para esta entrega.

## Testar no navegador

1. Depois de publicar os arquivos estáticos, abra `https://ai.hadix.site/app/` e configure URL da API e token Bearer.
2. Confira modelo e status da sessão; envie por Enter e pelo botão. A URL não deve mudar e o painel Network deve mostrar OPTIONS e POST bem-sucedidos.
3. Teste Shift+Enter, Parar, nova conversa, troca de conversa e recarregamento. O histórico deve persistir.
4. O token fica em memória por padrão. A opção de lembrar grava a conexão em localStorage; Sair remove essa credencial. Conversas ficam no dispositivo, limitadas a 50 conversas e 200 mensagens por conversa.

Para desenvolvimento, sirva `backend/site` por HTTP e use uma API que autorize essa origem. A origem `file://` não substitui uma origem CORS autorizada. O visual funciona sem internet/CDN; conversar requer acesso à API configurada.

## Testar no VS Code

Veja `../../vscode-extension/README.md` para instalar o VSIX ou abrir a pasta da extensão com F5. O transporte padrão faz fetch no host da extensão e usa `postMessage`; a Webview usa CSP com nonce e `connect-src 'none'`. As credenciais ficam em SecretStorage e o histórico no estado do workspace.

Não é necessário adicionar uma origem Webview ao CORS usando a ponte padrão. O host precisa alcançar a API por HTTPS. O modo opcional `hadix.transport: direct` permite no CSP somente a origem da API e exige que o backend autorize a origem efetiva da Webview. Prefira a ponte para manter o CORS atual. Após trocar URL ou transporte nas configurações, reabra o painel.

## Testar imagens

Escolha conversa, dashboard ou sessão e PNG/SVG em Exportar imagem. No navegador o arquivo é baixado; na extensão aparece o diálogo para salvar. Abra o PNG em um visualizador e o SVG no navegador. Conversas longas geram um ZIP com páginas, preservando o conteúdo.

O exportador desenha uma composição própria a partir dos dados, sem capturar o DOM nem usar fontes remotas. O texto exportado preserva a marcação Markdown literal. Os nomes incluem timestamp e modelo. Campos de credenciais não fazem parte da exportação.

## Verificação automatizada

```powershell
cd vscode-extension
npm ci
npm test
cd ../tests/dashboard
npm ci
npx playwright install chromium
npm test
```

É possível indicar um Chromium existente com `PLAYWRIGHT_CHROMIUM_EXECUTABLE`. A integração usa a aplicação real da API com Ollama simulado, testa CORS/preflight, envio sem navegação, cancelamento, persistência, erros, limites do contexto, layout móvel e PNG/SVG/ZIP. Executa também o código compilado da extensão com um adaptador VS Code e Chromium com CSP restritiva, incluindo gravação pelo host.

Os resultados e capturas ficam em `tests/dashboard/results/`. Os testes locais passaram; não representam um teste de inferência na VPS nem uma sessão interativa real de F5.
