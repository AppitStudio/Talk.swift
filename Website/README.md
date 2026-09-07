# Talk.swift website

A static landing page for Talk.swift. It explains the SDK, the independent provider and consumer roles, the pairing flow, and the public integration resources.

## Develop and build

Use Node.js 20.19+ in the 20.x line, or Node.js 22.12+. Node.js 21 is not supported by Vite 7.

```sh
cd Website
npm ci
npm run dev -- --port 4173 --strictPort
```

The local preview is `http://127.0.0.1:4173/`.

```sh
npm run build
npm run preview -- --port 4174 --strictPort
```

Deploy the contents of `dist/` to a static host. Asset paths are relative so the build supports a domain root or a repository subdirectory. `node_modules/`, `dist/`, and local environment files stay out of source control. This directory does not create hosting resources or publish automatically.

## Content and release alignment

- Keep the package URL and exact published beta version in `index.html` aligned with the SDK installation guide.
- The package example targets `0.1.0-beta.2`, which includes generic incoming-connection support and public app guides. The website is a local preview; publishing the SDK source does not deploy this site.
- Links to `Integrations/`, `Docs/INTEGRATION-UX.md`, installation, pairing, examples, security, and the skill target the GitHub repository. Verify the matching beta.2 source/docs are available there before deploying the website.
- The ExtraBar/DockFlow illustration shows a read-only preset request. It does not invoke either app or represent a live connected session.
- Preserve beta status, the pending minimum-OS qualification, correct signing requirements, and the pending license statement until their underlying status changes.
- No analytics, external font requests, accounts, cloud data, or runtime LLM are used.

## Design and motion

Manrope typography, a cool neutral background, and a directional conversation diagram carry the design. GSAP animates one finite request/result sequence and the order of pairing steps. There is no scroll interception or looping animation. `gsap.matchMedia()` disables and reverts animations when reduced motion is requested; content and links remain available without JavaScript.

The requested skill discovery used:

- [Anthropic frontend-design](https://github.com/anthropics/skills/blob/main/skills/frontend-design/SKILL.md): typography, focused composition, concise content, and restrained motion.
- [Official GSAP core skill](https://github.com/greensock/gsap-skills/blob/main/skills/gsap-core/SKILL.md): timeline setup and reduced-motion support.
- [Official GSAP ScrollTrigger skill](https://github.com/greensock/gsap-skills/blob/main/skills/gsap-scrolltrigger/SKILL.md): the finite pairing sequence.
- [Official GSAP performance skill](https://github.com/greensock/gsap-skills/blob/main/skills/gsap-performance/SKILL.md): transform-based motion and cleanup.

Reference APIs: [gsap.matchMedia](https://gsap.com/docs/v3/GSAP/gsap.matchMedia%28%29/) and [ScrollTrigger](https://gsap.com/docs/v3/Plugins/ScrollTrigger/). No discovered skill was installed globally.

## Third-party assets

The website's dependencies are separate from the dependency-free Swift SDK:

- GSAP 3.15.0: [GSAP standard license](https://gsap.com/standard-license/). The bundled JavaScript preserves its license banner.
- Manrope from `@fontsource-variable/manrope` 5.3.0: SIL Open Font License 1.1. The self-hosted Latin variable font is bundled by Vite; its license is included in [public/manrope-license.txt](public/manrope-license.txt).
- Vite 7.3.6: development/build tooling, MIT license.

These third-party terms do not grant a license to Talk.swift itself.
