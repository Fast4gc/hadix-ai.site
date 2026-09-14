const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizeBase, renderWebview, validRequest, cleanState, decodeExport } = require('../out/security');
test('only HTTPS or loopback HTTP without embedded credentials', () => {
  assert.equal(normalizeBase('https://api.hadix.site/'), 'https://api.hadix.site');
  assert.equal(normalizeBase('http://127.0.0.1:3000'), 'http://127.0.0.1:3000');
  for (const value of ['http://example.org','file:///secret','https://user:token@example.org','https://api.example.com/?token=secret']) assert.throws(() => normalizeBase(value));
});
test('CSP bridge has no network or remote scripts; direct origin is exact', () => {
  const source = '<meta id="hadix-csp" content="old"><!-- HADIX_HOST_CONFIG --><script>hello()</script>';
  const bridge = renderWebview(source, 'https://api.hadix.site', 'bridge');
  assert.match(bridge, /connect-src 'none'/);
  assert.match(bridge, /script-src 'nonce-[a-f0-9]+'/);
  assert.doesNotMatch(bridge, /<script>/);
  assert.match(renderWebview(source,'https://api.example.com/v1','direct'), /connect-src https:\/\/api.example.com;/);
});
test('bridge cannot issue arbitrary URLs, methods or oversized model context', () => {
  assert.ok(validRequest('/api/chat','POST',{messages:[{role:'user',content:'Olá'}]}));
  assert.equal(validRequest('https://evil.example/api/chat','POST',{messages:[]}),false);
  assert.equal(validRequest('/api/pull','POST',{}),false);
  assert.equal(validRequest('/api/config','DELETE',undefined),false);
  assert.equal(validRequest('/api/chat','POST',{messages:[{role:'user',content:'a'.repeat(8001)}]}),false);
});
test('persisted state discards token and arbitrary fields', () => {
  const state = cleanState({token:'secret',selected:'one',conversations:[{id:'one',token:'secret',title:'A',messages:[{role:'user',content:'hi',token:'secret'}]}]});
  assert.equal(JSON.stringify(state).includes('secret'),false);
});
test('export validates signature and basename and rejects active SVG', () => {
  assert.equal(decodeExport('hadix-test.svg',Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"></svg>').toString('base64')).extension,'svg');
  assert.throws(()=>decodeExport('../hadix-test.svg','AA=='));
  assert.throws(()=>decodeExport('hadix-test.png','AA=='));
  assert.throws(()=>decodeExport('hadix-test.svg',Buffer.from('<svg ><script>alert(1)</script></svg>').toString('base64')));
});
