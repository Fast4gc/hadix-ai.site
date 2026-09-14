import { randomBytes } from 'node:crypto';

export function normalizeBase(value: string): string {
  const u = new URL(value.trim());
  const loopback = ['localhost', '127.0.0.1', '[::1]'].includes(u.hostname);
  if (u.username || u.password || u.search || u.hash || !(u.protocol === 'https:' || (u.protocol === 'http:' && loopback))) throw new Error('invalid_base');
  return u.href.replace(/\/+$/, '');
}
export function renderWebview(source: string, base: string, transport: 'bridge' | 'direct'): string {
  const nonce = randomBytes(20).toString('hex');
  const connect = transport === 'bridge' ? "'none'" : new URL(normalizeBase(base)).origin;
  const csp = `default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}'; img-src data: blob:; connect-src ${connect}; base-uri 'none'; form-action 'none';`;
  const config = JSON.stringify({ transport }).replace(/</g, '\\u003c');
  return source.replace(/<meta id="hadix-csp"[^>]*>/, `<meta http-equiv="Content-Security-Policy" content="${csp}">`)
    .replace(/<script>/g, `<script nonce="${nonce}">`)
    .replace('<!-- HADIX_HOST_CONFIG -->', `<script nonce="${nonce}">window.__HADIX_HOST_CONFIG__=${config};</script>`);
}
export function validRequest(path: unknown, method: unknown, body: unknown): boolean {
  if (method === 'GET') return ['/api/config', '/api/ready'].includes(String(path)) && body === undefined;
  if (method !== 'POST' || path !== '/api/chat' || !body || typeof body !== 'object') return false;
  const messages = (body as { messages?: unknown }).messages;
  if (!Array.isArray(messages) || !messages.length || messages.length > 24) return false;
  if (messages.some(m => !m || !['user', 'assistant', 'system'].includes(m.role) || typeof m.content !== 'string' || !m.content.trim() || m.content.length > 8000)) return false;
  return messages.reduce((n, m) => n + m.content.length, 0) <= 16000;
}
export function cleanState(value: unknown): unknown {
  if (!value || typeof value !== 'object') return undefined;
  const input = value as { selected?: unknown; conversations?: unknown };
  if (!Array.isArray(input.conversations)) return undefined;
  const conversations = input.conversations.slice(0, 50).filter(c => c && typeof c.id === 'string').map(c => ({
    id: c.id.slice(0, 100), title: String(c.title || '').slice(0, 100), model: String(c.model || '').slice(0, 100),
    created: Number(c.created) || Date.now(), updated: Number(c.updated) || Date.now(),
    messages: (Array.isArray(c.messages) ? c.messages : []).slice(-200).filter((m: any) => m && ['user', 'assistant', 'system'].includes(m.role) && typeof m.content === 'string').map((m: any) => ({
      id: String(m.id || '').slice(0, 100), role: m.role, content: m.content.slice(0, 32000),
      state: ['pending', 'complete', 'error', 'stopped'].includes(m.state) ? m.state : 'complete', notice: String(m.notice || '').slice(0, 300),
    })),
  }));
  const result = { version: 1, selected: typeof input.selected === 'string' ? input.selected.slice(0, 100) : '', conversations };
  if (JSON.stringify(result).length > 4_000_000) return undefined;
  return result;
}
export function decodeExport(name: unknown, encoded: unknown): { name: string; bytes: Uint8Array; extension: string } {
  if (typeof name !== 'string' || !/^hadix-[a-zA-Z0-9_.-]+\.(png|svg|zip)$/.test(name) || name.length > 180) throw new Error('invalid_export');
  if (typeof encoded !== 'string' || encoded.length > 34_000_000 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) throw new Error('invalid_export');
  const bytes = Buffer.from(encoded, 'base64');
  const extension = name.split('.').pop()!;
  if (extension === 'png' && !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) throw new Error('invalid_export');
  if (extension === 'zip' && bytes.readUInt32LE(0) !== 0x04034b50) throw new Error('invalid_export');
  if (extension === 'svg') {
    const svg = bytes.toString('utf8');
    if (!svg.startsWith('<svg ') || /<script|<foreignObject|\son[a-z]+\s*=|\b(?:href|src)\s*=/i.test(svg)) throw new Error('invalid_export');
  }
  return { name, bytes, extension };
}
