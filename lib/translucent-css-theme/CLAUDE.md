# lib/translucent-css-theme

A glassmorphic design system — translucent surfaces, layered 3D borders, a
blue primary on deep-black (or near-white) background. Pure CSS + a tiny ES
module for theme toggling.

This is **one specific aesthetic among many**, not "the" platform style. Apps
opt in by linking `tokens.css` (or the bundled `init.css` for tokens + base
components). Apps that don't import it keep their own look.

## Files

- `tokens.css` — `:root` color/spacing/typography/radius/shadow custom
  properties. Has a `prefers-color-scheme: light` block plus
  `body.theme-dark` / `body.theme-light` override hooks.
- `base.css` — generic `.translucent-panel`, `.translucent-button`, `.translucent-input`,
  `.translucent-overlay` classes using the tokens.
- `init.css` — single `@import` entry: tokens + base.
- `theme.js` — `applyTheme("dark" | "light" | "system")` + `getTheme()`.
  Persists to `localStorage` under key `"theme"`. Auto-applies on import.

## Adding an app

In the app's HTML head:

```html
<link rel="stylesheet" href="/translucent-css-theme.css">
<link rel="stylesheet" href="style.css">
<script type="module" src="/theme.js"></script>
```

In the app's own `style.css`, drop any `:root { --bg: ... }` blocks — the
tokens come from `translucent-css-theme.css`. Reference values with `var(--bg)`,
`var(--fg)`, `var(--primary)`, etc.

## Token contract

Color tokens (`--bg`, `--fg`, `--fg-muted`, `--translucent-*`, `--primary`,
`--success`, `--error`, `--warning`, `--info`) mirror the canonical
claude-code-hub palette exactly. Spacing/typography/radius/shadow tokens are
chosen to fit the aesthetic; they are stable and may be relied on by
consuming apps.

## Not a Lua library

`lib/translucent-css-theme/` has no Lua. It lives under `lib/` because that's where
crescent libraries live, and apps vendor it via symlink (`tar -h`) into their
static directory.
