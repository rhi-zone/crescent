# ccv2 frontend tests

Bun-based test suite for the static JS modules under
`lib/platform/apps/charactercardv2/static/`. Hand-rolled DOM polyfill, no
`npm install`, no `node_modules`, no `package.json` at runtime — bun is
already in `flake.nix` for the docs site, so the dev shell has it.

## Run

```sh
cd lib/platform/apps/charactercardv2/static
bun test
```

Or one file at a time:

```sh
bun test test/persona.test.js
```

Bun discovers `*.test.js` under `test/` automatically. No config needed.

## Files

| File                   | Purpose                                                              |
| ---------------------- | -------------------------------------------------------------------- |
| `dom.js`               | ~400-line Element/Document/Window polyfill + tiny HTML parser.       |
| `mock-fetch.js`        | Installs `globalThis.fetch` mock with `respond(pattern, fn)` + calls log. |
| `helpers.js`           | `loadIndexHtml()`, `flush()`, `escAttr`, etc.                        |
| `<module>.test.js`     | One per extracted production module.                                 |

`dom.js` is **scoped to what these tests use**, not a full DOM spec. If
production code starts touching something the polyfill doesn't model, extend
`dom.js` (or have it throw `"not implemented: X"` rather than silently
returning `undefined`).

## Adding a test

1. Create `test/<module>.test.js`.
2. `import { describe, test, expect, beforeEach } from "bun:test"`.
3. In `beforeEach`, call `loadIndexHtml()` and `installFetchMock()`.
4. Import the production module under test from `../<module>.js` directly
   — do NOT copy or stub it.
5. Exercise behavior by calling exported functions, dispatching DOM events,
   and asserting against the mock call log + DOM state.

Example:

```js
import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initThing } from "../thing.js";

let mock;
beforeEach(() => { loadIndexHtml(); mock = installFetchMock(); });

describe("thing.init", () => {
  test("clicking the button POSTs", async () => {
    mock.respond("/api/thing", () => ({ status: 200, json: { ok: true } }));
    initThing({ showError: () => {} });
    document.getElementById("the-button").click();
    await flush();
    expect(mock.findCall("POST", "/api/thing")).toBeDefined();
  });
});
```

## Aspirational tests (failing-on-purpose)

**Read the project CLAUDE.md "Core Rules" section before changing tests.**

Tests in this suite encode **what the code should do**, not what it currently
does. If the production module is buggy or has unimplemented behavior, write
the test for the *correct* behavior — even if it fails. Leave a comment:

```js
// FAILING: <module> does not currently <X>. See TODO.md frontend test regressions.
test("X works correctly", () => {
  ...
});
```

Then add a one-line entry under `## frontend test regressions` in
`TODO.md` at the repo root.

**Do NOT** adjust a failing test to match buggy behavior. **Do NOT** fix the
bug in the same pass as adding the test — that erases the regression marker.
The whole point is that the test stays red until the underlying bug is fixed,
at which point the test goes green automatically.

This mirrors the rule in `/CLAUDE.md`:

> A design that requires X to be safe must ship with X. Implementing the
> unsafe version "for now" and deferring X is not a step toward the right
> design — it's a lie that accumulates.

A failing test is the most honest possible TODO marker: CI flags it, it
shows up in `bun test` output, and it can't be silently ignored.

## DOM polyfill caveats

- `setTimeout` does NOT fire callbacks. Tests that depend on timer effects
  must drive them manually (or extend `dom.js`).
- CSS selectors support `#id`, `.class`, `tag`, `[attr]`, `[attr="v"]`, and
  the descendant combinator (`a b`). No `>`, no `:nth-*`, no `,`.
- `innerHTML` parses via a minimal forgiving HTML tokenizer. It handles
  attributes, self-closing tags, and raw-text elements (`script`, `style`,
  `textarea`). It does NOT handle malformed HTML correctly — tests should
  pass well-formed strings.
- Event bubbling works for `click` and other dispatched events but capture
  phase is not implemented.
- `confirm` / `alert` / `prompt` are `window` properties — assign via
  `window.confirm = () => false`, not `globalThis.confirm`.
