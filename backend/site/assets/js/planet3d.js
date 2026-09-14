// Local, procedural WebGL planet. No textures, fetch or module imports: file:// safe.
window.createPortalPlanet = function () {
  if (!window.THREE) return null;
  const T = window.THREE, main = document.getElementById('main'), anchor = document.querySelector('.globe-stage');
  const canvas = document.createElement('canvas');canvas.className='planet-canvas';canvas.setAttribute('aria-hidden','true');
  let renderer;
  try { renderer = new T.WebGLRenderer({canvas,alpha:true,antialias:true,powerPreference:'low-power'}); } catch { return null; }
  main.append(canvas);
  renderer.setPixelRatio(Math.min(devicePixelRatio,1.6));renderer.setClearColor(0x080909,0);
  const scene = new T.Scene(), camera = new T.PerspectiveCamera(38,1,.03,60);
  const root = new T.Group(), globe = new T.Group();root.add(globe);scene.add(root);
  const sphere = new T.Mesh(new T.SphereGeometry(1,64,48),new T.MeshPhongMaterial({color:0x101c19,emissive:0x020806,shininess:35,transparent:true,opacity:.97}));globe.add(sphere);
  scene.add(new T.AmbientLight(0x7baca0,.9));
  const key=new T.DirectionalLight(0xb6e6a1,2.2);key.position.set(-3,3,4);scene.add(key);
  const rim=new T.DirectionalLight(0x65bad4,1.6);rim.position.set(3,-1,-2);scene.add(rim);
  const gridMat=new T.LineBasicMaterial({color:0x8fb498,transparent:true,opacity:.32});
  const v=(lat,lon,r=1.008)=>{const a=lat*Math.PI/180,b=lon*Math.PI/180;return new T.Vector3(r*Math.cos(a)*Math.sin(b),r*Math.sin(a),r*Math.cos(a)*Math.cos(b));};
  function line(points,material,parent=globe){const line=new T.Line(new T.BufferGeometry().setFromPoints(points),material);parent.add(line);return line;}
  for(let lat=-75;lat<=75;lat+=15){const points=[];for(let lon=0;lon<=360;lon+=3)points.push(v(lat,lon));line(points,gridMat);}
  for(let lon=0;lon<360;lon+=20){const points=[];for(let lat=-90;lat<=90;lat+=3)points.push(v(lat,lon));line(points,gridMat);}
  const continents=[[[37,-8],[32,12],[31,33],[12,44],[8,50],[-12,40],[-34,19],[-25,14],[4,8],[8,-15],[24,-17],[37,-8]],[[36,-9],[44,-9],[49,1],[56,8],[70,25],[65,35],[55,30],[50,55],[42,40],[37,24],[44,14],[42,3],[36,-9]],[[12,-81],[9,-65],[0,-50],[-5,-35],[-22,-42],[-35,-57],[-54,-68],[-44,-74],[-18,-70],[-5,-81],[12,-81]],[[70,-150],[59,-135],[49,-125],[30,-115],[18,-100],[22,-87],[30,-81],[44,-66],[52,-55],[60,-67],[68,-90],[70,-150]],[[70,30],[73,95],[62,140],[45,140],[25,120],[7,105],[22,90],[8,78],[26,62],[35,40]], [[-12,115],[-11,138],[-20,151],[-38,146],[-34,116],[-12,115]]];
  const landMat=new T.LineBasicMaterial({color:0xbacbb2,transparent:true,opacity:.7});
  continents.forEach(poly=>line(poly.map(([a,b])=>v(a,b,1.014)),landMat));
  const hubs=[[51,0],[40,-74],[-23,-46],[30,31],[6,3],[48,17],[15,-17],[-1,37],[35,110]];
  const hubMat=new T.MeshBasicMaterial({color:0xd3f56b}), dotGeometry=new T.SphereGeometry(.015,8,8);
  hubs.forEach(([a,b])=>{const dot=new T.Mesh(dotGeometry,hubMat);dot.position.copy(v(a,b,1.03));globe.add(dot);});
  const routeMat=new T.LineBasicMaterial({color:0xd3f56b,transparent:true,opacity:.55});
  [[0,1],[0,3],[0,5],[1,2],[2,4],[4,6],[3,7],[5,8]].forEach(([a,b])=>{const points=[],p=v(...hubs[a]),q=v(...hubs[b]);for(let i=0;i<=48;i++){const t=i/48;points.push(p.clone().lerp(q,t).normalize().multiplyScalar(1.025+Math.sin(t*Math.PI)*.17));}line(points,routeMat);});
  const atmosphere=new T.Mesh(new T.SphereGeometry(1.035,48,32),new T.ShaderMaterial({transparent:true,depthWrite:false,blending:T.AdditiveBlending,uniforms:{},vertexShader:'varying vec3 n;varying vec3 e;void main(){vec4 p=modelViewMatrix*vec4(position,1.);n=normalize(normalMatrix*normal);e=normalize(-p.xyz);gl_Position=projectionMatrix*p;}',fragmentShader:'varying vec3 n;varying vec3 e;void main(){float rim=pow(1.-max(dot(normalize(n),normalize(e)),0.),3.);gl_FragColor=vec4(.32,.72,.58,rim*.45);}'}));globe.add(atmosphere);
  const rings=new T.Group();root.add(rings);
  [1.3,1.5].forEach((r,i)=>{const points=[];for(let j=0;j<=128;j++){const a=j/128*Math.PI*2;points.push(new T.Vector3(Math.cos(a)*r,Math.sin(a)*r,0));}const ring=line(points,new T.LineBasicMaterial({color:i?0x8ea985:0xbee69b,transparent:true,opacity:.22}),rings);ring.rotation.set(.9+i*.6,.4,i*.7);});
  const portal=new T.Mesh(new T.TorusGeometry(1.035,.009,8,128),new T.MeshBasicMaterial({color:0xbcebb0,transparent:true,opacity:0,blending:T.AdditiveBlending,depthTest:false}));root.add(portal);
  const state={progress:0};let enabled=false,failed=false,frame=0,time=0,last=0,home={x:0,y:0,scale:1},reduced=matchMedia('(prefers-reduced-motion: reduce)');
  function resize(){const r=main.getBoundingClientRect(),a=anchor.getBoundingClientRect();renderer.setSize(r.width,r.height,false);camera.aspect=r.width/r.height;camera.updateProjectionMatrix();const height=2*Math.tan(19*Math.PI/180)*5.8;home={x:((a.left+a.width/2-r.left)/r.width-.5)*height*camera.aspect,y:(.5-(a.top+a.height/2-r.top)/r.height)*height,scale:a.width*.39/r.height*height};draw();}
  function draw(){if(failed)return;const p=state.progress,center=T.MathUtils.smoothstep(p,0,.58);root.position.set(home.x*(1-center),home.y*(1-center),0);root.scale.setScalar(home.scale);camera.position.set(0,0,5.8+(home.scale*.25-5.8)*p);globe.rotation.set(.15,time*.065-.4,-.15);rings.rotation.z=time*.025;portal.material.opacity=Math.sin(p*Math.PI)*.8;portal.scale.setScalar(1+p*.15);renderer.render(scene,camera);}
  function tick(now){frame=0;if(!enabled||document.hidden||failed)return;const dt=Math.min((now-last)/1000||0,.04);last=now;if(!reduced.matches)time+=dt;draw();if(!reduced.matches)frame=requestAnimationFrame(tick);}
  function setEnabled(value){enabled=value&&!failed;canvas.style.visibility=enabled?'visible':'hidden';if(frame)cancelAnimationFrame(frame);frame=0;if(enabled){last=performance.now();draw();if(!reduced.matches)frame=requestAnimationFrame(tick);}}
  canvas.addEventListener('webglcontextlost',event=>{event.preventDefault();failed=true;setEnabled(false);document.body.classList.remove('planet-ready');});
  const observer=new ResizeObserver(resize);observer.observe(main);observer.observe(anchor);
  document.getElementById('hero').addEventListener('scroll',resize,{passive:true});
  document.addEventListener('visibilitychange',()=>setEnabled(enabled));reduced.addEventListener('change',()=>setEnabled(enabled));
  resize();document.body.classList.add('planet-ready');
  return {canvas,state,draw,resize,setEnabled,get ready(){return !failed;}};
};
