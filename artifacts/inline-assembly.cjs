const fs = require('node:fs');
const file = 'index.html';
let html = fs.readFileSync(file, 'utf8');
let svg = fs.readFileSync('assets/img/architecture.svg', 'utf8');
svg = svg.replace('<svg ', '<svg class="assembly-svg" role="img" aria-labelledby="assemblyTitle" ').replace('<defs>', '<title id="assemblyTitle">Construção progressiva das quatro camadas do Hadix</title><defs>');
svg = svg.replace('<g stroke="#89907e"', '<g class="assembly-links" stroke="#89907e"');
for (const [i,y] of [35,195,355,515].entries()) {
  const original = `<g transform="translate(0 ${y}) scale(1 .7)">`;
  svg = svg.replace(original, `<g class="assembly-module" data-module="${i}">${original}`);
  const next = i < 3 ? `<g transform="translate(0 ${[35,195,355,515][i+1]}) scale(1 .7)">` : '<path d="M436 424H511"';
  svg = svg.replace(next, '</g>' + next);
}
const figure = `<div class="assembly-status" aria-hidden="true"><span class="status-dot"></span><span id="assemblyStatus">04 / Sistema conectado</span><span id="assemblyPercent">100%</span></div>${svg}<div class="assembly-progress" aria-hidden="true"><span></span></div>`;
html = html.replace(/<img src="assets\/img\/architecture.svg"[^>]*>/, figure);
fs.writeFileSync(file, html);
