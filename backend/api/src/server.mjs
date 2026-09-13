import { createApp, readConfig } from './app.mjs';
const app = createApp(readConfig());
const server = app.listen(3000, '0.0.0.0', () => console.log('Hadix API listening on :3000'));
server.requestTimeout = 250_000;
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10_000).unref();
});
