// A single low-poly wire surface morphs with the four product scenes.
window.createAdaptiveSpace = function () {
  const backdrop=document.querySelector('.spatial-backdrop');
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const {THREE:T,gsap}=window;
  let renderer;
  const canvas=document.createElement('canvas');canvas.className='adaptive-canvas';canvas.setAttribute('aria-hidden','true');
  try { if(!T)return null;renderer=new T.WebGLRenderer({canvas,alpha:true,antialias:true,powerPreference:'low-power'}); } catch { return null; }
  backdrop.append(canvas);renderer.setPixelRatio(Math.min(devicePixelRatio,1.4));
  const scene=new T.Scene(),camera=new T.PerspectiveCamera(40,1,.1,40);camera.position.z=7;
  const columns=48,rows=24,count=(columns+1)*(rows+1),targets=[];
  for(let shape=0;shape<4;shape++){
    const data=new Float32Array(count*3);
    for(let j=0;j<=rows;j++)for(let i=0;i<=columns;i++){
      const u=i/columns*Math.PI*2,v=j/rows*Math.PI*2,k=(j*(columns+1)+i)*3;
      let x,y,z;
      if(shape===0){const lat=j/rows*Math.PI;x=Math.cos(u)*Math.sin(lat)*1.8;y=Math.cos(lat)*1.8;z=Math.sin(u)*Math.sin(lat)*1.8;}
      if(shape===1){const radius=1.25+.22*Math.cos(v*4);x=Math.sign(Math.cos(u))*Math.pow(Math.abs(Math.cos(u)),.45)*radius;y=(j/rows-.5)*3.3;z=Math.sign(Math.sin(u))*Math.pow(Math.abs(Math.sin(u)),.45)*radius;}
      if(shape===2){const along=(i/columns-.5)*5.5;x=along;y=Math.sin(i/columns*Math.PI*2)*.7+Math.cos(v)*.44;z=Math.cos(i/columns*Math.PI*2)*.6+Math.sin(v)*.44;}
      if(shape===3){const r=1.45+.5*Math.cos(v);x=r*Math.cos(u);y=r*Math.sin(u);z=.5*Math.sin(v)+.3*Math.sin(u*4);}
      data.set([x,y,z],k);
    }targets.push(data);
  }
  const geometry=new T.BufferGeometry();geometry.setAttribute('position',new T.BufferAttribute(targets[0].slice(),3));
  const indices=[];
  for(let j=0;j<=rows;j++)for(let i=0;i<=columns;i++){const k=j*(columns+1)+i;if(i<columns)indices.push(k,k+1);if(j<rows)indices.push(k,k+columns+1);}
  geometry.setIndex(indices);
  const material=new T.LineBasicMaterial({color:0xa8cf95,transparent:true,opacity:.12,depthWrite:false});
  const mesh=new T.LineSegments(geometry,material);mesh.frustumCulled=false;scene.add(mesh);
  const state={mix:1,rx:0,ry:0,turn:0},pointer={x:0,y:0};let current=0,from=targets[0],to=targets[0],frame=0,last=0,lost=false;
  function draw(){if(lost)return;const positions=geometry.attributes.position.array;for(let i=0;i<positions.length;i++)positions[i]=from[i]+(to[i]-from[i])*state.mix;geometry.attributes.position.needsUpdate=true;mesh.rotation.set(state.rx+pointer.y,state.ry+pointer.x+state.turn,.12);renderer.render(scene,camera);}
  function tick(now){frame=0;if(document.hidden||lost)return;const delta=Math.min((now-last)/1000||0,.04);last=now;state.turn+=delta*.025;draw();if(!reduced.matches)frame=requestAnimationFrame(tick);}
  function resume(){cancelAnimationFrame(frame);frame=0;if(!document.hidden&&!lost){draw();last=performance.now();if(!reduced.matches)frame=requestAnimationFrame(tick);}}
  function resize(){renderer.setSize(innerWidth,innerHeight,false);camera.aspect=innerWidth/innerHeight;camera.updateProjectionMatrix();const mobile=innerWidth<=800;mesh.position.set(mobile?0:1.8,mobile?-.4:.2,-1);mesh.scale.setScalar(mobile?.9:1.15);draw();}
  function setScene(index,instant=false){
    current=index;backdrop.dataset.scene=['hero','platform','pipeline','agents'][index];
    from=geometry.attributes.position.array.slice();to=targets[index];gsap.killTweensOf(state);state.mix=0;
    const duration=instant||reduced.matches?0:1.5;
    gsap.to(state,{mix:1,rx:[.1,.3,.25,.35][index],ry:[0,.55,-.15,.35][index],duration,ease:'power2.inOut',onUpdate:draw});
    gsap.to(material,{opacity:[.035,.12,.2,.16][index],duration,ease:'sine.inOut',overwrite:true,onUpdate:draw});
    gsap.to(backdrop,{'--grid-tilt':[61,48,66,55][index]+'deg','--grid-shift':[0,28,-20,14][index]+'px',duration,ease:'power2.inOut'});
  }
  const xTo=gsap.quickTo(pointer,'x',{duration:1.2,ease:'power2.out',onUpdate:draw});
  const yTo=gsap.quickTo(pointer,'y',{duration:1.2,ease:'power2.out',onUpdate:draw});
  addEventListener('pointermove',e=>{if(reduced.matches||e.pointerType!=='mouse'||document.hidden)return;xTo((e.clientX/innerWidth-.5)*.16);yTo((e.clientY/innerHeight-.5)*.1);},{passive:true});
  document.addEventListener('visibilitychange',resume);
  reduced.addEventListener('change',()=>{gsap.killTweensOf(pointer);pointer.x=pointer.y=0;setScene(current,true);resume();});
  canvas.addEventListener('webglcontextlost',e=>{e.preventDefault();lost=true;cancelAnimationFrame(frame);canvas.hidden=true;});
  addEventListener('resize',resize);resize();resume();
  return {setScene};
};

