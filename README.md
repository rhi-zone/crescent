# crescent

A complete software ecosystem in pure Lua — protocols, codecs, parsers, typechecker, package manager, game primitives, and more — all as libraries you own outright.

Part of the [rhi ecosystem](https://rhi.zone).

---

## What it is

Crescent is the ecosystem LuaJIT never had. LuaJIT (a fast, embeddable scripting runtime with an excellent C FFI) is capable enough to build real software, but it ships with almost no standard library. Crescent fills that gap — ambitiously.

The goal isn't a handful of utility functions. It's the entire surface area of software: HTTP, WebSockets, DNS, SQLite, cryptography, compression, parsing, reactive state, async concurrency, game math, ML primitives, a static typechecker, a package manager, a test runner. All of it, as composable pure-Lua libraries you can read, copy, and modify.

**Crescent is not a language or framework.** There is no transpiler, no magic, no "crescent way" of building apps. It's a collection of libraries. Use the ones you need.

---

## Why it might matter to you

**`git clone` and it runs.** No `npm install`, no `pip`, no build step, no internet required after the clone. LuaJIT binaries for Linux (x86\_64 and aarch64), macOS (arm64), and Windows are vendored in `bin/`. On an air-gapped machine, in a Docker container, on a friend's laptop — it just works.

**Own your dependencies.** Every library is copy-paste-ownable. Find something you want to use? Copy the directory into your project. It's yours: no upstream to break you, no version negotiation, no hidden transitive dependencies. The ecosystem spreads through inspection and curiosity, not through a registry.

**The whole thing is small.** The complete crescent ecosystem — every library — is approximately 8 MB of readable Lua plus ~4 MB of runtime (LuaJIT + SQLite). A typical Node.js project's `node_modules` exceeds this before the first line of application code. Small enough to vendor into a game, a CLI tool, or anything users download without reading a manifest first.

**Discoverability lives in the tool, not in tutorials.** A tool that requires you to read external docs to find its features has failed. Crescent's `bin/cr` entry point, the typechecker, and the test runner are designed so you can explore the system without opening a browser.

---

## Try it

```bash
git clone https://github.com/rhi-zone/crescent
cd crescent
bin/cr test              # run all tests
bin/cr test lib/http/    # run a single library's tests
bin/cr check lib/http/init.lua   # typecheck a file
```

If your platform isn't covered by the vendored binaries, `bin/install` (requires curl) downloads from [pterror/LuaJIT](https://github.com/pterror/LuaJIT/releases).

---

## What's in the box

A high-level tour. For the full per-library index, see [`docs/inventory.md`](docs/inventory.md).

**Tooling**
- `lib/type/` — static typechecker with constraint-based inference, LSP daemon, type search (Hoogle-style), lint passes
- `lib/test/` — test runner, property testing, fuzz testing with replay, snapshot fixtures
- `lib/pkg/` — vendor-first package manager (semver, manifest, lockfile)
- `lib/cli/` — argument parsing

**Network protocols**
HTTP (server + client, mature), WebSocket, SMTP, OAuth/OAuth2, x509, TLS (wip), ljsocket, wire framing

**Formats and codecs**
JSON, CBOR, MessagePack, TOML, YAML, BSON, Protobuf, CSV, ASN.1, XML, XPath, SVG, PNG, PEM, tar, base32/58/64, UUID, URL, iCalendar, multipart, and more

**Compression**
Brotli, gzip/zlib (tiered FFI + pure Lua), LZ4, Snappy, Zstd, Huffman, RLE

**Cryptography**
AES-GCM, ChaCha20-Poly1305, HKDF, Argon2, BLAKE2, Ed25519, Curve25519, JWT, PBKDF2, scrypt, TOTP/HOTP, SipHash, MurmurHash, Shamir secret sharing, and more via `lib/crypto/` and `lib/cryptography/`

**Parsing and grammars**
PEG parsers, regex (PCRE2 + pure-Lua Thompson-NFA), CSS, GraphQL (parser + schema + executor), Datalog, Prolog, µKanren, Markdown, diff/merge, expression evaluators

**Data structures**
Bloom filters, LRU caches, tries, HAMTs, skip lists, segment trees, B-trees, rope, ring buffers, spatial indexes (k-d tree, quadtree), and a few dozen more — all stable

**Numerics, math, and ML**
Complex numbers, geometry, 2D physics, A\*, neural nets, decision trees, Bayesian filters, stats, DSP, Bézier curves, Voronoi, finance/money, datetime/duration

**Storage and databases**
SQLite FFI, ECS (SQLite-backed), in-memory entity-component, ORM, query builder, schema migrations, Raft state machine

**Async and concurrency**
Coroutine actor model, async/await, Go-style channels, promises, scheduler, semaphores, connection pool, circuit breaker, retry, cron

**Reactive state**
Push signals, auto-tracking signals (parallel implementations), reactive DB with live queries, Redux-style store, Rx-style streams, pub/sub, event sourcing

**Text and markup**
Template engines, Mustache, HTML builder, word wrap, spell check, full i18n/locale, Levenshtein, fuzzy matching, Markov chains, Porter stemmer

**UI and graphics**
TUI (ANSI), canvas (PPM/PGM/BMP output), color toolchain, layout, web framework (`lib/web/` — middleware, routing, cookies, reactive DOM), barcode, QR codes (wip)

**OS and platform**
`lib/fs/`, `lib/path/`, `lib/process/`, `lib/env/`, POSIX signals, `lib/platform/` (tarball loader, sandboxed entrypoints, cap dispatch)

---

## Where it's going

Crescent's ambition is the entire surface area of software. The organizing principle: if a concept exists as a library anywhere and it can be implemented in pure Lua with acceptable LuaJIT performance, it belongs in crescent.

The practical bar: an ecosystem complete enough that you can build a local-first PIM, a web service, a game, a language server, or an LLM pipeline without reaching outside it.

Read more:
- [`docs/batteries.md`](docs/batteries.md) — the full scope: what's planned, motivating targets, the distribution thesis
- [`docs/principles.md`](docs/principles.md) — the north star: make the computer small, discoverability in the tool, no online resources in the loop

---

## Repo layout

```
bin/           vendored LuaJIT binaries + bin/cr entry point
lib/           all packages — each a directory with init.lua, tests, types
  type/        static typechecker + LSP
  pkg/         package manager
  test/        test runner
  crescent_examples/  demo scripts
dep/           vendored C dependencies (compiled binaries per platform)
docs/          design documents, inventory, perf log
```

Every package is a self-contained directory. Libraries are independent — you can vendor any one of them without the rest.

---

## Development

```bash
bin/cr test                    # run tests
bin/cr check <file>            # typecheck a file
bin/cr check --summary <file>  # grouped error summary (start here for noisy files)
cd docs && bun dev             # local docs server (requires bun)
nix develop                    # dev shell with bun and other contributor tools
```

For contributors on NixOS: `nix develop` provides contributor tooling. The LuaJIT in `bin/` handles everything at runtime.

---

## Related projects

- [rhi.zone](https://rhi.zone) — the broader rhi ecosystem
- [pterror/LuaJIT](https://github.com/pterror/LuaJIT) — the vendored LuaJIT build

---

## License

See [LICENSE](LICENSE) if present, or check individual library directories.
