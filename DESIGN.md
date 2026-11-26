# ZMRIG visual system

## Direction

A **precision mining instrument**: unmistakably technical and trustworthy, never a stock SaaS dashboard or crypto casino. Keep the existing Z mark and project attribution; replace the old component composition where it obstructs a clear user task. Make engineering evidence, installation, safety and source links visible. Do not use token coin art, rockets, emoji icons, fake telemetry, speculative earning claims, or gratuitous gradients/glows.

The UI Pro Max skill's generated default cautioned against placing an install command on the home page; that generic recommendation conflicts with the product requirement. Installation remains the primary action. Its dark/flat operations palette and accessible control guidance are useful; typography and exact tokens below are product decisions, not blindly copied defaults.

## Surfaces

- **Marketing / docs (Docusaurus):** Read + Persuade. Paper-like neutral canvas for long-form reading; dark ink, existing signal-copper accent, restrained lime for success and red/amber for warnings. The home page is installation-first and offers separate host, USB appliance, fleet and contributor routes. Use real documentation content and source-linked proof.
- **Fleet console:** Operate. Low-glare, high-contrast instrument panel with a dark-first theme and an explicit light alternative. Keep primary actions predictable, destructive actions guarded, temperatures and stale status readable without relying on color alone, and forms usable by keyboard. Server-rendered HTML stays lightweight and works without client JavaScript.

## Tokens (initial; adjust only with a contrast-checked reason)

| Token | Light | Dark | Use |
|---|---|---|---|
| `--surface-page` | `#F7F6F2` | `#111416` | page ground |
| `--surface-panel` | `#FFFFFF` | `#191E20` | grouped content |
| `--surface-raised` | `#EFEEE9` | `#202729` | secondary region |
| `--ink` | `#171A1B` | `#F0F2EF` | primary text |
| `--ink-muted` | `#535C5D` | `#B0B9B7` | secondary text |
| `--line` | `#D7D8D2` | `#374143` | dividers/control boundaries |
| `--brand` | `#9C3D19` | `#F08A58` | existing ZMRIG copper accent |
| `--success` | `#17633A` | `#60D394` | confirmed healthy state |
| `--warning` | `#8C5200` | `#F0B54B` | attention/temperature |
| `--danger` | `#A3262D` | `#FF7478` | error/destructive |

The `@media (prefers-color-scheme)` values are not the authority: use semantic tokens and verify both palettes. For status, pair color with text/icon/shape. Body copy must reach WCAG AA 4.5:1; meaningful non-text UI boundaries need at least 3:1. Focus indicators remain visible in either theme.

## Type, layout, motion

- Use bundled/system sans for UI and a system monospace for commands, hashes and values; no remote font request or layout shift.
- Documentation text measure: 62–76 characters. Dashboard tables may be denser, but mobile transforms to labeled rows rather than forcing page-wide horizontal scroll.
- Use a 4px base spacing scale, 8px standard rhythm, 44px minimum pointer targets, stable table numerals and explicit units.
- Use a single simple icon family (inline SVG or existing marks), no emoji as functional icons.
- Motion is short and functional (120–200ms); never animate important numbers continuously. Respect `prefers-reduced-motion` and never hide final content behind an animation.

## Content and behavior

- A label names what is installed or controlled; a button names the action and object.
- Distinguish last-known data from current data. Show `last seen`/age and mark stale/offline; never label a cached value “live”.
- Routine reversible settings are queued with immediate acknowledgment and auditable results; irreversible/restart/power actions name the rig and consequences and require deliberate confirmation.
- Keep `plan` (read-only preview) ahead of `install` where practical. Never copy an example wallet or place a secret in a URL.
- Bilingual parity includes nav, empty/error states, safety warnings, fee disclosure and operational control copy—not only page titles.

## Source and derivation

Design guidance was informed by the requested Impeccable, UI/UX Pro Max, Vercel agent-skills and Taste Skill repositories. UI/UX Pro Max queries selected an installation-oriented product/home pattern and separately confirmed clear feedback, confirmation for irreversible actions, accessible role queries, and controlled React inputs. Their licenses and pinned source commits are in `.agents/skills-licenses/` and `.agents/skills/SOURCES.json`.
