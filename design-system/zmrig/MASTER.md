# ZMRIG design system — source of truth

This project keeps the read surface (docs/home) distinct from the operate surface (fleet dashboard), while sharing semantic states and a coherent brand. This file deliberately corrects generic generated suggestions when they conflict with the approved product brief: installation is the homepage's primary task, and there is no assumed live telemetry or performance proof.

## Surface modes and hierarchy

- **Docs and home:** Read/Persuade. Home tasks: Install on Linux (primary), boot USB, configure a fleet, contribute. Pages favor scanable headings, short task paths and sourced technical details.
- **Fleet:** Operate. Overview: state/age, aggregate hashrate (only from online reports), attention, rig list. Detail: reported configuration and last check-in, queued command, setup, logs, explicit safety actions. Never fabricate metrics or hide stale state.
- Keep the existing logo geometry and the `@nggkhaiz` attribution. Do not treat implementation convenience or generated page files as brand authority.

## Semantic color tokens

| Token | Light | Dark | Role |
|---|---|---|---|
| `--surface-page` | `#F7F6F2` | `#111416` | page ground |
| `--surface-panel` | `#FFFFFF` | `#191E20` | cards/panels |
| `--surface-raised` | `#EFEEE9` | `#202729` | secondary region |
| `--ink` | `#171A1B` | `#F0F2EF` | primary text |
| `--ink-muted` | `#535C5D` | `#B0B9B7` | secondary text |
| `--line` | `#D7D8D2` | `#374143` | dividers and boundaries |
| `--brand` | `#9C3D19` | `#F08A58` | ZMRIG copper accent |
| `--success` | `#17633A` | `#60D394` | confirmed healthy state |
| `--warning` | `#8C5200` | `#F0B54B` | attention/temperature |
| `--danger` | `#A3262D` | `#FF7478` | error/destructive |

Map Docusaurus `--ifm-*` and fleet `--*` tokens to these semantics; avoid unreviewed raw colors in components. Check color contrast separately in both themes: WCAG AA 4.5:1 for body text and 3:1 for meaningful UI boundaries. Pair every state color with a word/symbol.

## Type and interaction

- System sans for prose/UI, system monospace for terminal values; no remote font request or font-induced layout shift.
- Reading width 62–76ch; dashboards use tabular numerals and remain usable at 375px.
- 4px spacing base, common 8px rhythm, minimum 44px target; visible `:focus-visible` ring.
- Motion 120–200ms for meaningful state transition only; no ambient number animation; reduce motion on request.
- Prefer accessible HTML controls and concise inline SVG icons; no emoji as an action icon.
- Prefer a read-only install plan before applying changes. Mark uncertain, stale, estimated or assumed values explicitly.

## Source notes

The first machine-generated UI Pro Max candidate recommended a static open-source project hero and warned against an install command. That warning conflicts with the approved product requirement and is overridden. Design direction uses its dark/flat high-contrast operations recommendations, its UX search results on irreversible confirmation and feedback, plus Impeccable's surface-mode model and the Taste Skill's real-product/anti-generic discipline. See `DESIGN.md` and `.agents/skills/` for fuller context, source revisions and licenses.
