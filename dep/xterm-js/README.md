# dep/xterm-js

Vendored browser builds of [xterm.js](https://github.com/xtermjs/xterm.js)
(terminal emulator) and its `addon-fit` (auto-resize) addon. Both MIT-licensed.

## Files

- `xterm.min.js` — UMD build (`@xterm/xterm` npm package's `lib/xterm.js`).
  Exposes a global `Terminal` when loaded via `<script>`.
- `xterm.css` — required stylesheet for terminal rendering (cursor, selection,
  cell layout).
- `addon-fit.min.js` — UMD build of the fit addon (`@xterm/addon-fit`'s
  `lib/addon-fit.js`). Exposes a global `FitAddon`.
- `LICENSE-xterm` — MIT, copied verbatim from `@xterm/xterm`.
- `LICENSE-addon-fit` — MIT, copied verbatim from `@xterm/addon-fit`.
- `VERSION` — pinned upstream versions.

## Consumer

- `lib/platform/apps/terminal_mux/server.lua` — serves these files as static
  frontend assets (embedded inline in the app's HTML response) to render the
  browser-side terminal UI. Wires `Terminal.onData`/`.write` to the WS
  wire protocol and `FitAddon` to auto-size on window resize.

Browser-side only — never loaded by daemon/server Lua code. No CDN reference
(CSP blocks external scripts); the app tarball vendors these directly, per
the zero-dependency / no-CDN rule in `lib/platform/CLAUDE.md`.

## How this was vendored

```sh
mkdir /tmp/xterm-fetch && cd /tmp/xterm-fetch
bun init -y
bun add @xterm/xterm@6.0.0 @xterm/addon-fit@0.11.0
cp node_modules/@xterm/xterm/lib/xterm.js         <crescent>/dep/xterm-js/xterm.min.js
cp node_modules/@xterm/xterm/css/xterm.css        <crescent>/dep/xterm-js/xterm.css
cp node_modules/@xterm/addon-fit/lib/addon-fit.js <crescent>/dep/xterm-js/addon-fit.min.js
cp node_modules/@xterm/xterm/LICENSE              <crescent>/dep/xterm-js/LICENSE-xterm
cp node_modules/@xterm/addon-fit/LICENSE          <crescent>/dep/xterm-js/LICENSE-addon-fit
printf '@xterm/xterm 6.0.0\n@xterm/addon-fit 0.11.0\n' > <crescent>/dep/xterm-js/VERSION
```

**Important**: run `bun init -y` in the scratch directory *first*. Without a
local `package.json`, `bun add` walks up the directory tree looking for one
and will install into whatever ancestor directory has one — including a
shared `/tmp` if one exists there. `bun init -y` pins the install root.

To bump: change the versions above, repeat the steps, and re-run
`bin/cr test lib/platform/apps/terminal_mux/` plus a manual smoke test
(`docs/apps/terminal-mux.md` if present, or launch the app and open a
terminal in a browser) to confirm the addon API surface didn't change.
