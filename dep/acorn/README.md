# dep/acorn

Vendored single-file build of [acorn](https://github.com/acornjs/acorn),
a small, fast JavaScript parser. ESM, MIT-licensed.

## Files

- `acorn.mjs` — the single-file ESM build (`dist/acorn.mjs` from npm).
- `LICENSE` — MIT, copied verbatim from upstream.
- `VERSION` — pinned upstream version (currently `8.14.0`).

## Consumer

- `lib/js_pack_validator/validator.js` — author-side pack-JS subset
  hygiene tool. Imports `acorn.parse` from this file via relative path.

This dependency is used ONLY by the author-side validator. It is NOT a
daemon-side runtime dependency (per `docs/platform_isolation.md` §3
"Daemon-side parser-level enforcement — rejected").

## How this was vendored

```sh
mkdir /tmp/acorn-fetch && cd /tmp/acorn-fetch
bun init -y
bun add acorn@8.14.0
cp node_modules/acorn/dist/acorn.mjs <crescent>/dep/acorn/acorn.mjs
cp node_modules/acorn/LICENSE        <crescent>/dep/acorn/LICENSE
echo "8.14.0" > <crescent>/dep/acorn/VERSION
```

To bump: change the version above, repeat the steps, and re-run
`bun lib/js_pack_validator/validator.test.js` to confirm parser
compatibility with the test corpus.

## Why a single-file ESM vendor, not a bun lockfile

Per the crescent vendoring convention (`CLAUDE.md` "This repository is
zero-dependency"), dependencies are committed source rather than fetched
at install time. Acorn's `dist/acorn.mjs` is a self-contained ESM
module (~150 KB) with no transitive runtime dependencies, which makes
it a clean fit for the single-file vendor pattern already used for
e.g. `dep/sqlite3/sqlite3.c`.
