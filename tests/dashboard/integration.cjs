const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '../..');
const results = path.join(__dirname, 'results');
fs.mkdirSync(results, { recursive: true });
const token = 'hadix-local-test-token-not-a-real-credential';
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(`http://127.0.0.1:${server.address().port}`)));
const report = [];
let hostHTML = '', nextError = null, calls = [], preflights = 0;

(async () => {
  const { createApp } = await import(pathToFileURL(path.join(root, 'backend/api/src/app.mjs')));
  const site = http.createServer((req, res) => {
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    if (req.url === '/webview') return res.end(hostHTML);
    const pathname=new URL(req.url,'http://localhost').pathname;
    if(pathname.startsWith('/assets/')){const asset=path.resolve(root,'backend/site','.'+pathname);if(!asset.startsWith(path.resolve(root,'backend/site/assets')+path.sep)||!fs.existsSync(asset)){res.writeHead(404);return res.end();}res.setHeader('Content-Type',asset.endsWith('.js')?'application/javascript':asset.endsWith('.css')?'text/css':'image/svg+xml');return res.end(fs.readFileSync(asset));}
    const file = ['/','/index.html'].includes(pathname)?'index.html':pathname==='/login/'?'login/index.html':pathname === '/chat.html' ? 'chat.html' : pathname === '/app/' ? 'app/index.html' : 'dashboard.html';
    res.end(fs.readFileSync(path.join(root, 'backend/site', file)));
  });
  const siteURL = await listen(site);
  const apiApp = createApp({ token, ollamaUrl:'http://fake-ollama', model:'qwen3:4b', origins:[siteURL], rateMax:1000, timeoutMs:5000, driveUrl:'https://drive.example.test' }, {
    fetchImpl: async (url, options = {}) => {
      if (url.endsWith('/api/tags')) return Response.json({ models:[{name:'qwen3:4b'}] });
      const body = JSON.parse(options.body); calls.push(body);
      const question = body.messages.at(-1).content;
      await new Promise((resolve, reject) => {
        const timer = setTimeout(resolve, question.includes('[slow]') ? 3500 : 120);
        options.signal.addEventListener('abort', () => { clearTimeout(timer); reject(new DOMException('Aborted','AbortError')); }, {once:true});
      });
      return Response.json({ message:{role:'assistant',content:'**Resposta segura** para: ' + question + '\n\n- Contexto preservado\n- Próximo passo\n\n```js\nconst sinal = "decisão";\n```\n<img src="https://invalid.example/x" onerror="window.hacked=true">'}, done:true });
    },
  });
  const apiServer = http.createServer((req, res) => {
    if(req.method === 'OPTIONS') preflights++;
    if(nextError && req.method !== 'OPTIONS') {
      const error=nextError; nextError=null;
      res.setHeader('Access-Control-Allow-Origin',siteURL);res.setHeader('Content-Type','application/json');res.writeHead(error.status);return res.end(JSON.stringify({error:error.code}));
    }
    apiApp(req,res);
  });
  const apiURL = await listen(apiServer);
  const browser = await chromium.launch({headless:true, ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? {executablePath:process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE} : {})});
  let disposeHost = () => {};
  try {
    const landingContext=await browser.newContext();await landingContext.route('**/*',route=>route.request().url().startsWith(siteURL)?route.continue():route.abort());const landing=await landingContext.newPage();await landing.goto(siteURL);await landing.locator('.header-cta').click();await landing.waitForSelector('#loginDialog[open]');assert.match(landing.url(),/\/login\/$/);assert.equal(await landing.locator('#dashboard').isVisible(),false);await landingContext.close();report.push({test:'landing-to-login',passed:true});
    const context = await browser.newContext({viewport:{width:1440,height:1000},acceptDownloads:true});
    const page = await context.newPage();
    const errors=[], external=[], navigation=[];
    page.on('pageerror',e=>errors.push(e.message));
    page.on('request',req=>{if(!req.url().startsWith(siteURL)&&!req.url().startsWith(apiURL)&&!req.url().startsWith('blob:'))external.push(req.url());});
    await page.goto(siteURL + '/chat.html');
    await page.waitForSelector('#loginDialog[open]');assert.match(page.url(),/\/login\/$/);assert.equal(await page.locator('#dashboard').isVisible(),false);
    await page.locator('#apiBase').fill(apiURL);await page.locator('#apiToken').fill(token);await page.locator('#rememberToken').check();await page.locator('#loginBtn').click();
    await page.waitForFunction(()=>document.querySelector('#sessionStatus').textContent==='Pronta');
    assert.match(page.url(),/\/app\/$/);await page.screenshot({path:path.join(results,'dashboard-welcome.png'),fullPage:true});await page.locator('#toggleSession').click();
    page.on('framenavigated',frame=>{if(frame===page.mainFrame())navigation.push(frame.url());});
    await page.locator('#chatInput').fill('Pergunta por Enter');await page.locator('#chatInput').press('Enter');
    await page.waitForFunction(()=>document.querySelectorAll('.assistant .message-body').length===1);
    await page.locator('#chatInput').fill('Pergunta por clique');await page.locator('#sendBtn').click();
    await page.waitForFunction(()=>document.querySelectorAll('.assistant .message-body').length===2);
    assert.equal(calls.at(-1).messages.length,3);
    assert.equal(navigation.length,0,'Enter or click navigated');
    assert.equal(await page.locator('.message-body img').count(),0);
    assert.equal(await page.evaluate(()=>!!window.hacked),false);
    await page.locator('#chatInput').fill('linha 1');await page.locator('#chatInput').press('Shift+Enter');await page.locator('#chatInput').type('linha 2');
    assert.equal(await page.locator('#chatInput').inputValue(),'linha 1\nlinha 2');
    const before=calls.length;
    await page.locator('#chatInput').fill('[slow] parar');await page.locator('#sendBtn').click();await page.waitForTimeout(180);await page.locator('#stopBtn').click();
    await page.waitForFunction(()=>!document.querySelector('#stopBtn').hidden===false);
    assert.match(await page.locator('#messages').innerText(),/Geração interrompida/);
    assert.equal(await page.locator('.message.error').count(),0);
    assert.equal(calls.length,before+1);
    await page.waitForTimeout(100);
    await page.locator('#chatInput').fill('[slow] responder na conversa original');await page.locator('#sendBtn').click();await page.locator('#newConversation').click();
    await page.waitForTimeout(3900);
    assert.equal(await page.locator('.message').count(),0,'old response leaked into new conversation');
    await page.locator('.conversation-button').nth(1).click();
    assert.match(await page.locator('#messages').innerText(),/responder na conversa original/);
    await page.screenshot({path:path.join(results,'dashboard-desktop.png'),fullPage:true});
    assert.deepEqual(external,[]);assert.deepEqual(errors,[]);assert.ok(preflights>0);
    report.push({test:'browser',enter:true,click:true,navigation:0,preflights,safeMarkdown:true,abort:true,multiConversation:true});

    // PNG uses manual Canvas painting, and SVG contains only safe escaped text.
    await page.locator('#exportFormat').selectOption('png');
    const pngDownload=page.waitForEvent('download');await page.locator('#exportBtn').click();const png=await pngDownload;const pngPath=path.join(results,'export-conversation.png');await png.saveAs(pngPath);
    assert.ok(fs.readFileSync(pngPath).subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])));
    const dimensions=await page.evaluate(async data=>{const image=new Image();image.src='data:image/png;base64,'+data;await image.decode();return [image.width,image.height];},fs.readFileSync(pngPath).toString('base64'));
    assert.deepEqual(dimensions,[1000,1800]);
    for(const scope of ['dashboard','session','conversation']){
      await page.locator('#exportScope').selectOption(scope);await page.locator('#exportFormat').selectOption('svg');const wait=page.waitForEvent('download');await page.locator('#exportBtn').click();const download=await wait;const dest=path.join(results,`export-${scope}.svg`);await download.saveAs(dest);const text=fs.readFileSync(dest,'utf8');assert.ok(text.startsWith('<svg '));assert.equal(text.includes(token),false);assert.doesNotMatch(text,/<script|<foreignObject|<img/);
    }
    report.push({test:'exports',pngDimensions:dimensions,svgScopes:3,tokenExcluded:true});

    const messagesBefore=await page.locator('.message').count();await page.reload();await page.waitForFunction(()=>document.querySelector('#sessionStatus').textContent==='Pronta');assert.equal(await page.locator('.message').count(),messagesBefore);await page.locator('#toggleSession').click();
    nextError={status:429,code:'model_busy'};await page.locator('#chatInput').fill('teste ocupado');await page.locator('#sendBtn').click();await page.waitForSelector('.message.error');assert.match(await page.locator('.message.error').last().innerText(),/ocupado/);
    nextError={status:503,code:'model_missing'};await page.locator('#refreshStatus').click();await page.waitForFunction(()=>document.querySelector('#sessionStatus').textContent==='Sem modelo');
    assert.equal(await page.locator('#sendBtn').isDisabled(),true);await page.locator('#retryReady').click();await page.waitForFunction(()=>document.querySelector('#sessionStatus').textContent==='Pronta');
    nextError={status:401,code:'unauthorized'};await page.locator('#chatInput').fill('teste sessão');await page.locator('#sendBtn').click();await page.waitForFunction(()=>!document.querySelector('#connectBtn').hidden);assert.equal(await page.evaluate(()=>localStorage.getItem('hadix.chat')),null);
    report.push({test:'persistence-errors',reload:true,busy:true,modelMissing:true,unauthorized:true});
    assert.match(page.url(),/\/login\/$/);assert.equal(await page.evaluate(()=>sessionStorage.getItem('hadix.session')),null);await page.screenshot({path:path.join(results,'login-desktop.png')});
    await page.locator('#apiToken').fill(token);await page.locator('#rememberToken').uncheck();await page.locator('#loginBtn').click();await page.waitForFunction(()=>document.querySelector('#sessionStatus').textContent==='Pronta');await page.reload();await page.waitForFunction(()=>document.querySelector('#sessionStatus').textContent==='Pronta');assert.equal(await page.evaluate(()=>localStorage.getItem('hadix.chat')),null);
    await page.setViewportSize({width:390,height:844});await page.screenshot({path:path.join(results,'dashboard-mobile.png'),fullPage:true});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    await page.locator('#logoutBtn').click();assert.equal(await page.locator('#dashboard').isVisible(),false);assert.match(page.url(),/\/login\/$/);report.push({test:'login-routing',login:true,tabSession:true,logout:true});await context.close();

    // API limits: preserve long history in UI but only send a bounded context.
    const bounded=await browser.newContext();await bounded.addInitScript(({base,token})=>{localStorage.setItem('hadix.chat',JSON.stringify({base,token}));localStorage.setItem('hadix.conversations.v1',JSON.stringify({selected:'long',conversations:[{id:'long',title:'Histórico longo',messages:Array.from({length:30},(_,i)=>({id:String(i),role:i%2?'assistant':'user',state:'complete',content:'x'.repeat(1000)}))}]}));},{base:apiURL,token});
    const limited=await bounded.newPage();await limited.goto(siteURL+'/app/');await limited.waitForFunction(()=>document.querySelector('#sessionStatus').textContent==='Pronta');await limited.locator('#chatInput').fill('Continue');await limited.locator('#sendBtn').click();await limited.waitForFunction(()=>document.querySelector('#stopBtn').hidden);assert.ok(calls.at(-1).messages.length<=24);assert.ok(calls.at(-1).messages.reduce((n,m)=>n+m.content.length,0)<=16000);assert.equal(await limited.locator('.message').count(),32);
    await limited.locator('#toggleSession').click();await limited.locator('#exportFormat').selectOption('svg');const zipWait=limited.waitForEvent('download');await limited.locator('#exportBtn').click();const zip=await zipWait;assert.match(zip.suggestedFilename(),/\.zip$/);await zip.saveAs(path.join(results,'export-long.zip'));report.push({test:'context-and-pagination',max24:true,max16000:true,historyPreserved:true,zip:true});await bounded.close();

    // Execute the compiled extension handler behind a tiny VS Code API adapter.
    // The real HTML is loaded under the extension's nonce CSP and connect-src 'none'.
    const Module=require('node:module');const originalLoad=Module._load;const commands=new Map(),secrets=new Map(),workspaceState=new Map(),globalState=new Map();let handler,hostPage,htmlResolve;let savedExport='';
    const htmlReady=new Promise(resolve=>htmlResolve=resolve);
    const uri=p=>({fsPath:p});
    const mockPanel={reveal(){},dispose(){disposeHost();},onDidDispose(fn){disposeHost=fn;return{dispose(){}};},webview:{onDidReceiveMessage(fn){handler=fn;return{dispose(){}};},postMessage(m){return hostPage?.evaluate(m=>window.dispatchEvent(new MessageEvent('message',{data:m})),m);},set html(value){hostHTML=value;htmlResolve();}}};
    const vscode={ViewColumn:{One:1},ConfigurationTarget:{Global:1},Uri:{file:uri,joinPath:(u,...p)=>uri(path.join(u.fsPath,...p))},commands:{registerCommand(name,fn){commands.set(name,fn);return{dispose(){}};},executeCommand(name){return commands.get(name)?.();}},window:{createWebviewPanel(){return mockPanel;},showErrorMessage(){throw new Error('unexpected extension error');},showSaveDialog:async options=>{savedExport=path.join(results,options.defaultUri.fsPath.split(/[\\/]/).pop());return uri(savedExport);}},env:{clipboard:{writeText:async()=>{}}},workspace:{getConfiguration(){return{get:key=>key==='transport'?'bridge':apiURL,update:async()=>{}};},fs:{readFile:async u=>fs.readFileSync(u.fsPath),writeFile:async(u,data)=>fs.writeFileSync(u.fsPath,data)}}};
    Module._load=function(name,parent,isMain){return name==='vscode'?vscode:originalLoad.call(this,name,parent,isMain);};
    const extension=require(path.join(root,'vscode-extension/out/extension.js'));Module._load=originalLoad;
    extension.activate({extensionUri:uri(path.join(root,'vscode-extension')),subscriptions:[],secrets:{get:async k=>secrets.get(k),store:async(k,v)=>secrets.set(k,v),delete:async k=>secrets.delete(k)},workspaceState:{get:k=>workspaceState.get(k),update:async(k,v)=>workspaceState.set(k,v)},globalState:{get:k=>globalState.get(k),update:async(k,v)=>globalState.set(k,v)}});
    await commands.get('hadix.openDashboard')();await htmlReady;
    const hc=await browser.newContext({viewport:{width:1440,height:1000}});hostPage=await hc.newPage();const violations=[],hostRequests=[];
    await hostPage.exposeBinding('hostPost',(_source,m)=>handler(m));
    await hostPage.addInitScript(()=>{window.acquireVsCodeApi=()=>({postMessage:m=>void window.hostPost(m),setState(){},getState(){return null;}});window.cspViolations=[];document.addEventListener('securitypolicyviolation',e=>window.cspViolations.push(e.violatedDirective));});
    hostPage.on('pageerror',e=>violations.push(e.message));hostPage.on('request',r=>hostRequests.push(r.url()));
    await hostPage.goto(siteURL+'/webview');await hostPage.getByRole('button',{name:'Conectar API'}).click();await hostPage.locator('#apiToken').fill(token);await hostPage.locator('#loginBtn').click();await hostPage.waitForFunction(()=>document.querySelector('#sessionStatus').textContent==='Pronta');
    await hostPage.locator('#chatInput').fill('Ponte do VS Code');await hostPage.locator('#chatInput').press('Enter');await hostPage.waitForSelector('.assistant .message-body');
    assert.equal(await hostPage.evaluate(()=>localStorage.getItem('hadix.chat')),null);assert.ok(secrets.size===1);
    await hostPage.locator('#toggleSession').click();await hostPage.locator('#exportBtn').click();await hostPage.waitForFunction(()=>document.querySelector('#exportNotice').textContent==='Imagem salva.');assert.ok(fs.readFileSync(savedExport).subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])));
    assert.deepEqual(await hostPage.evaluate(()=>window.cspViolations),[]);assert.deepEqual(violations,[]);assert.deepEqual(hostRequests,[siteURL+'/webview']);assert.equal(JSON.stringify([...workspaceState.values()]).includes(token),false);
    await hostPage.screenshot({path:path.join(results,'dashboard-webview.png'),fullPage:true});report.push({test:'compiled-extension-bridge',strictCSP:true,webviewFetches:0,hostFetch:true,secretStorage:true,savePNG:true});
    disposeHost();await hc.close();
    fs.writeFileSync(path.join(results,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
  } finally { disposeHost();await browser.close();apiServer.closeAllConnections();apiServer.close();site.closeAllConnections();site.close(); }
})().catch(err=>{console.error(err);process.exitCode=1;});
