const fs = require('node:fs');
// Stylized vector illustrations from the layout references, not an exact 3D reconstruction.
const f = n => n.toFixed(2);
const point = (lat, lon, radius = 222) => {
  const a = lat * Math.PI / 180, b = (lon + 20) * Math.PI / 180;
  const x = Math.cos(a) * Math.sin(b), y = -Math.sin(a), z = Math.cos(a) * Math.cos(b);
  const tilt = -.24;
  return [320 + radius * (x * Math.cos(tilt) - y * Math.sin(tilt)), 320 + radius * (x * Math.sin(tilt) + y * Math.cos(tilt)), z];
};
let globe = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 640"><defs><radialGradient id="g"><stop stop-color="#22281d" stop-opacity=".5"/><stop offset="1" stop-color="#080909" stop-opacity="0"/></radialGradient></defs><circle cx="320" cy="320" r="280" fill="url(#g)"/><g fill="none" stroke="#9eaa8e" stroke-width=".7"><circle cx="320" cy="320" r="222" opacity=".6"/>`;
function line(coords, color, opacity, width = .7) {
  return `<path d="${coords.map((p,i) => `${i?'L':'M'}${f(p[0])},${f(p[1])}`).join(' ')}" fill="none" stroke="${color}" stroke-opacity="${opacity}" stroke-width="${width}"/>`;
}
for(let lat=-75;lat<=75;lat+=15) {
  for(const back of [true,false]) {
    let run=[];
    for(let lon=-180;lon<=180;lon+=2) { const p=point(lat,lon); if((p[2]<0)===back) run.push(p); else if(run.length){globe+=line(run,'#acb49f',back?.10:.36);run=[];} }
    if(run.length) globe+=line(run,'#acb49f',back?.10:.36);
  }
}
for(let lon=-180;lon<180;lon+=15){const pts=[];for(let lat=-90;lat<=90;lat+=2)pts.push(point(lat,lon));globe+=line(pts,'#acb49f',point(0,lon)[2]<0?.09:.35);}
globe+='</g>';
// Deliberately simplified continental outlines; coordinates are illustrative.
const continents=[[[71,-160],[60,-147],[58,-132],[50,-127],[43,-125],[32,-117],[25,-110],[22,-106],[18,-103],[17,-96],[20,-90],[24,-88],[30,-90],[30,-82],[37,-76],[44,-66],[48,-54],[54,-60],[60,-65],[65,-80],[70,-100],[71,-160]],[[12,-81],[8,-77],[10,-67],[7,-60],[0,-50],[-5,-35],[-15,-39],[-22,-41],[-30,-50],[-40,-62],[-54,-68],[-49,-74],[-30,-71],[-17,-75],[-5,-81],[12,-81]],[[35,-6],[37,10],[32,25],[31,33],[16,43],[11,50],[0,42],[-12,40],[-26,33],[-35,19],[-28,15],[-16,12],[-5,11],[5,9],[5,-2],[10,-15],[22,-17],[35,-6]],[[36,-9],[44,-9],[48,-5],[50,2],[55,8],[58,5],[63,10],[70,25],[65,35],[60,30],[57,45],[52,53],[45,45],[42,40],[41,29],[38,24],[44,15],[43,10],[40,14],[43,3],[36,-9]],[[60,-45],[68,-30],[78,-20],[83,-40],[78,-63],[65,-52],[60,-45]],[[50,-5],[55,-6],[58,-3],[54,0],[50,-5]],[[57,45],[68,55],[72,90],[60,130],[50,140],[35,130],[25,120],[20,105],[5,103],[22,90],[8,77],[25,65],[30,48],[42,40]], [[-13,49],[-20,50],[-25,45],[-17,44],[-13,49]]];
for(const shape of continents){let run=[];for(const [lat,lon] of shape){const p=point(lat,lon,223);if(p[2]>-.1)run.push(p);else if(run.length){globe+=line(run,'#c3c9b9',.55,1);run=[];}}if(run.length)globe+=line(run,'#c3c9b9',.55,1);}
const nodes=[[40,-74],[51,0],[38,-9],[-23,-46],[6,3],[30,31],[48,17],[57,24],[15,-17],[-1,37]];
const hubs=nodes.map(p=>point(...p,225));
for(const [a,b] of [[0,1],[0,3],[1,2],[1,6],[2,8],[2,4],[4,3],[4,5],[5,9],[6,7]]){const p=hubs[a],q=hubs[b];globe+=`<path d="M${f(p[0])} ${f(p[1])} Q${f((p[0]+q[0])/2-20)} ${f((p[1]+q[1])/2-25)} ${f(q[0])} ${f(q[1])}" fill="none" stroke="#d3f56b" stroke-opacity=".5" stroke-width=".85"/>`;}
hubs.forEach((p,i)=>{globe+=`<circle cx="${f(p[0])}" cy="${f(p[1])}" r="${i%3===0?8:5}" fill="#080909" stroke="#d3f56b" stroke-opacity=".6" stroke-width=".7"/><circle cx="${f(p[0])}" cy="${f(p[1])}" r="2.2" fill="#d3f56b"/>`;});
globe+=`<g fill="none" stroke="#8c9978" stroke-width=".65"><ellipse cx="320" cy="320" rx="295" ry="65" transform="rotate(-35 320 320)" opacity=".28"/><ellipse cx="320" cy="320" rx="265" ry="79" transform="rotate(63 320 320)" opacity=".18"/></g><g fill="#a8b199" font-family="monospace" font-size="8"><text x="110" y="181">01 / SIGNAL</text><text x="385" y="529">02 / CONTEXT</text></g></svg>`;
fs.writeFileSync('assets/img/network.svg',globe);

let stack=`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 540 700"><defs><linearGradient id="holo"><stop stop-color="#85ddf4"/><stop offset=".27" stop-color="#b1eaf8"/><stop offset=".48" stop-color="#d6b8e8"/><stop offset=".7" stop-color="#f5d9b8"/><stop offset="1" stop-color="#d6ecc1"/></linearGradient><linearGradient id="top" x2="0" y2="1"><stop stop-color="#252921"/><stop offset="1" stop-color="#10130e"/></linearGradient></defs><g stroke="#89907e" stroke-width=".7" stroke-dasharray="4 6" opacity=".5"><path d="M104 153V540M270 63V452M436 153V540M270 235V622"/></g>`;
const ys=[35,195,355,515];
ys.forEach((y,i)=>{
 const active=i===2,stroke=active?'#dfe4d2':'#69705f';
 stack+=`<g transform="translate(0 ${y}) scale(1 .7)"><path d="M104 105V128Q104 139 119 147L247 214Q270 227 293 214L422 147Q436 140 436 128V105" fill="${active?'url(#holo)':'#11140f'}" stroke="${stroke}" stroke-width="1"/><path d="M116 84L247 15Q270 3 293 15L424 84Q448 97 424 111L293 181Q270 193 247 181L116 111Q92 98 116 84Z" fill="url(#top)" stroke="${stroke}" stroke-width="1.2"/><path d="M128 87L250 23Q270 13 290 23L412 87Q430 98 412 108L290 173Q270 183 250 173L128 108Q110 98 128 87Z" fill="none" stroke="${active?'#f1e9cc':'#565e4d'}" stroke-width=".8"/>`;
 for(let j=0;j<20;j++) stack+=`<path d="M${118+j*3.7} ${126+j*1.93}v15" stroke="${active?'#35434a':'#444c3b'}" stroke-width="1"/>`;
 for(let j=0;j<12;j++) stack+=`<path d="M${389+j*2.6} ${151-j*1.4}v7" stroke="${active?'#4f493d':'#444c3b'}" stroke-width="1"/>`;
 [[125,98],[270,24],[414,98],[270,173]].forEach(([x,y])=>{stack+=`<ellipse cx="${x}" cy="${y}" rx="3.2" ry="1.8" fill="${active?'#eee6cd':'#7d8770'}"/>`;});
 stack+=`<g transform="translate(270 98) scale(1 .53) rotate(-45)"><path d="M-8-48H8V-18L29-39 40-28 18-7H48V8H18L40 29 29 40 8 18V48H-8V18L-29 40-40 29-18 8H-48V-8H-18L-40-29-29-40-8-18Z" fill="${active?'url(#holo)':'none'}" stroke="${active?'#d1e3de':'#777e6e'}" stroke-width="1.2"/></g><path d="M270 192V216" stroke="${stroke}" stroke-width=".6"/></g>`;
});
stack+=`<path d="M436 424H511" stroke="#d7e0c9" stroke-width=".8"/><rect x="506" y="420" width="7" height="7" fill="url(#holo)"/><g fill="#9ca68e" font-family="monospace" font-size="8"><text x="58" y="116">01</text><text x="466" y="261">02</text><text x="58" y="406" fill="#d3f56b">03</text><text x="466" y="551">04</text></g></svg>`;
fs.writeFileSync('assets/img/architecture.svg',stack);

