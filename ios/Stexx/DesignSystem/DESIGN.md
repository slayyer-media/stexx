# Design language

Two layers: a brand-neutral **shared language** that you could reuse anywhere,
and a **brand layer** that plugs one accent and one motif into it. The Swift
tokens in this folder implement both. `Theme.swift` is the source of truth;
this note explains it.

---

## 1. Shared language

### Principles

- **Dark ink base.** Near-black, slightly cool. Everything else sits on it.
- **Cool neutrals, crisp type, hairlines, negative space.** Use fewer
  containers. Whitespace and a 0.5pt divider usually beat a card.
- **Accent as lighting.** The accent is never a fill. It shows up only as
  light: a thin rim catching the edge of glass, and one faint static flare
  in the background. One or two lit surfaces per screen at most.
- **Black frosted glass** only for things that float over scrolling content.
- **Quiet motion.** Short ease-outs and springs with no overshoot, and
  nothing ambient.

### Colour tokens

| Role | Hex | Swift | Use |
|---|---|---|---|
| ink | `#050608` | `Theme.ink` | app background |
| ink 1 | `#0A0C10` | `Theme.ink1` | flat raised surfaces: rows, bubbles, fields, chips |
| ink 2 | `#12161C` | `Theme.ink2` | pressed, selected, input fill |
| line | `#FFFFFF` @ 0.08 | `Theme.line` | 0.5pt dividers and borders |
| line strong | `#FFFFFF` @ 0.14 | `Theme.lineStrong` | top edge of glass, focused borders |
| frost | `#E8EEF5` | `Theme.frost` | primary text, primary button fill, own bubble |
| steel | `#8B96A5` | `Theme.steel` | secondary text, icons |
| slate | `#545E6B` | `Theme.slate` | tertiary text, disabled, placeholders |
| ice | `#A9C8E8` | `Theme.ice` | interactive tint: links, selected states, app tint |
| cool light | `#1B2430` @ 0.35 | `Theme.coolLight` | faint bottom-leading background radial |
| online | `#4FE3B5` | `Theme.online` | 6pt online dot, static |
| danger | `#FF5A6A` | `Theme.danger` | destructive |
| warning | `#FFC56B` | `Theme.warning` | rare |
| **ACCENT: rim** | *per brand* | `Theme.rim` | rim strokes (0.5–1pt), brand letters, × tick, flare streak |
| **ACCENT: flare** | *per brand* | `Theme.flare` | radial lens-flare blobs, at most 0.12 opacity |

The two **ACCENT** rows are the brand slot. Nothing else changes per brand.

### Type

Heavy sans display paired with a mono caps meta layer. All sizes are
Dynamic Type relative.

| Level | Spec | Swift |
|---|---|---|
| display | 34 heavy, tracking −0.03em (−1.0) | `Font.stexxLargeTitle`, `.stexxTitleStyle(.display)` |
| title | 22 heavy, −0.03em (−0.66) | `Font.stexxTitle`, `.stexxTitleStyle(.title)` |
| headline | 17 semibold | `Font.stexxHeadline` |
| body | 17 regular | `Font.stexxBody` |
| sub | 15 regular | `Font.stexxSub` |
| label | 11 mono medium, UPPERCASE, +0.18em (≈2.0) | `Font.stexxLabel`, `.stexxLabelStyle()` |
| micro | 10 mono medium, UPPERCASE, +0.16em | `Font.stexxMicro`, `.stexxLabelStyle(.micro)` |

Use the mono caps layer for section labels, distances, status, counts,
chips, timestamps and badge text. Display type carries the voice. Mono caps
carries the data.

### Spacing and radius

| Spacing | 4 | 8 | 12 | 16 | 24 | 32 | 48 |
|---|---|---|---|---|---|---|---|
| Swift `Theme.Spacing.` | `xs` | `s` | `m` | `l` | `xl` | `xxl` | `xxxl` |

Screen margin is 20 (`Theme.Spacing.screen`). Leave 24–32 between sections
(`Theme.Spacing.section` = 28). Grid gutter is 2 (`Theme.Spacing.gridGutter`).

| Radius | pt | Swift | Use |
|---|---|---|---|
| xs | 4 | `Theme.Radius.xs` | tiles, chips, tags, badges, bubble tail |
| sm | 6 | `Theme.Radius.sm` / `.avatar` | small buttons, square avatars |
| md | 10 | `Theme.Radius.md` | cards, primary buttons, fields, icon buttons |
| lg | 14 | `Theme.Radius.lg` | sheets, bubbles |
| pill | — | `Capsule()` | segmented controls and tab only |

### Surfaces

- **Black frosted glass** (`.blackGlass(in:)`): ultra-thin material under an
  ink @ 0.55 veil, with a 0.5pt edge running from `lineStrong` at the top to
  `line` at the bottom. The liquid-glass variant for interactive controls is
  `.stexxGlass(in:)`. Use it for bars once content scrolls under them,
  floating action bars, sheets, the composer, and chips over photos.
- **Flat**: `ink1` with a 0.5pt `line` (`GlassCard`, rows), or plain whitespace
  with `HairlineDivider`.
- **Rim light** (`.rimLight()`): a 0.75pt accent stroke at 0.9 opacity from
  the top-leading corner, fading out by about 35% of the perimeter. Use it
  on hero surfaces only.
- Accessibility: Reduce Transparency turns every glass surface into flat `ink1`
  and removes the background flare.

### Motion

| Token | Value | Use |
|---|---|---|
| `Motion.quick` | easeOut 0.20s | chips, toggles, selection |
| `Motion.standard` | easeOut 0.26s | appearing content |
| `Motion.settle` | spring 0.34, damping 0.92 | cards, sheets |
| `Motion.press` | easeOut 0.14s | press feedback (opacity 0.85, scale 0.98) |
| `Motion.fade` | easeOut 0.18s | what everything collapses to under Reduce Motion |

No bounce, pulsing, drifting or scroll-reactive light. Use haptics
sparingly: `.selection` for tabs, favourites and filters, and a light
`.impact` for send.

### Rules

- Never fill with the accent. No accent gradients on buttons, bubbles or
  badges, and no washes of accent colour on the background.
- No glow shadows. The only exception is the brand mark, which may carry a
  faint accent flare (radius ≤ 6, opacity ≤ 0.35).
- The tab bar and app tint use `ice`/`frost`, never the accent.

---

## 2. Brand layer: Stexx

| Slot | Stexx |
|---|---|
| Accent: rim | violet `#A78BFF` (`Theme.rim`) |
| Accent: flare | violet `#7B5CFF` (`Theme.flare`) |
| Motif | the 500 m cell |
| Mark | the "xx" (`StexxMark`, asset `StexxMark`) |
| Voice | lowercase heavy display titles: "nearby", "chats", "you" |
| Tagline | **No ads. Just stexx.** (`Tagline`) |

**Direction: cold glass, violet rim light.** Violet appears only where light
catches glass.

- **Background** (`stexxBackground()` / `GlowBackground`): solid ink with one
  static lens flare. It is a `flare` ellipse at about 0.10 near the
  top-trailing corner, with a 1pt `rim` streak through it at 0.18, blurred by
  2pt and about 140pt wide. A faint cool-light radial sits at the
  bottom-leading corner.
- **The cell** (`CellFrame` / `.cellCorners()`): Stexx snaps locations to a
  500 m grid cell, and the UI draws that cell. Four L-shaped corner ticks
  (6pt arms, 0.75pt, frost @ 0.35) sit 4pt outside a rectangle, or inset on
  photos. The top-leading tick is lit `rim`. Use them on hero surfaces: the
  profile hero, your photo, the logo tile, the paywall card and empty states.
  Square-ish avatars (radius 6) and the 3-column Nearby grid with 2pt gutters
  carry the same motif.
- **× tick**: section labels read "× ABOUT", with the × in `rim` (`SectionLabel`).
- **Coordinates**: distances are always mono caps ("0.5 KM").
- **Wordmark** (`Wordmark`): lowercase "stexx", heavy, tracking −0.04em.
  "ste" is frost and "xx" is flat `rim`, with an optional faint flare
  (rim @ 0.3, radius ≤ 6).
- **Mark** (`StexxMark`): frost "XX" with a violet rim light on its
  top-leading edges. The logo tile (`StexxLogoTile`) is an `ink1` square with
  radius 0.22 × size and cell corners.
- **Stexx+** (`PlusBadge`): mono "STEXX+" with the "XX" in `rim`, a 0.5pt
  rim @ 0.6 outline, and no fill.
