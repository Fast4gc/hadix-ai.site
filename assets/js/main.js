// Navigation remains usable if GSAP is unavailable (normal document fallback).
const toggle = document.getElementById('menuToggle');
const mobileNav = document.getElementById('mobileNav');
function setMenu(open, focus = false) {
  toggle.setAttribute('aria-expanded', String(open));
  toggle.setAttribute('aria-label', open ? 'Fechar menu' : 'Abrir menu');
  mobileNav.hidden = !open;
  if (focus) toggle.focus();
}
toggle.addEventListener('click', () => setMenu(mobileNav.hidden));
mobileNav.addEventListener('click', e => { if (e.target.closest('a')) setMenu(false); });
document.addEventListener('keydown', e => { if(e.key === 'Escape') setMenu(false, true); });
document.addEventListener('click', e => { if(!mobileNav.contains(e.target) && !toggle.contains(e.target)) setMenu(false); });
matchMedia('(min-width:801px)').addEventListener('change', e => { if(e.matches) setMenu(false); });

if (window.gsap) initializeScenes();
function initializeScenes() {
  const {gsap} = window;
  const ids = ['hero','platform','pipeline','agents'];
  const names = ['Início','Plataforma','Pipeline','Agentes'];
  const panels = ids.map(id => document.getElementById(id));
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const cta = document.getElementById('cta');
  panels[3].append(cta);
  const controls = document.createElement('nav');
  controls.className = 'scene-controls';
  controls.setAttribute('aria-label','Navegar entre telas');
  controls.innerHTML = '<span class="scene-current" aria-live="polite"></span><span>/ 04</span><span class="scene-hint">ROLE PARA EXPLORAR</span><button type="button" aria-label="Tela anterior">↑</button><button type="button" aria-label="Próxima tela">↓</button>';
  document.body.append(controls);
  const [previous,next] = controls.querySelectorAll('button');
  const orbit = document.createElement('div');
  orbit.className = 'scene-orbit';orbit.setAttribute('aria-hidden','true');
  document.getElementById('main').prepend(orbit);
  panels.forEach(panel => {panel.classList.add('scene');panel.tabIndex = -1;});
  document.body.classList.add('scene-mode');
  let current = Math.max(0, ids.indexOf(location.hash.slice(1) === 'cta' ? 'agents' : location.hash.slice(1)));
  let busy = false, cooldown = 0, wheelTotal = 0, wheelTime = 0, transition;
  const assembly = createAssembly(gsap);
  const adaptiveSpace = window.createAdaptiveSpace?.();
  const planet = window.createPortalPlanet?.();
  const ambient = gsap.to('.globe-art',{rotation:5,duration:12,ease:'sine.inOut',repeat:-1,yoyo:true,paused:true});
  function update() {
    controls.querySelector('.scene-current').textContent = `0${current+1} / ${names[current]}`;
    previous.disabled = current === 0; next.disabled = current === 3;
    document.querySelectorAll('.section-index a,.nav a').forEach(link => {
      const active = link.hash === '#' + ids[current];link.classList.toggle('active',active);
      if(active)link.setAttribute('aria-current','page');else link.removeAttribute('aria-current');
    });
    document.getElementById('scrollBar').style.transform = `scaleX(${(current+1)/4})`;
    if(current === 0 && !reduced.matches && !document.hidden)ambient.resume();else ambient.pause();
  }
  function enter(index) {
    if(index === 1) { if(reduced.matches)assembly.progress(1).pause();else assembly.restart(); }
    else assembly.pause();
    if(planet){planet.state.progress=0;planet.canvas.style.opacity='1';planet.setEnabled(index===0);planet.resize();}
  }
  function navigate(index, {historyMode='push',focus=false,target=null}={}) {
    index = Math.max(0,Math.min(3,index));
    if(busy) return;
    if(index === current) {if(target)target.scrollIntoView({block:'start',behavior:reduced.matches?'instant':'smooth'});return;}
    const origin = current;
    const outgoing = panels[current], incoming = panels[index], direction = index > current ? 1 : -1;
    busy = true; current = index; wheelTotal=0;
    setMenu(false);
    outgoing.inert = true;outgoing.setAttribute('aria-hidden','true');
    incoming.inert = false;incoming.removeAttribute('aria-hidden');incoming.scrollTop=0;
    if(historyMode==='push') history.pushState(null,'','#'+ids[index]);
    update();
    adaptiveSpace?.setScene(index);
    assembly.pause();
    if(index===1)assembly.progress(reduced.matches?1:0).pause();
    const duration = reduced.matches ? 0 : .85;
    const children = incoming.querySelectorAll('.hero-copy, .globe-stage, .section-heading, .architecture, .pipeline-grid, .agent-grid');
    transition = gsap.timeline({onComplete:()=>{
      gsap.set(outgoing,{autoAlpha:0,y:0,scale:1});
      gsap.set(incoming,{clearProps:'transform'});
      gsap.set(children,{clearProps:'transform,opacity,visibility'});
      gsap.set(outgoing.querySelectorAll('.hero-copy,.hero-bottom,.scene-label,.globe-tag'),{clearProps:'transform,opacity,visibility'});
      busy=false;cooldown=performance.now()+250;enter(index);
      if(focus || outgoing.contains(document.activeElement))incoming.focus({preventScroll:true});
      if(target)target.scrollIntoView({block:'start',behavior:'instant'});
    }});
    if(planet?.ready && !reduced.matches && ((origin===0 && index===1)||(origin===1 && index===0))){
      const forward=index===1;
      planet.state.progress=forward?0:1;planet.setEnabled(true);planet.resize();
      gsap.set(planet.canvas,{opacity:forward?1:0});
      gsap.set(incoming,{autoAlpha:0,y:0,scale:forward?.92:1});
      transition.to(outgoing.querySelectorAll('.hero-copy,.hero-bottom,.scene-label,.globe-tag'),{autoAlpha:0,y:-18,duration:.4,ease:'power2.in'},0)
        .to(planet.state,{progress:forward?1:0,duration:1.65,ease:'power3.inOut',onUpdate:planet.draw},0)
        .to(outgoing,{autoAlpha:0,duration:.6,ease:'power2.inOut'},forward?.65:0)
        .to(planet.canvas,{opacity:forward?0:1,duration:forward?.55:.5,ease:'sine.inOut'},forward?1.1:.15)
        .to(incoming,{autoAlpha:1,scale:1,duration:.8,ease:'power3.out'},forward?.95:.8)
        .to(orbit,{x:forward?-180:0,scale:forward?.8:1,rotation:forward?65:0,duration:1.65,ease:'power2.inOut'},0);
      return;
    }
    if(planet){planet.state.progress=0;planet.setEnabled(index===0);}
    transition.to(outgoing,{autoAlpha:0,y:-direction*60,scale:.96,duration:duration*.65,ease:'power2.in'},0)
      .fromTo(incoming,{autoAlpha:0,y:direction*70,scale:1.035},{autoAlpha:1,y:0,scale:1,duration,ease:'power3.out'},duration*.2)
      .fromTo(children,{y:direction*24},{y:0,duration:duration*.7,stagger:reduced.matches?0:.06,ease:'power2.out'},duration*.3)
      .to(orbit,{x:[0,-180,80,-70][index],rotation:index*65,scale:[1,.8,1.25,.95][index],duration,ease:'power2.inOut'},0);
  }
  panels.forEach((panel,i)=>{gsap.set(panel,{autoAlpha:i===current?1:0});panel.inert=i!==current;if(i!==current)panel.setAttribute('aria-hidden','true');});
  update();enter(current);adaptiveSpace?.setScene(current,true);
  if(location.hash==='#cta')requestAnimationFrame(()=>cta.scrollIntoView());
  previous.addEventListener('click',()=>navigate(current-1,{focus:true}));
  next.addEventListener('click',()=>navigate(current+1,{focus:true}));
  document.addEventListener('click',e=>{
    const link=e.target.closest('a[href^="#"]');if(!link)return;
    const id=link.hash.slice(1),index=ids.indexOf(id==='cta'?'agents':id==='main'?'hero':id);
    if(index<0)return;e.preventDefault();navigate(index,{focus:true,target:id==='cta'?cta:null});
  });
  function restoreHash(){
    if(transition && busy)transition.progress(1);
    const id=location.hash.slice(1);navigate(Math.max(0,ids.indexOf(id==='cta'?'agents':id)),{historyMode:'none',target:id==='cta'?cta:null});
  }
  addEventListener('popstate',restoreHash);addEventListener('hashchange',restoreHash);
  function boundary(direction){const panel=panels[current];return direction>0 ? panel.scrollTop+panel.clientHeight>=panel.scrollHeight-3 : panel.scrollTop<=2;}
  document.getElementById('main').addEventListener('wheel',e=>{
    if(e.ctrlKey || Math.abs(e.deltaX)>Math.abs(e.deltaY) || !mobileNav.hidden)return;
    const direction=Math.sign(e.deltaY);if(!direction)return;
    if(busy || performance.now()<cooldown){e.preventDefault();return;}
    if(!boundary(direction)){wheelTotal=0;return;}
    e.preventDefault();const now=performance.now();
    if(now-wheelTime>180 || Math.sign(wheelTotal)!==direction)wheelTotal=0;
    wheelTime=now;wheelTotal+=e.deltaY*(e.deltaMode===1?16:e.deltaMode===2?innerHeight:1);
    if(Math.abs(wheelTotal)>45){navigate(current+direction);wheelTotal=0;}
  },{passive:false});
  document.addEventListener('keydown',e=>{
    if(e.target.closest('input,textarea,select,button') || e.target.isContentEditable || !mobileNav.hidden)return;
    const direction=['ArrowDown','PageDown',' '].includes(e.key)?1:['ArrowUp','PageUp'].includes(e.key)?-1:0;
    if(direction && boundary(direction)){e.preventDefault();navigate(current+direction,{focus:true});}
    if(e.key==='Home'){e.preventDefault();navigate(0,{focus:true});}
    if(e.key==='End'){e.preventDefault();navigate(3,{focus:true});}
  });
  let touch=null;
  const main=document.getElementById('main');
  main.addEventListener('touchstart',e=>{if(e.touches.length===1)touch={x:e.touches[0].clientX,y:e.touches[0].clientY,top:boundary(-1),bottom:boundary(1)};else touch=null;},{passive:true});
  main.addEventListener('touchend',e=>{
    if(!touch || busy || performance.now()<cooldown)return;
    const dy=touch.y-e.changedTouches[0].clientY,dx=touch.x-e.changedTouches[0].clientX;
    if(Math.abs(dy)>65 && Math.abs(dy)>Math.abs(dx) && (dy>0?touch.bottom:touch.top))navigate(current+Math.sign(dy));touch=null;
  },{passive:true});
  main.addEventListener('touchcancel',()=>touch=null,{passive:true});
  reduced.addEventListener('change',()=>{if(busy)transition.progress(1);if(reduced.matches)assembly.progress(1).pause();update();});
  document.addEventListener('visibilitychange',()=>{update();if(document.hidden)assembly.pause();else if(current===1 && !reduced.matches)assembly.resume();});
}
function createAssembly(gsap) {
  const modules=[...document.querySelectorAll('.assembly-module')];
  const cards=['perception','memory','reasoning','action'].map(name=>document.querySelector('.layer-'+name));
  const labels=['Percebendo sinais','Conectando contexto','Construindo raciocínio','Preparando a ação'];
  const status=document.getElementById('assemblyStatus'), percent=document.getElementById('assemblyPercent');
  const paths=modules.map(m=>[...m.querySelectorAll(':scope > g > path')].slice(0,3));
  const connectors=document.querySelector('.assembly-links path'),length=connectors.getTotalLength();
  const timeline=gsap.timeline({paused:true,onUpdate(){const p=this.progress(),step=Math.min(3,Math.floor(p*4));percent.textContent=Math.round(p*100)+'%';status.textContent=p>.99?'04 / Sistema conectado':`0${step+1} / ${labels[step]}`;cards.forEach((card,i)=>{card.classList.toggle('active',i===step);card.classList.toggle('is-built',i<step);});}});
  modules.forEach((module,i)=>{
    // Draw the silhouette before the material arrives. Every layer has its own beat.
    timeline.fromTo(module,{autoAlpha:.08,y:32},{autoAlpha:1,y:0,duration:.65,ease:'power3.out'},i*.8)
      .fromTo(paths[i],{fillOpacity:0,strokeDasharray:(_,p)=>p.getTotalLength(),strokeDashoffset:(_,p)=>p.getTotalLength()},{strokeDashoffset:0,duration:.55,ease:'power2.inOut'},i*.8)
      .to(paths[i],{fillOpacity:1,duration:.32,ease:'sine.out'},i*.8+.38);
  });
  timeline.fromTo(connectors,{strokeDasharray:length,strokeDashoffset:length},{strokeDashoffset:0,duration:3.2,ease:'none'},0)
    .fromTo('.assembly-progress span',{scaleX:0},{scaleX:1,duration:3.2,ease:'none'},0);
  return timeline;
}
