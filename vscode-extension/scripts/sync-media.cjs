const fs = require('node:fs');
const path = require('node:path');
const source = path.resolve(__dirname, '../../backend/site/dashboard.html');
const target = path.resolve(__dirname, '../media/dashboard.html');
if (fs.existsSync(source)) { fs.mkdirSync(path.dirname(target), { recursive: true }); fs.copyFileSync(source, target); }
else if (!fs.existsSync(target)) throw new Error('dashboard.html não encontrado.');
