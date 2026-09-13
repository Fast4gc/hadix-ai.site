# Hadix layout review

The page is a stylized interpretation of the two supplied website references. It uses a monochrome technical grid, lime signals, a wireframe network globe, and separated isometric modules with an iridescent intelligence layer.

## Skills consulted

- https://github.com/img2threejs/img2threejs — silhouette, component and material analysis. Its complete gated Three.js reconstruction pipeline was not executed: Python is unavailable in this environment. The new illustrations are deterministic SVG, not Three.js models. The original `assets/js/emblem3d.js` is preserved but no longer loaded.
- https://github.com/lottiefiles/motion-design-skill — Premium motion personality, restrained travel, consistent timing, easing and secondary hover feedback.
- https://github.com/greensock/gsap-skills — core and ScrollTrigger guidance, matchMedia cleanup, reduced motion, local dependencies and scroll-triggered entrances.

## Corrections

- Honor the mobile navigation's hidden attribute; close on Escape, outside click, selection and desktop breakpoint.
- Keep content visible independently of JavaScript, animation dependencies and WebGL.
- Replace pinned sections and forced horizontal scrolling with responsive grids.
- Remove simulated account creation and unverified statistics/customer endorsements; calls to action navigate to available sections.
- Keep essential visual assets and GSAP local. Fonts have system fallbacks.
- Pause ambient motion outside the viewport and when the tab is hidden; skip motion when reduced motion is requested.

## Validation

`layout-checks.json` records the browser checks. Screenshots are `layout-1440.png` and `layout-390.png`.
The browser script checks overflow, assets, anchor targets, JavaScript errors, mobile navigation and dependency/motion fallbacks. No backend account creation is implemented.

## Full viewport scenes

The four primary sections now share a fixed viewport. GSAP coordinates exit/entrance transforms, scale and a persistent orbit backdrop. Navigation supports section hashes, browser history, buttons, keyboard, wheel and touch gestures at the content boundaries. Panels with content taller than the available viewport retain internal scrolling. Inactive panels are inert and hidden from assistive technology. The CTA lives inside the Agents scene; its original anchor remains available.

The platform's 2D assembly now runs on scene entry, replacing the earlier document-scroll timeline. Reduced motion immediately displays the completed assembly. Without GSAP, the normal readable document remains available.

Current validation: `check-scenes.cjs` checks desktop/mobile scenes, viewport bounds, history, direct file hashes, wheel navigation and reduced motion. The earlier scroll assembly checks describe the previous interaction and are superseded by this check.

## Planet portal update

The hero now uses a real procedural Three.js globe with surface geometry, geographic outlines, raised network routes, orbital rings and a Fresnel atmosphere. A shared WebGL canvas allows the camera to move from the hero into a portal without clipping the planet to its original illustration bounds. Hero/platform transitions use the same progress state in opposite directions. Other screen transitions remain unchanged.

The assembly now resets before the incoming scene becomes visible, draws each silhouette before filling its materials, and pauses when leaving the platform. Motion runs for 3.2 seconds; reduced motion shows the completed state immediately.

All runtime dependencies are local and compatible with file URLs. WebGL failure keeps the SVG illustration and the regular GSAP transition. `check-portal.cjs` verified WebGL rendering, forward/reverse transitions, partial and completed assembly states, reduced motion and a forced WebGL-unavailable fallback at desktop/mobile widths.

## Adaptive spatial background

Added a CSS square grid with a perspective floor and a separate low-poly WebGL wire surface. The same vertex topology morphs between sphere, stacked cross sections, flowing tube and a connected ring as the active scene changes. GSAP coordinates shape, orientation, opacity and floor perspective. Desktop pointer movement adds restrained parallax; mobile uses smaller geometry and a softer mask. The CSS grid remains visible without WebGL or JavaScript. Ambient rendering pauses in hidden tabs and with reduced motion.

`check-adaptive.cjs` verifies scene-specific morph selection, desktop/mobile overflow and reduced-motion navigation. The portal regression check also passes with the new background.
