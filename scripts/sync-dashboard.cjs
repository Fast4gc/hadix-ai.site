const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'backend/site/dashboard.html'));
for (const relative of ['backend/site/index.html', 'backend/site/chat.html', 'backend/site/app/index.html', 'vscode-extension/media/dashboard.html']) {
  const target = path.join(root, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, source);
}
console.log('Dashboard sincronizado: /, /app/, /chat.html e extensão.');
