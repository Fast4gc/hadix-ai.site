import * as THREE from "three";

/*
 * img2threejs — reconstruction-by-code (stylized).
 * Reference: assets/img/reference.png (1672x941).
 * Evidence: assets/img/palette-report.json (pixel analysis — this run had no
 * vision input; form is a stylized interpretation, palette is measured):
 *   - background near-black with blue tint, ~92% pure black
 *   - dominant vivid subject: lime #9cd00a, vertical mass centered
 *   - wide dense bright base at the lower third of the subject
 *   - white #e1e1e2 text bands left/right, sparse lime accents up top
 * qualityContract: real-time browser prop, ~60fps, <40k tris, no external
 * art, deterministic seed, explodable + clickable parts.
 */
export const EMBLEM_SPEC = {
  id: "hadix-emblem",
  reference: "assets/img/reference.png",
  fidelity: "stylized",
  palette: {
    lime: 0x9cd00a,
    limeHot: 0xc8ff3c,
    white: 0xe1e1e2,
    darkMetal: 0x111410,
    blueAmbient: 0x2a4a6a,
  },
  layout: {
    subjectWidthRatio: 0.22,
    subjectHeightRatio: 0.65,
    base: "wide dense glow at lower third",
  },
  seed: 20260913,
};

function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makeGlowTexture(hexColor) {
  const c = document.createElement("canvas");
  c.width = c.height = 256;
  const ctx = c.getContext("2d");
  const g = ctx.createRadialGradient(128, 128, 0, 128, 128, 128);
  const col = new THREE.Color(hexColor);
  const rgb = `${Math.round(col.r * 255)},${Math.round(col.g * 255)},${Math.round(col.b * 255)}`;
  g.addColorStop(0, `rgba(${rgb},0.85)`);
  g.addColorStop(0.35, `rgba(${rgb},0.32)`);
  g.addColorStop(1, `rgba(${rgb},0)`);
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, 256, 256);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

function makeBeamTexture(hexColor) {
  const c = document.createElement("canvas");
  c.width = 8;
  c.height = 128;
  const ctx = c.getContext("2d");
  const col = new THREE.Color(hexColor);
  const rgb = `${Math.round(col.r * 255)},${Math.round(col.g * 255)},${Math.round(col.b * 255)}`;
  const g = ctx.createLinearGradient(0, 128, 0, 0);
  g.addColorStop(0, `rgba(${rgb},0.55)`);
  g.addColorStop(0.45, `rgba(${rgb},0.28)`);
  g.addColorStop(1, `rgba(${rgb},0)`);
  ctx.fillStyle = g;
  ctx.fillRect(0, 0, 8, 128);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

export function createHadixEmblem(spec = EMBLEM_SPEC) {
  const P = spec.palette;
  const rand = mulberry32(spec.seed);

  const group = new THREE.Group();
  group.name = spec.id;

  const texGlow = makeGlowTexture(P.lime);
  const texGlowWhite = makeGlowTexture(P.white);
  const texBeam = makeBeamTexture(P.limeHot);

  const M = {
    metal: new THREE.MeshPhysicalMaterial({
      color: P.darkMetal,
      metalness: 0.92,
      roughness: 0.32,
      clearcoat: 0.45,
      clearcoatRoughness: 0.3,
    }),
    neon: new THREE.MeshPhysicalMaterial({
      color: P.lime,
      emissive: P.lime,
      emissiveIntensity: 1.5,
      metalness: 0.15,
      roughness: 0.28,
      flatShading: true,
    }),
    hot: new THREE.MeshPhysicalMaterial({
      color: P.white,
      emissive: P.white,
      emissiveIntensity: 2.1,
      roughness: 0.35,
      metalness: 0,
    }),
    beam: new THREE.MeshBasicMaterial({
      map: texBeam,
      transparent: true,
      opacity: 0.5,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
      side: THREE.DoubleSide,
    }),
    glowLime: new THREE.MeshBasicMaterial({
      map: texGlow,
      transparent: true,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    }),
    glowWhite: new THREE.MeshBasicMaterial({
      map: texGlowWhite,
      transparent: true,
      opacity: 0.5,
      blending: THREE.AdditiveBlending,
      depthWrite: false,
    }),
    line: new THREE.MeshBasicMaterial({
      color: P.lime,
      transparent: true,
      opacity: 0.16,
      side: THREE.DoubleSide,
      depthWrite: false,
    }),
  };

  const parts = [];
  function reg(obj, dir, amt, pulseable = true) {
    obj.userData.home = obj.position.clone();
    obj.userData.dir = dir.clone().normalize();
    obj.userData.amt = amt;
    obj.userData.pulse = 0;
    obj.userData.pulseable = pulseable;
    parts.push(obj);
    return obj;
  }

  function addAt(parent, geo, mat, x, y, z, dir, amt, pulseable) {
    const m = new THREE.Mesh(geo, mat);
    m.position.set(x, y, z);
    parent.add(m);
    if (parent === group) return reg(m, dir, amt, pulseable);
    m.userData.home = new THREE.Vector3(x, y, z);
    m.userData.dir = dir.clone().normalize();
    m.userData.amt = amt;
    m.userData.pulse = 0;
    m.userData.pulseable = pulseable !== false;
    parts.push(m);
    return m;
  }

  const V = (x, y, z) => new THREE.Vector3(x, y, z);

  /* ---- base platform (wide dense glow, lower third of reference) ---- */
  const base = new THREE.Group();
  group.add(base);

  addAt(
    base,
    new THREE.CylinderGeometry(1.55, 1.8, 0.26, 6),
    M.metal,
    0, 0, 0,
    V(0, -1, 0), 0.9, true
  ).rotation.y = Math.PI / 6;

  addAt(
    base,
    new THREE.TorusGeometry(1.44, 0.024, 8, 6),
    M.neon,
    0, 0.145, 0,
    V(0, -0.6, 0), 0.7
  ).rotation.x = -Math.PI / 2;

  const underGlow = addAt(
    base,
    new THREE.CircleGeometry(2.0, 32),
    M.glowLime,
    0, 0.16, 0,
    V(0, -0.4, 0), 0.5, false
  );
  underGlow.rotation.x = -Math.PI / 2;

  [1.95, 2.45].forEach((r, i) => {
    addAt(
      base,
      new THREE.RingGeometry(r, r + 0.02, 72),
      M.line,
      0, 0.02 + i * 0.001, 0,
      V(0, -0.3, 0), 0.4 + i * 0.25, false
    ).rotation.x = -Math.PI / 2;
  });

  /* ---- energy column ---- */
  addAt(
    base,
    new THREE.CylinderGeometry(0.16, 0.55, 1.7, 28, 1, true),
    M.beam,
    0, 1.05, 0,
    V(0, -0.5, 0), 0.6, false
  );

  /* ---- core assembly (vertical lime mass, center of reference) ---- */
  const coreY = 2.0;
  const core = addAt(
    group,
    new THREE.IcosahedronGeometry(0.52, 1),
    M.neon,
    0, coreY, 0,
    V(0, 1, 0), 1.35
  );

  const kernel = addAt(
    group,
    new THREE.SphereGeometry(0.3, 24, 16),
    M.hot,
    0, coreY, 0,
    V(0, 1.4, 0), 1.5
  );

  const halo = addAt(
    group,
    new THREE.PlaneGeometry(3.4, 3.4),
    M.glowLime,
    0, coreY, -0.2,
    V(0, 1.2, 0), 1.4, false
  );

  const ringA = addAt(
    group,
    new THREE.TorusGeometry(0.88, 0.032, 10, 72),
    M.metal,
    0, coreY, 0,
    V(0.8, 0.5, 0.4), 1.1
  );
  ringA.rotation.z = 0.55;

  const ringB = addAt(
    group,
    new THREE.TorusGeometry(1.12, 0.016, 8, 90),
    M.neon,
    0, coreY, 0,
    V(-0.7, 0.6, 0.5), 1.25
  );
  ringB.rotation.x = 1.15;
  ringB.userData.spin = -0.22;
  ringA.userData.spin = 0.3;

  const trimRing = addAt(
    group,
    new THREE.TorusGeometry(0.88, 0.042, 8, 72),
    new THREE.MeshPhysicalMaterial({
      color: P.limeHot,
      emissive: P.limeHot,
      emissiveIntensity: 1.1,
      metalness: 0.3,
      roughness: 0.4,
      transparent: true,
      opacity: 0.85,
    }),
    0, coreY, 0,
    V(0.8, 0.5, 0.4), 1.1
  );
  trimRing.rotation.z = 0.55;
  trimRing.userData.follow = ringA;

  /* ---- shards: sparse lime accents rising diagonally (top of reference) ---- */
  const shards = new THREE.Group();
  shards.position.y = coreY;
  group.add(shards);
  shards.userData.home = shards.position.clone();
  shards.userData.dir = V(0, 1, 0);
  shards.userData.amt = 0.9;
  shards.userData.pulse = 0;
  parts.push(shards);

  for (let i = 0; i < 6; i++) {
    const ang = (i / 6) * Math.PI * 2 + rand() * 0.5;
    const r0 = 0.75 + rand() * 0.2;
    const h = 1.15 + rand() * 0.9;
    const curve = new THREE.CatmullRomCurve3([
      new THREE.Vector3(Math.cos(ang) * r0, -0.55, Math.sin(ang) * r0),
      new THREE.Vector3(Math.cos(ang) * (r0 + 0.35), h * 0.45, Math.sin(ang) * (r0 + 0.35)),
      new THREE.Vector3(Math.cos(ang) * 0.35, h, Math.sin(ang) * 0.35),
    ]);
    const tube = new THREE.Mesh(new THREE.TubeGeometry(curve, 14, 0.018, 5), M.neon);
    shards.add(tube);
    const tip = new THREE.Mesh(new THREE.TetrahedronGeometry(0.055), M.neon);
    tip.position.set(Math.cos(ang) * 0.35, h, Math.sin(ang) * 0.35);
    shards.add(tip);
  }

  /* ---- orbiting sparks (deterministic) ---- */
  const SPARKS = 46;
  const sparks = new THREE.InstancedMesh(
    new THREE.TetrahedronGeometry(0.045),
    M.neon,
    SPARKS
  );
  const sparkData = [];
  for (let i = 0; i < SPARKS; i++) {
    sparkData.push({
      r: 1.15 + rand() * 1.6,
      speed: 0.08 + rand() * 0.35,
      phase: rand() * Math.PI * 2,
      y: coreY - 0.6 + rand() * 2.3,
      rot: rand() * Math.PI * 2,
    });
  }
  sparks.userData.sparkData = sparkData;
  group.add(sparks);

  const dolly = new THREE.Object3D();
  function updateSparks(t, p) {
    for (let i = 0; i < SPARKS; i++) {
      const d = sparkData[i];
      const a = d.phase + t * d.speed * 4;
      const spread = 1 + p * 0.9;
      dolly.position.set(
        Math.cos(a) * d.r * spread,
        d.y + Math.sin(t * 0.8 + d.phase) * 0.18 + p * 1.2,
        Math.sin(a) * d.r * spread
      );
      dolly.rotation.set(d.rot + t * 0.6, a, 0);
      const s = 0.6 + Math.sin(t * 3 + d.phase * 7) * 0.35;
      dolly.scale.setScalar(Math.max(0.15, s));
      dolly.updateMatrix();
      sparks.setMatrixAt(i, dolly.matrix);
    }
    sparks.instanceMatrix.needsUpdate = true;
  }

  /* ---- API ---- */
  let explode = 0;

  function setExplode(p) {
    explode = THREE.MathUtils.clamp(p, 0, 1);
  }

  for (const o of parts) {
    o.userData.baseScale = o.scale.clone();
  }

  function pulse(obj) {
    let t = obj;
    while (t && !t.userData.pulseable) t = t.parent;
    if (!t) return false;
    t.userData.pulse = 1;
    return true;
  }

  function update(t, dt) {
    ringA.rotation.y += dt * 0.32;
    ringB.rotation.y -= dt * 0.24;
    trimRing.quaternion.copy(ringA.quaternion);
    core.rotation.y += dt * 0.14;
    shards.rotation.y += dt * 0.08;

    for (const o of parts) {
      const bob = o === core || o === kernel || o === halo ? Math.sin(t * 1.6) * 0.07 : 0;
      o.position
        .copy(o.userData.home)
        .addScaledVector(o.userData.dir, explode * o.userData.amt);
      o.position.y += bob;
      if (o.userData.pulse > 0) {
        o.userData.pulse = Math.max(0, o.userData.pulse - dt * 2.2);
        const k = 1 + o.userData.pulse * 0.18 * Math.sin(o.userData.pulse * Math.PI);
        o.scale.copy(o.userData.baseScale).multiplyScalar(k);
      }
    }

    M.neon.emissiveIntensity = 1.5 + Math.sin(t * 2.2) * 0.22 + core.userData.pulse * 2.4;
    M.beam.opacity = 0.42 + Math.sin(t * 3.1) * 0.1;
    underGlow.material.opacity = 0.75 + Math.sin(t * 1.8) * 0.2;
    group.rotation.y += dt * 0.045;
    updateSparks(t, explode);
  }

  function pickTargets() {
    return parts.filter((p) => p.userData.pulseable);
  }

  function dispose() {
    texGlow.dispose();
    texGlowWhite.dispose();
    texBeam.dispose();
    const seen = new Set();
    group.traverse((o) => {
      if (o.geometry) o.geometry.dispose();
      const mats = Array.isArray(o.material) ? o.material : o.material ? [o.material] : [];
      mats.forEach((m) => {
        if (seen.has(m)) return;
        seen.add(m);
        Object.values(m).forEach((v) => v && v.isTexture && v.dispose());
        m.dispose();
      });
    });
  }

  return { group, update, setExplode, pulse, pickTargets, dispose, parts };
}
