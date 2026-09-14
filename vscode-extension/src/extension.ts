import * as vscode from 'vscode';
import { cleanState, decodeExport, normalizeBase, renderWebview, validRequest } from './security';

type Transport = 'bridge' | 'direct';
type ApiError = Error & { code?: string; status?: number };
const secretKey = (base: string) => 'hadix.token:' + base;

export function activate(context: vscode.ExtensionContext) {
  let panel: vscode.WebviewPanel | undefined;
  function configuredBase(): string {
    return normalizeBase(process.env.HADIX_API_URL || vscode.workspace.getConfiguration('hadix').get<string>('apiUrl') || 'https://api.hadix.site');
  }
  context.subscriptions.push(vscode.commands.registerCommand('hadix.configureConnection', async () => {
    const value = await vscode.window.showInputBox({ title: 'Hadix — URL da API', value: configuredBase(), ignoreFocusOut: true });
    if (!value) return;
    let base: string;
    try { base = normalizeBase(value); } catch { void vscode.window.showErrorMessage('Use HTTPS ou HTTP em localhost.'); return; }
    const token = await vscode.window.showInputBox({ title: 'Hadix — Token de acesso', password: true, ignoreFocusOut: true });
    if (!token?.trim()) return;
    await context.secrets.store(secretKey(base), token.trim());
    await context.globalState.update('hadix.lastBase', base);
    await vscode.workspace.getConfiguration('hadix').update('apiUrl', base, vscode.ConfigurationTarget.Global);
    panel?.dispose();
    void vscode.commands.executeCommand('hadix.openDashboard');
  }));
  context.subscriptions.push(vscode.commands.registerCommand('hadix.openDashboard', async () => {
    if (panel) { panel.reveal(); return; }
    let base: string;
    try { base = configuredBase(); } catch { void vscode.window.showErrorMessage('URL da API Hadix inválida.'); return; }
    const transport: Transport = vscode.workspace.getConfiguration('hadix').get('transport') === 'direct' ? 'direct' : 'bridge';
    if (transport === 'bridge') {
      const remembered = context.globalState.get<string>('hadix.lastBase');
      if (remembered && !process.env.HADIX_API_URL) { try { base = normalizeBase(remembered); } catch {} }
    }
    const webviewPanel = vscode.window.createWebviewPanel('hadixDashboard', 'Hadix AI', vscode.ViewColumn.One, {
      enableScripts: true, retainContextWhenHidden: true, localResourceRoots: [vscode.Uri.joinPath(context.extensionUri, 'media')],
    });
    panel = webviewPanel;
    const requests = new Map<string, AbortController>();
    let generation = 0, disposed = false, chatActive = false;
    const reply = (id: string, data?: unknown, error?: { code: string; status?: number }) => {
      if (!disposed) void webviewPanel.webview.postMessage({ type: 'hadix:reply', id, data, error });
    };
    async function request(path: string, method: string, body: unknown, signal: AbortSignal, token: string, endpoint = base): Promise<any> {
      const result = await fetch(endpoint + path, { method, signal, redirect: 'error', headers: { Authorization: 'Bearer ' + token, ...(body ? { 'Content-Type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) });
      const data: any = await result.json().catch(() => ({}));
      if (!result.ok) throw Object.assign(new Error(), { code: String(data.error || data.status || 'request_failed'), status: result.status });
      return data;
    }
    webviewPanel.onDidDispose(() => { disposed = true; for (const controller of requests.values()) controller.abort(); requests.clear(); panel = undefined; }, null, context.subscriptions);
    webviewPanel.webview.onDidReceiveMessage(async (message: any) => {
      if (!message || typeof message !== 'object') return;
      if (message.type === 'abort') { requests.get(String(message.id))?.abort(); return; }
      if (message.type === 'persist') {
        const state = cleanState(message.data);
        if (state) await context.workspaceState.update('hadix.conversations.v1', state);
        return;
      }
      const id = message.id;
      if (typeof id !== 'string' || id.length > 80 || requests.has(id)) return;
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 280000);
      requests.set(id, controller);
      let ownsChat = false;
      try {
        if (message.type === 'bootstrap') {
          const token = await context.secrets.get(secretKey(base));
          reply(id, { base, hasToken: !!token, ...(transport === 'direct' ? { token } : {}), state: context.workspaceState.get('hadix.conversations.v1') });
        } else if (message.type === 'connect') {
          const endpoint = normalizeBase(String(message.base));
          if (transport === 'direct' && new URL(endpoint).origin !== new URL(base).origin) throw Object.assign(new Error(), { code: 'origin_not_allowed' });
          const supplied = typeof message.token === 'string' ? message.token.trim() : '';
          const token = supplied || (endpoint === base ? await context.secrets.get(secretKey(base)) : undefined);
          if (!token || token.length > 8192 || /[\r\n]/.test(token)) throw Object.assign(new Error(), { code: 'unauthorized', status: 401 });
          const attempt = ++generation;
          const config = await request('/api/config', 'GET', undefined, controller.signal, token, endpoint);
          if (attempt !== generation || controller.signal.aborted) throw new Error('canceled');
          if (typeof config.model !== 'string') throw Object.assign(new Error(), { code: 'invalid_response' });
          await context.secrets.store(secretKey(endpoint), token);
          base = endpoint;
          await context.globalState.update('hadix.lastBase', base);
          reply(id, { config });
        } else if (message.type === 'request') {
          if (!validRequest(message.path, message.method, message.body)) throw Object.assign(new Error(), { code: 'invalid_messages', status: 400 });
          if (message.path === '/api/chat') {
            if (chatActive) throw Object.assign(new Error(), { code: 'model_busy', status: 429 });
            chatActive = true; ownsChat = true;
          }
          const token = await context.secrets.get(secretKey(base));
          if (!token) throw Object.assign(new Error(), { code: 'unauthorized', status: 401 });
          reply(id, await request(message.path, message.method, message.body, controller.signal, token));
        } else if (message.type === 'logout') {
          generation++;
          for (const [otherId, other] of requests) if (otherId !== id) other.abort();
          await context.secrets.delete(secretKey(base));
          reply(id, { loggedOut: true });
        } else if (message.type === 'copy') {
          if (typeof message.text !== 'string' || message.text.length > 1_000_000) throw new Error('invalid');
          await vscode.env.clipboard.writeText(message.text); reply(id, { copied: true });
        } else if (message.type === 'saveExport') {
          const file = decodeExport(message.name, message.base64);
          const uri = await vscode.window.showSaveDialog({ defaultUri: vscode.Uri.joinPath(vscode.Uri.file(process.env.USERPROFILE || process.env.HOME || '.'), file.name), filters: { [file.extension.toUpperCase()]: [file.extension] }, saveLabel: 'Salvar imagem Hadix' });
          if (uri) await vscode.workspace.fs.writeFile(uri, file.bytes);
          reply(id, { saved: !!uri });
        } else throw new Error('invalid');
      } catch (error) {
        const err = error as ApiError;
        const allowed = ['unauthorized', 'origin_not_allowed', 'model_busy', 'rate_limited', 'model_missing', 'ollama_unavailable', 'inference_timeout', 'invalid_messages', 'invalid_response'];
        reply(id, undefined, { code: controller.signal.aborted ? 'inference_timeout' : allowed.includes(err.code || '') ? err.code! : 'network', status: err.status });
      } finally { clearTimeout(timer); requests.delete(id); if (ownsChat) chatActive = false; }
    }, undefined, context.subscriptions);
    const source = Buffer.from(await vscode.workspace.fs.readFile(vscode.Uri.joinPath(context.extensionUri, 'media', 'dashboard.html'))).toString('utf8');
    webviewPanel.webview.html = renderWebview(source, base, transport);
  }));
}
export function deactivate() {}
