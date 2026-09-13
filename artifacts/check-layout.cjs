const { chromium } = require('C:/Users/typr/AppData/Local/npm-cache/_npx/e41f203b7505f1fb/node_modules/playwright');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = process.cwd();
const types = { '.html':'text/html; charset=utf-8', '.css':'text/css', '.js':'text/javascript', '.svg':'image/svg+xml', '.png':'image/png' };
const server = http.createServer((req,res) => {
 const file = path.resolve(root, '.' + (req.url === '/' ? '/index.html' : req.url.split('?')[0]));
 if (!file.startsWith(root + path.sep) || !fs.existsSync(file)) {res.writeHead(404);res.end();return;}
 res.setHeader('Content-Type',types[path.extname(file)] || 'application/octet-stream');fs.createReadStream(file).pipe(res);
});
(async()=>{
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const url = `http://127.0.0.1:${server.address().port}`;
 const browser = await chromium.launch({headless:true, executablePath:'C:/Users/typr/AppData/Local/ms-playwright/chromium-1237/chrome-win64/chrome.exe'});
 const report=[];
 try {
 for(const width of [1440,1024,810,768,390,320]){
  const page=await browser.newPage({viewport:{width,height:900},deviceScaleFactor:1});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(url,{waitUntil:'networkidle'});await page.waitForTimeout(1100);
  assert.equal(await page.locator('#mobileNav').isVisible(),false);
  assert.deepEqual(errors,[]);
  const metrics=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,brokenImages:[...document.images].filter(i=>!i.complete||!i.naturalWidth).length,brokenLinks:[...document.querySelectorAll('a[href^="#"]')].filter(a=>!document.querySelector(a.hash)).length}));
  assert.ok(metrics.scrollWidth<=width,JSON.stringify(metrics));assert.equal(metrics.brokenImages,0);assert.equal(metrics.brokenLinks,0);
  if(width<=800){await page.locator('#menuToggle').click();assert.equal(await page.locator('#mobileNav').isVisible(),true);await page.keyboard.press('Escape');assert.equal(await page.locator('#mobileNav').isVisible(),false);await page.locator('#menuToggle').click();await page.locator('#mobileNav a').first().click();assert.equal(await page.locator('#mobileNav').isVisible(),false);}
  for(let y=0;y<await page.evaluate(()=>document.body.scrollHeight);y+=650){await page.evaluate(y=>scrollTo(0,y),y);await page.waitForTimeout(60);}
  await page.evaluate(()=>scrollTo(0,0));await page.waitForTimeout(1000);
  if([1440,390].includes(width)) await page.screenshot({path:`artifacts/layout-${width}.png`,fullPage:true});
  report.push({width,...metrics,errors,menu:'passed'});await page.close();
 }
 for(const mode of ['reduced-motion','blocked-gsap','no-javascript']){
  const context=await browser.newContext({viewport:{width:390,height:844},reducedMotion:mode==='reduced-motion'?'reduce':'no-preference',javaScriptEnabled:mode!=='no-javascript'});
  if(mode==='blocked-gsap')await context.route('**/assets/vendor/**',route=>route.abort());
  const page=await context.newPage();await page.goto(url,{waitUntil:'networkidle'});
  assert.equal(await page.locator('h1').isVisible(),true);assert.equal(await page.locator('#cta h2').isVisible(),true);
  if(mode!=='no-javascript'){await page.locator('#menuToggle').click();assert.equal(await page.locator('#mobileNav').isVisible(),true);}
  else { assert.equal(await page.locator('#mobileNav').isVisible(),true); }
  if(mode==='reduced-motion')assert.equal(await page.evaluate(()=>gsap.getTweensOf(document.querySelectorAll('.globe-art, .hero-copy > *, .stack-stage img, .pipeline-card, .agent-card')).length),0);
  report.push({mode,passed:true});await context.close();
 }
 fs.writeFileSync('artifacts/layout-checks.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
 } finally {await browser.close();server.close();}
})().catch(e=>{console.error(e);server.close();process.exitCode=1;});
