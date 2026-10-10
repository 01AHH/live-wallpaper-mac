# LiveWall brand

The look set by the home page (`web/public/index.html`, styled by `landing.css`). Everything people see follows it: the website, the app's welcome and the installer.

## Stage

- **Near-black background**: `#07070a`. Surfaces step up gently: `#111115`, `#17171c`.
- **Hairlines, not boxes**: borders are white at 8% (`--line`) or 14% (`--line-strong`).
- **The wallpapers bring the colour.** Everything else stays neutral.

## Accent

- **One accent: golden-hour amber `#f59e38`** (the app's `Brand.accent`).
- It marks what's selected, playing or numbered: step badges, the playing tile, toggles, small highlights.
- Don't use it for large flat fills or for primary buttons.

## The glow

Soft amber bands lying diagonally across black, slowly drifting, fading out towards the edges. It sits behind hero moments only:

| Where | Implementation |
|---|---|
| Website hero, closing call to action, download page | `.glow-bands` in `web/public/landing.css` |
| The app's first-launch welcome | `GlowBands` in `Sources/LiveWall/Effects.swift` |
| The `.dmg` installer window | `Packaging/make_dmg_background.swift` |

All three use the same colour stops: clear → `#f59e38` → `#ffc56e` → `#d65c1e` → clear. If you change one, change all three.

## Type

- **Font**: the system font (SF Pro). Small print, versions and requirements are in monospace (`--mono`), like *macOS Tahoe and Apple silicon required*.
- **Headlines**: bold, with tight tracking (`-0.035em`).
- **Section pattern**: a bold statement followed by a muted one. For example: **One canvas across every screen.** Or a different wallpaper on each.

## Controls

- **Primary button**: white on black, 10px corners (`.btn-white`).
- **Secondary button**: transparent with a hairline border (`.btn-ghost`).
- **Navigation**: a floating pill bar with Features, Gallery, Setup guide and a white Download button. Every page uses it.

## Motion

- **Curve**: the spring `cubic-bezier(0.2, 0.9, 0.1, 1)`, the same curve as the app.
- **Layout changes** morph in place over 0.7s and never jump.
- **Reduced motion**: always respect it.

## Words

- **No em dashes** in anything a visitor reads. Use a full stop, colon or comma instead.
- **Short and plain, in British spelling**: colour, licence, personalised.
- **Imagery in marketing** uses public-domain NASA footage only, never wallpapers whose licence is unverified.
