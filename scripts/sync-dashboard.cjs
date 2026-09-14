const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'backend/site/dashboard.html'));
for (const relative of ['backend/site/login/index.html', 'backend/site/chat.html', 'backend/site/app/index.html', 'vscode-extension/media/dashboard.html']) {
  const target = path.join(root, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, source);
}
fs.copyFileSync(path.join(root, 'backend/site/landing.html'), path.join(root, 'backend/site/index.html'));
const installerPath = path.join(root, 'install.sh');
let installer = fs.readFileSync(installerPath, 'utf8').replace(/\r\n/g, '\n');
for (const [marker, file] of [['HX_INDEX', 'landing.html'], ['HX_CHAT', 'dashboard.html']]) {
  const start = installer.indexOf("<<'" + marker + "'\n");
  const end = installer.indexOf('\n' + marker + '\n', start);
  if (start < 0 || end < 0) throw new Error('Marcador ausente no instalador: ' + marker);
  const contentStart = start + ("<<'" + marker + "'\n").length;
  installer = installer.slice(0, contentStart) + fs.readFileSync(path.join(root, 'backend/site', file), 'utf8').trimEnd() + installer.slice(end);
}
if (!installer.includes('# HADIX_DASHBOARD_ROUTES')) {
  installer = installer.replace('\nHX_CHAT\n', '\nHX_CHAT\n  # HADIX_DASHBOARD_ROUTES\n  mkdir -p "$BACKEND_DIR/site/login" "$BACKEND_DIR/site/app"\n  cp "$BACKEND_DIR/site/chat.html" "$BACKEND_DIR/site/login/index.html"\n  cp "$BACKEND_DIR/site/chat.html" "$BACKEND_DIR/site/app/index.html"\n  cp "$BACKEND_DIR/site/chat.html" "$BACKEND_DIR/site/dashboard.html"\n');
}
fs.writeFileSync(installerPath, installer);
console.log('Landing em /; login em /login/; dashboard em /app/, /chat.html e extensão.');
