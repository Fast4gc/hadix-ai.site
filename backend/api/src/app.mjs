import express from 'express';
import helmet from 'helmet';
import { rateLimit } from 'express-rate-limit';
import { createHash, timingSafeEqual } from 'node:crypto';

const digest = value => createHash('sha256').update(value).digest();
export function readConfig(env = process.env) {
  if (!env.API_TOKEN || env.API_TOKEN.length < 32) throw new Error('API_TOKEN deve ter pelo menos 32 caracteres.');
  const ollamaUrl = new URL(env.OLLAMA_URL || 'http://ollama:11434');
  if (!['http:', 'https:'].includes(ollamaUrl.protocol)) throw new Error('OLLAMA_URL inválida.');
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
  // Exactly one reverse proxy, and no host port published for this service.
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
      return res.status(400).json({ error: 'invalid_messages', message: 'Envie 1–24 mensagens de texto, até 16.000 caracteres no total.' });
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
