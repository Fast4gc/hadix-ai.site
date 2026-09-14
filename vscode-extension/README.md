# Hadix AI Dashboard

Dashboard local para a API Hadix, com múltiplas conversas, status do modelo e exportação PNG/SVG. Não carrega CDN. Requer uma API Hadix acessível e token Bearer.

## Instalar o pacote

No VS Code, execute **Extensions: Install from VSIX…** e selecione `hadix-ai-dashboard-1.0.0.vsix`. Depois execute **Hadix AI: Configure Connection** para informar URL e token, ou **Hadix AI: Open Dashboard** para abrir o painel.

## Desenvolver com F5

Abra esta pasta `vscode-extension` como pasta principal no VS Code e execute:

```powershell
npm ci
npm run compile
```

Pressione F5 e execute **Hadix AI: Open Dashboard** na janela Extension Development Host. Configure a conexão e teste envio com Enter/clique, Parar, persistência e exportação. A exportação deve abrir o diálogo nativo para salvar.

## Configuração e credenciais

`hadix.apiUrl` configura o endereço; a variável de ambiente `HADIX_API_URL` também é aceita. O token é guardado em SecretStorage, nunca em settings.json. O histórico é armazenado no workspace. Sair apaga a credencial da conexão atual.

`hadix.transport` usa `bridge` por padrão: a Webview não faz fetch, tem `connect-src 'none'` e solicita as operações ao host por postMessage. Não requer CORS adicional no backend. O host precisa ter acesso de rede à API.

O modo opcional `direct` faz fetch na Webview, disponibiliza a credencial em sua memória e restringe connect-src à origem configurada. Nesse modo, o CORS da API precisa autorizar a origem da Webview. Reabra o painel após mudar URL ou transporte. A ponte é a opção indicada para o CORS atual do Hadix.

## Compilar, testar e empacotar

```powershell
npm test
npm run package
```

O segundo comando sincroniza o HTML, compila TypeScript e gera `hadix-ai-dashboard-1.0.0.vsix`. A fonte do dashboard está em `../backend/site/dashboard.html`; a cópia distribuída está em `media/dashboard.html`. A pasta da extensão também funciona isoladamente com essa cópia.

O HTML funciona sem acesso à internet, mas respostas exigem a API. Imagens são geradas localmente, sem capturar credenciais. Conversas extensas são exportadas em páginas dentro de um ZIP.

Referências: [Webview e CSP](https://code.visualstudio.com/api/extension-guides/webview), [SecretStorage](https://code.visualstudio.com/api/references/vscode-api#SecretStorage), [empacotamento VSIX](https://code.visualstudio.com/api/working-with-extensions/publishing-extension).
