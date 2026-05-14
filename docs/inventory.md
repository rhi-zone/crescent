# Inventory

This is the definitive index of what currently exists under `lib/`. Grep this file before designing or implementing anything reusable — a library, prelude, parser, codec, type declaration, util — to find out whether it already exists, partly exists, or is stubbed.

This file is hand-maintained. **When you add a new library or `_types.lua` file, add a line here in the same commit.** If the index lags behind reality, spot-check `lib/` directly before assuming something doesn't exist.

**Duplicate clusters triage:** see `docs/duplicate_clusters.md` for canonical-pick analysis of the ~25 duplicate library pairs/triplets noted inline below (`**Parallel to ...**`, `**Two parallel impls**`, etc.).

Status legend:
- **stable** — substantive code with real tests
- **wip** — partial, may be missing features or polish
- **stub** — empty-ish init.lua scaffold, placeholder
- **broken** — known-bad / abandoned (commented-out code, FIXMEs, no init.lua)

## Type preludes

These declare shared types and have no runtime code (or only declaration-side glue). Load via `--:: require "..."`.

- `lib/web/js_types.lua` — DOM, browser, and JS host API surface (DOMTokenList, Element, Event, fetch, history, etc., 2078 lines). **Use this** before redeclaring `Element` or any browser/JS type. Status: stable.
- `lib/caps/types.lua` — injected I/O capability function aliases (POpenFn, etc.). Status: stable.
- `lib/formats/ccv2/ccv2_types.lua` — Character Card v2 format types. Status: stable.
- `lib/http/format_types.lua` — `http_request` / `http_response` shape aliases. Status: stable.
- `lib/imap/format_types.lua` — IMAP (RFC 9051) flags and capability aliases. Status: stable.
- `lib/platform/apps/system_dashboard/primitive_types.lua` — system_dashboard pack output schema. Status: stable.
- `lib/platform/apps/system_dashboard/projections/projection_types.lua` — typed environment for projection authors (Children, Style, Props, sealed `dom` tag table, `text`, `Ctx`, `Projection`). Imports `Element`, `Text`, `Event` etc. from `lib/web/js_types.lua` rather than redeclaring them. Status: stable.
- `lib/taskgraph/taskgraph_types.lua` — taskgraph aliases. Status: stable.
- `lib/type/static/ctx_types.lua` — typechecker context (ctx) struct, used in self-check. Status: stable.
- `lib/type/static/stdlib_types.lua` — Lua 5.1 / LuaJIT stdlib type declarations. Status: stable.

## Type system / tooling

- `lib/type/` — runtime schema typechecker (separate from static).
  - `lib/type/static/` — full static typechecker. v2/v3 design (see `docs/typechecker-v2.md`). Includes `cli.lua`, `lsp.lua`, parser, constrain, narrow, unify, prelude, cdef parser, fuzzers. Status: stable.
  - `lib/type/search/` — Hoogle-style type search over the registry. Status: wip.
- `lib/lua2ts/` — Lua → TypeScript transpiler over the crescent AST. Status: wip.
- `lib/doc/` — docgen (extract typed API docs from Lua source via the typechecker). Status: wip.
- `lib/lsp/` — LSP protocol method binding library on top of `lib/jsonrpc`. Status: wip.
- `lib/mcp/` — Model Context Protocol server library on top of `lib/jsonrpc`. Status: wip.
- `lib/jsonrpc/` — JSON-RPC 2.0 dispatcher with pluggable transport. Status: stable.
- `lib/cr/` — unified `bin/cr` CLI dispatcher. Status: stable.
- `lib/cli/` — declarative CLI argument parser. Status: stable.
- `lib/pkg/` — package manager. Foundation only (semver, manifest, lock parsers); install algorithm not yet implemented. Status: wip.
- `lib/bundle/` — Lua module bundler (resolves static `require()`s and inlines). Status: stable.
- `lib/edit/` — byte-range file edit applier. Used by `cr check --fix` to apply diagnostic autofixes atomically. Status: stable.
- `lib/embed/` — module embedding helper. Status: wip.
- `lib/sandbox/` — capability-based script sandbox. Status: stable.
- `lib/stdlib/` — stdlib lint CLI. Status: wip.

## Test infrastructure

- `lib/test/` — test runner (`cli.lua`), `assert.lua`, `coverage.lua`, `fixture.lua` (snapshot), `fuzz.lua` (fast/guided), `gen.lua` + `prop.lua` (property), `arb.lua` (integrated shrinking). Status: stable.
- `lib/bench/` — micro-benchmarking framework with statistics. Status: stable.
- `lib/testing_utils/` — mocks, spies, parameterized tests, fake clock, HTTP recorder. Status: stable.

## Type preludes for tests / props — see Test infrastructure above.

## Network protocols

- `lib/dns/` — DNS. Status: stub (entry point is 9 lines).
- `lib/email/` — RFC 5322/MIME composition + SMTP client (RFC 5321). Status: stable.
- `lib/epoll/` — Linux epoll (and wepoll on Windows) wrapper. Status: wip.
- `lib/exec/` — process execution capability wrapper. Status: stable.
- `lib/fuse/` — FUSE filesystem bindings. Status: wip (no test file).
- `lib/git/` — Git protocol/repository operations (2154 lines). Status: wip (no test file).
- `lib/github/` — GitHub REST API client. Status: stable.
- `lib/http/` — HTTP server/client. Status: stable.
- `lib/http_static/` — static file server with CORS headers, pre-compressed file support (.gz/.br), and optional path-prefix stripping. Wraps `lib/http/router/static_full`. Status: stable.
- `lib/https/` — HTTPS layer. Status: wip.
- `lib/imap/` — IMAP RFC 9051 format/parser. Status: wip (no init.lua, no test).
- `lib/inotify/` — Linux inotify FFI. Status: wip (no test).
- `lib/jsonrpc/` — see Type system / tooling.
- `lib/keyring/` — secure API key storage (libsecret > tier fallback). Status: stable.
- `lib/ljsocket/` — LuaJIT FFI socket library. Status: stable (no test).
- `lib/mud_cp/` — MUD client protocol. Status: broken / wip (no init.lua, TODOs throughout).
- `lib/net/` — network address parsing/manipulation (no I/O). Status: stable.
- `lib/oauth/` — OAuth 2.0 helpers (URL building, PKCE, JWT decode). Status: stable.
- `lib/oauth2/` — OAuth2 client (RFC 6749) with injectable HTTP. Status: stable.
- `lib/realtime/` — realtime/subscription primitives. Status: stable.
- `lib/smtp/` — RFC 5321 SMTP client with injectable transport. Status: stable.
- `lib/socket/` — socket abstraction. Status: stub.
- `lib/tcp/` — TCP client. Status: wip (no init.lua, TODOs).
- `lib/tls/` — TLS. Status: wip (TODOs noted).
- `lib/websocket/` — WebSocket framing. Status: stable.
- `lib/wire/` — length-prefixed binary protocol framing. Status: stable.
- `lib/wire_protocol/` — varint, TLV, fixed-size, delimited framing. Status: stable.
- `lib/x509/` — X.509 cert parser (RFC 5280) on top of asn1+pem. Status: stable.

## Codecs / formats / serialization

- `lib/asn1/` — ASN.1 DER parser/writer (pure Lua). Status: stable.
- `lib/base32/` — RFC 4648 base32 / hex / Crockford. Status: stable.
- `lib/base58/` — Base58 / Base58Check (Bitcoin/IPFS). Status: stable.
- `lib/base64/` — RFC 4648 base64 (standard + URL-safe). Status: stable.
- `lib/bencode/` — BitTorrent bencoding. Status: stable.
- `lib/bson/` — BSON (MongoDB wire format). Status: stable.
- `lib/cbor/` — CBOR RFC 7049. Status: stable.
- `lib/codec/` — codec wrapper interface; `codec/base85/` ascii85. Status: stable.
- `lib/crc/` — CRC family. Status: stable.
- `lib/crc32/` — standalone CRC32. Status: stable.
- `lib/csv/` — RFC 4180 CSV. Status: stable.
- `lib/csv_query/` — SQL-like in-memory tabular query engine. Status: stable.
- `lib/csv_transform/` — CSV transform pipelines. Status: stable.
- `lib/decimal/` — exact decimal {coeff,exp}. Status: stable.
- `lib/dotenv/` — .env file parser with variable expansion. Status: stable.
- `lib/encode/` — `base64/`, `urlencode/`, `utf8/` bytes-level encodings. Status: stable.
- `lib/format/` — `json/` (ffi+pure+simd tiers), `cbor/`, `msgpack/`, `toml/`, `yaml/`. Status: stable.
- `lib/formats/ccv2/` — Character Card v2 (with adapters, lorebook, macros). Status: stable.
- `lib/hex_dump/` — hex dump utility. Status: stable.
- `lib/ical/` — iCalendar RFC 5545 parser/builder. Status: stable.
- `lib/ini/` — INI file parser. Status: stable.
- `lib/json/` — RFC 8259 JSON (top-level pure-Lua entry; see also `lib/format/json/`). Status: stable. **Note: parallel to `lib/format/json/` — consider using the tiered version under `lib/format/`.**
- `lib/json_patch/` — RFC 6901 + RFC 6902 (pointer + patch). Status: stable.
- `lib/json_schema/` — JSON Schema draft-7 validator. Status: stable. **Note: duplicate of `lib/jsonschema/` — both exist.**
- `lib/jsonschema/` — JSON Schema draft-07 validator. Status: stable. **Duplicate of `lib/json_schema/`.**
- `lib/markup/` — markup AST/parser. Status: stable.
- `lib/mime/` — MIME type table (extension → type). Status: stable.
- `lib/mimetype/` — mimetype lookup (smaller). Status: stub.
- `lib/msgpack/` — MessagePack. Status: stable.
- `lib/multipart/` — RFC 2046 multipart encoder/decoder. Status: stable.
- `lib/ndjson/` — NDJSON / JSON Lines. Status: stable.
- `lib/netstring/` — DJB netstring framing. Status: stable.
- `lib/patch/` — RFC 6902 JSON Patch. Status: stable. **Parallel to `lib/json_patch/` — both exist.**
- `lib/pem/` — PEM RFC 7468 parser/writer. Status: stable.
- `lib/png/` — PNG chunk-level reader/writer. Status: stable.
- `lib/proto/` — Protocol Buffers 3 wire format (schemas as Lua tables). Status: stable.
- `lib/protocol_buffer/` — Protobuf wire format (alternative impl). Status: stable. **Parallel to `lib/proto/`.**
- `lib/sexp/` — S-expression parser/serializer. Status: stable.
- `lib/struct/` — C-style binary pack/unpack (Python `struct` syntax). Status: stable.
- `lib/svg/` — SVG document builder. Status: stable.
- `lib/tar/` — POSIX.1-1988 ustar tar reader/writer. Status: stable.
- `lib/toml/` — TOML parser. Status: stable.
- `lib/url/` — URL parsing. Status: stable.
- `lib/uuid/` — UUID v4 + v7. Status: stable.
- `lib/wire/`, `lib/wire_protocol/` — see Network protocols.
- `lib/xml/` — XML 1.0 SAX/DOM parser. Status: stable.
- `lib/xpath/` — XPath 1.0 evaluator. Status: stable.
- `lib/yaml/` — YAML 1.2 (subset). Status: stable.

## Compression

- `lib/brotli/` — Brotli RFC 7932 (HTTP `br`). Status: stable.
- `lib/compress/` — tiered zlib/gzip (system FFI > pure Lua). Status: stable.
- `lib/huffman/` — Huffman coding. Status: stable.
- `lib/lz4/` — LZ4 block + frame. Status: stable.
- `lib/lz77/` — pure Lua LZ77 (raw, custom frame, NOT DEFLATE). Status: stable.
- `lib/rle/` — run-length encoding. Status: stable.
- `lib/snappy/` — Snappy. Status: stable.
- `lib/zstd/` — Zstandard RFC 8878. Status: stable.

## Crypto

- `lib/argon2/` — Argon2d/i/id (RFC 9106). Status: stable.
- `lib/auth/` — JWT (HS256), session tokens, password hashing. Status: stable.
- `lib/blake2/` — BLAKE2b/s (RFC 7693). Status: stable.
- `lib/chacha20/` — ChaCha20 + ChaCha20-Poly1305 AEAD. Status: stable.
- `lib/crypto/` — tiered AES-256-GCM, ChaCha20-Poly1305, HKDF, random (system-libcrypto > pure). Status: stable.
- `lib/cryptography/` — pure Lua SHA-256/512, HMAC, PBKDF2, ChaCha20, Poly1305, ct-compare. Status: stable. **Parallel to `lib/crypto/`; this one is the pure-Lua bag.**
- `lib/curve25519/` — X25519 RFC 7748. Status: stable.
- `lib/ed25519/` — Ed25519 RFC 8032 (libsodium tier > pure). Status: stable.
- `lib/hash/` — `crc32/`, `hmac/`, `md5/`, `sha1/`, `sha256/`, `xxhash/`. Status: stable.
- `lib/jwt/` — JWT RFC 7519 (HS256 only). Status: stable.
- `lib/murmurhash/` — MurmurHash3 x86_32/x86_128/x64_128. Status: stable.
- `lib/pbkdf2/` — PBKDF2 RFC 8018. Status: stable.
- `lib/poly1305/` — Poly1305 RFC 8439 §2.5. Status: stable.
- `lib/scrypt/` — scrypt RFC 7914. Status: stable.
- `lib/shamir/` — Shamir's Secret Sharing over GF(256). Status: stable.
- `lib/siphash/` — SipHash-2-4 / 1-3. Status: stable.
- `lib/totp/` — HOTP RFC 4226 + TOTP RFC 6238. Status: stable.
- `lib/vigenere/` — classical ciphers (Vigenère, Caesar, Atbash, Playfair, etc.). Status: stable.

## Parsers / grammars / DSLs

- `lib/aho_corasick/` — Aho-Corasick multi-pattern matching. Status: stable.
- `lib/css/` — CSS data structures. Status: stable.
- `lib/css_parser/` — CSS tokenizer + selector + declaration + stylesheet parser. Status: stable.
- `lib/datalog/` — Datalog. Status: stable.
- `lib/diff/` — Myers O(ND) diff. Status: stable.
- `lib/expr/` — math expression parser/evaluator + symbolic differentiation. Status: stable.
- `lib/expression_evaluator/` — expression evaluator with builtins. Status: stable. **Parallel to `lib/expr/`.**
- `lib/glob/` — glob pattern matching. Status: stable.
- `lib/grammar/` — PEG parser combinators. Status: stable.
- `lib/grammar_gen/` — context-free grammar text generation (Tracery-style). Status: stable.
- `lib/graphql/` — GraphQL parser + schema DSL + executor. Status: stable.
- `lib/graphql_parser/` — GraphQL query/SDL parser + AST printer. Status: stable. **Parallel to `lib/graphql/` parser portion.**
- `lib/grammar/`, `lib/peg/` — PEG (parser combinator) impls. **`lib/peg/` is parallel to `lib/grammar/`.**
- `lib/lex/` — see `lib/tokenizer/`.
- `lib/log_parser/` — log line parsing. Status: stable.
- `lib/markdown/` — Markdown → HTML / plaintext. Status: stable.
- `lib/markdown_it/` — high-level Markdown via mdast + hast. Status: stable.
- `lib/merge3/` — three-way text merge. Status: stable.
- `lib/parse/` — generic parser primitives. Status: stable.
- `lib/parser_combinators/` — parser combinators. Status: stable. **Parallel to `lib/grammar/` and `lib/peg/`.**
- `lib/peg/` — PEG. Status: stable.
- `lib/prolog/` — Prolog (Horn clause + unification). Status: stable.
- `lib/regex/` — tiered PCRE2 FFI > pure Lua. Status: stable.
- `lib/regex_builder/` — fluent DSL → Lua pattern strings. Status: stable.
- `lib/regexp/` — Thompson-NFA regex with capture groups (pure). Status: stable.
- `lib/sscanf/` — C-style scanf/sscanf. Status: stable.
- `lib/text_diff/` — character-level diff (diff-match-patch style). Status: stable.
- `lib/tokenizer/` — declarative lexer/tokenizer builder. Status: stable.
- `lib/ukanren/` — µKanren miniKanren. Status: stable.

## Markup / unified pipeline

- `lib/unified/` — unified.js-style pipeline; many submodules: `mdast/`, `hast/`, `nlcst/`, `xast/`, `remark*`, `rehype*`, `retext*`, `unist_util_*`, `xast_util_to_xml/`. Status: wip (some modules empty; see `lib/unified/STATUS.md`).
- `lib/hast/` — top-level hast (no init.lua). Status: stub.
- `lib/mdast/` — top-level mdast (no init.lua). Status: stub.
- `lib/remark/`, `lib/remark_*/`, `lib/rehype/`, `lib/rehype_*/` — top-level shells, no init.lua. Status: stub. **The real impls are under `lib/unified/`.**
- `lib/template/` — HTML template (escape + render). Status: stable.
- `lib/template_engine/` — Jinja2-style with inheritance, filters, macros. Status: stable.
- `lib/string_template/` — simple string interpolation. Status: stable.
- `lib/mustache/` — Mustache renderer. Status: stable.
- `lib/html/` — type-safe HTML builder (nominal element types). Status: stable.
- `lib/word_wrap/`, `lib/text_justify/`, `lib/text_stats/`, `lib/spell_check/`, `lib/porter_stemmer/`, `lib/soundex/`, `lib/levenshtein/`, `lib/fuzzy_match/`, `lib/markov/`, `lib/nat_lang/`, `lib/i18n/`, `lib/locale/`, `lib/humanize/` — text utilities. Status: stable.

## Web / UI

- `lib/translucent-css-theme/` — opt-in glassmorphic design system (translucent panels, layered 3D borders, blue primary). Pure CSS tokens + components plus `theme.js` (dark/light/system toggle persisted to localStorage). No Lua. Used by ccv2 and library platform apps via symlinks under their `static/` dirs. Status: stable.
- `lib/web/` — web app framework (middleware, routing, cookies, CSRF, static). Status: stable.
  - `lib/web/html/` — typed HTML builder. Status: stable.
  - `lib/web/reactive_dom/` — reactive DOM bindings (uses `lib/web/js_types.lua`). Status: stable.
  - `lib/web/js_types.lua` — see Type preludes.
- `lib/router/` — URL routing (trie-based). Status: stable.
- `lib/canvas/` — 2D pixel canvas with PPM/PGM/BMP export. Status: stable.
- `lib/color/`, `lib/color_palette/`, `lib/color_space/`, `lib/gradient_descent/` (numerics, see below) — color toolchain. Status: stable.
- `lib/tui/` — TUI widget layer on top of `lib/ansi`. Status: stable.
- `lib/ansi/` — ANSI escapes (4/8/24-bit color, cursor, control). Status: stable.
- `lib/widget/` — platform-agnostic reactive widget layer. Status: wip.
- `lib/layout/` — layout engine. Status: stable.
- `lib/pretty_print/` — value pretty printer. Status: stable.
- `lib/qrencode/` — QR code encoder. Status: wip (no test).
- `lib/barcode/` — Code128/EAN/UPC/Code39 + SVG. Status: stable.

## Reactive / state / signals

- `lib/reactive/` — push-based signal/computed/effect/batch. Status: stable.
- `lib/reactive_db/` — reactive in-memory relational DB with live queries. Status: stable.
- `lib/reactive_optics/` — signals composed with `lib/fp/optics`. Status: stable.
- `lib/reactive_store/` — Redux/Zustand-style store. Status: stable.
- `lib/reactive_stream/` — pull-based Rx-style stream combinators. Status: stable.
- `lib/reactive_var/` — fine-grained reactive var (MobX/Solid/Vue style). Status: stable.
- `lib/signals/` — auto-tracking signals (Solid/Preact style). Status: stable. **Note: parallel to `lib/reactive/`; signals auto-tracks, reactive is explicit.**
- `lib/signal/` — POSIX signal handling. Status: stable.
- `lib/observable/`, `lib/observer/` — push observables with operators (cold, sync). Status: stable. **Two parallel impls.**
- `lib/event/`, `lib/event_emitter/` — event bus / pub-sub. Status: stable. **Two parallel impls.**
- `lib/event_sourcing/` — event store + aggregates + projections + sagas. Status: stable.
- `lib/pubsub/` — pub/sub with topic patterns + middleware. Status: stable.
- `lib/mediator/` — mediator pattern (commands/queries/events). Status: stable.

## Async / concurrency / scheduling

- `lib/actor/` — coroutine actor model with supervision/links/monitors. Status: stable.
- `lib/async/` — promise-based async/await on coroutines. Status: stable.
- `lib/async_queue/` — coroutine work queue with priorities/retries/rate limits. Status: stable.
- `lib/chan/` — Go-style coroutine channels. Status: stable.
- `lib/promise/` — synchronous Promises/A+ inspired. Status: stable.
- `lib/scheduler/` — cooperative coroutine scheduler with priorities + timers. Status: stable.
- `lib/semaphore/` — semaphore/mutex/event/condvar/channel (coroutine-safe). Status: stable.
- `lib/task_queue/` — min-heap task queue. Status: stable.
- `lib/task_runner/` — Make-style task runner with topo dependency resolution. Status: stable.
- `lib/taskgraph/` — task DAG. Status: wip.
- `lib/workflow/` — workflow primitives. Status: stable.
- `lib/pipeline/` — lazy data pipeline. Status: stable.
- `lib/pipeline_dsl/` — composable lazy DSL. Status: stable.
- `lib/circuit_breaker/` — fault-tolerant call wrapper (CLOSED/OPEN/HALF_OPEN). Status: stable.
- `lib/connection_pool/` — generic connection pool. Status: stable.
- `lib/ratelimit/`, `lib/rate_limiter/` — token bucket. Status: stable. **Two parallel impls.**
- `lib/retry/` — retry strategies (exp/linear/fib/none) + circuit breaker. Status: stable.
- `lib/cron/` — cron scheduler. Status: stable.
- `lib/cron_parser/` — cron expression parser (5-field + 6-field). Status: stable. **Parallel to `lib/cron/`.**
- `lib/timerfd/` — Linux timerfd FFI. Status: wip.
- `lib/notify/` — notification dispatch. Status: stable.

## Data structures

- `lib/bigint/` — arbitrary-precision integer (base-10^7 chunks). Status: stable.
- `lib/bignum/` — BigDecimal-style arbitrary precision decimal float. Status: stable.
- `lib/bin_packing/` — bin-packing algorithms. Status: stable.
- `lib/bitarray/` — packed bit storage with multi-bit fields. Status: stable.
- `lib/bits/` — bitset + Bloom filter. Status: stable.
- `lib/bitset/` — auto-growing dense bitset. Status: stable. **Parallel to `lib/bits/`.**
- `lib/bloom/`, `lib/bloom_count/`, `lib/bloom_filter/`, `lib/bloom_clock/` — Bloom variants. Status: stable. **Multiple parallel impls.**
- `lib/cache/`, `lib/lru/`, `lib/lru_cache/`, `lib/lru_ttl/` — caches. Status: stable. **Multiple parallel impls.**
- `lib/columnar/` — columnar storage / aggregation. Status: stable.
- `lib/consistent_hash/` — consistent hashing. Status: stable.
- `lib/count_min/` — Count-Min Sketch. Status: stable.
- `lib/cuckoo/` — cuckoo filter (with delete). Status: stable.
- `lib/deque/` — double-ended queue. Status: stable.
- `lib/disjoint_set/` — union-find. Status: stable.
- `lib/fenwick_tree/` — Fenwick / Binary Indexed Tree. Status: stable.
- `lib/hamt/` — hash array mapped trie. Status: stable.
- `lib/heap/`, `lib/pairing_heap/` — heaps. Status: stable.
- `lib/hyperloglog/` — HyperLogLog++. Status: stable.
- `lib/interval/`, `lib/interval_tree/` — interval arithmetic + interval BST. Status: stable.
- `lib/inverted_index/` — inverted index. Status: stable.
- `lib/kdtree/` — k-d tree. Status: stable.
- `lib/kv_store/` — in-memory KV with TTL + namespaces. Status: stable.
- `lib/multimap/`, `lib/multiset/`, `lib/ordered_map/`, `lib/set/` — collection variants. Status: stable.
- `lib/patricia_trie/` — radix/compressed trie. Status: stable.
- `lib/persistent/` — persistent (immutable) data structures. Status: stable.
- `lib/pool/`, `lib/pool_allocator/` — object/arena pools. Status: stable.
- `lib/quadtree/`, `lib/spatial_hash/` — 2D spatial indices. Status: stable.
- `lib/queue/` — priority + FIFO + ring buffer. Status: stable.
- `lib/red_black_tree/` — RB tree. Status: stable.
- `lib/ringbuf/` — ring buffer. Status: stable.
- `lib/rope/` — rope structure for big strings. Status: stable.
- `lib/segment_tree/` — segment tree. Status: stable.
- `lib/skiplist/` — skip list with rank queries. Status: stable.
- `lib/sparse_matrix/` — DOK/CSR/COO. Status: stable.
- `lib/suffix_array/` — suffix array + LCP. Status: stable.
- `lib/treap/` — treap (split/merge). Status: stable.
- `lib/trie/` — prefix tree. Status: stable.

## Numerics / math / stats / ML

- `lib/astar/` — A*. Status: stable.
- `lib/bayesian_filter/` — Naive Bayes spam-style filter. Status: stable.
- `lib/benford/` — Benford's Law analysis. Status: stable.
- `lib/bezier/` — Bézier curves & splines (2D/3D, Catmull-Rom, Hermite). Status: stable.
- `lib/calendar/` — calendar utilities. Status: stable.
- `lib/complex/` — complex numbers. Status: stable.
- `lib/constraint_solver/` — CSP backtracking + AC-3. Status: stable.
- `lib/convex_hull/` — convex hull. Status: stable.
- `lib/datetime/`, `lib/duration/`, `lib/time/`, `lib/time_series/` — time arithmetic. Status: stable.
- `lib/decision_tree/` — decision tree learner. Status: stable.
- `lib/dice/` — dice notation parser/evaluator. Status: stable.
- `lib/dsp/` — digital signal processing. Status: stable.
- `lib/easing/` — Penner easing. Status: stable.
- `lib/finance/`, `lib/money/` — financial primitives, exact-minor-units money. Status: stable.
- `lib/finite_field/` — GF(p) and GF(2^n) + polynomials. Status: stable.
- `lib/flow_network/` — Edmonds-Karp max flow + min cut. Status: stable.
- `lib/genetic/` — genetic algorithm framework. Status: stable.
- `lib/geo/`, `lib/geo_hash/`, `lib/geohash/` — geospatial; `geohash` is duplicate of `geo_hash`. Status: stable.
- `lib/geom/`, `lib/geometry_3d/`, `lib/game_math/`, `lib/vec/`, `lib/matrix/`, `lib/matrix_ext/` — geometry/linear algebra. Status: stable.
- `lib/graph/`, `lib/graph_algorithms/`, `lib/graph_coloring/`, `lib/graph_layout/`, `lib/graph_query/` — graph family. Status: stable.
- `lib/gradient_descent/` — GD/Adam/RMSProp/L-BFGS/CG/SGD/line search/numdiff. Status: stable.
- `lib/hamming/` — Hamming codes + parity. Status: stable.
- `lib/interpolation/`, `lib/interpolation_curves/` — 1D/2D splines. Status: stable.
- `lib/kalman/` — Kalman filter. Status: stable.
- `lib/knn/` — k-nearest neighbors. Status: stable.
- `lib/lindenmayer/`, `lib/lsystem/` — L-systems; `lsystem` is parallel/older. Status: stable.
- `lib/luhn/` — Luhn checksum. Status: stable.
- `lib/math/` — math utilities: `tointeger(x) -> integer | nil`. Status: stable.
- `lib/math_ext/` — extended math.*. Status: stable.
- `lib/minimax/` — minimax + αβ + iterative deepening + MCTS. Status: stable.
- `lib/neural/`, `lib/neural_net/` — feedforward NN with backprop. Status: stable. **Two parallel impls.**
- `lib/noise/`, `lib/noise_gen/` — Perlin/Simplex/Worley/fBm/turbulence/domain-warping. Status: stable. **`noise_gen` is the larger/newer one.**
- `lib/number_theory/` — number theory utilities. Status: stable.
- `lib/particle/` — particle systems. Status: stable.
- `lib/physics_2d/` — 2D rigid body (semi-implicit Euler, AABB/circle, joints). Status: stable.
- `lib/pid/` — PID controller. Status: stable.
- `lib/rand/` — RNG. Status: stable.
- `lib/rational/` — exact rationals (GCD-normalized). Status: stable.
- `lib/roman/`, `lib/roman_numeral/` — Roman numerals; `roman_numeral` is the extended/Unicode one. Status: stable.
- `lib/sat/` — DPLL SAT solver. Status: stable.
- `lib/simulated_annealing/` — simulated annealing. Status: stable.
- `lib/stats/` — descriptive stats, distributions, hypothesis tests, regression. Status: stable.
- `lib/symbolic_diff/` — symbolic differentiation. Status: stable.
- `lib/tfidf/` — TF-IDF. Status: stable.
- `lib/units/` — unit conversion. Status: stable.
- `lib/voronoi/` — Voronoi + Bowyer-Watson Delaunay. Status: stable.
- `lib/wavelet/`, `lib/wave/` — wavelet transforms / waveforms. Status: stable.
- `lib/xgboost/` — gradient-boosted trees. Status: stable.

## Storage / DB

- `lib/conversation/` — SQLite-backed conversation tree. Status: stable.
- `lib/db/` — DB abstraction. Status: stable.
- `lib/ecs/` — SQLite-backed entity-component store. Status: stable.
- `lib/entity_component/` — in-memory ECS. Status: stable. **Parallel to `lib/ecs/`.**
- `lib/mini_orm/` — pure-Lua in-memory ORM. Status: stable.
- `lib/query_builder/` — fluent SQL query builder. Status: stable.
- `lib/raft/` — Raft state machine (no networking). Status: stable.
- `lib/schema/` — declarative schema migration DSL. Status: stable.
- `lib/sqlite/` — SQLite FFI bindings. Status: stable.

## OS / FFI / platform

- `lib/asm/` — CPU feature detection + kernel compilation. Status: stable.
- `lib/caps/` — capability type aliases (no init.lua, types only). Status: stable.
- `lib/dynamic_library/` — dynamic library loading. Status: wip.
- `lib/env/` — environment variable access (capability-injected). Status: stable.
- `lib/env_schema/` — typed env var schema validation. Status: stable.
- `lib/cloc/` — count lines of code/comments/blank by language extension; capability-injected I/O. Status: stable.
- `lib/expand_c/` — C macro expansion via `cc -E`; capability-injected popen. Status: stable.
- `lib/find_cli/` — filesystem search with predicate DSL (name, size, age, bool combinators); capability-injected walk and time. Status: stable.
- `lib/fs/` — filesystem ops. Status: stable.
- `lib/linux/` — Linux /proc parsing (no init.lua). Status: wip.
- `lib/path/` — cross-platform path string ops (no I/O). Status: stable.
- `lib/platform/` — platform runner: tarball app loader + sandboxed entrypoints + cap dispatch + daemon + service + session. Status: stable.
- `lib/platform/caps/cap_types.lua` — type declarations for all platform cap interfaces (CliCap, TimeCap, DbCap, FsCap, HttpServerCap, HttpClientCap, LlmCap, ShellCap, ExecCap, CreateInstanceCap, HttpReq, HttpRes, etc.). Declarations only. Status: stable.
- `lib/platform/caps/create_instance.lua` — `create_instance` cap: lets a sandboxed app install a new instance of itself by handing the platform raw PNG/tarball bytes; the cap extracts the calling app's runtime from its installed tarball and feeds it through `import_card`. Returns `(app_id, launch_url)`. Designed for the "frictionless new card" cross-origin path (ccv2). Status: stable.
- `lib/platform/platform_types.lua` — core platform type declarations (Manifest, CapDecl, EntryDef, AppRecord, TarEntry). Declarations only. Status: stable.
- `lib/posix/` — POSIX (no init.lua, TODOs noted). Status: wip.
- `lib/process/` — process spawning. Status: stable.
- `lib/stb/` — tiered stb_image / stb_image_resize2 (vendored binary > libvips > pure). Status: stable.

## Apps and demos

- `lib/crescent_examples/` — small demos (3d_view etc.). Not a library — examples only.
- `lib/platform/apps/charactercardv2/` — Character Card v2 app (server, llm, presets, import, manifest). Status: stable.
- `lib/platform/apps/library/` — general-purpose collection browser with adapter interface. Status: stable.
- `lib/platform/apps/sillytavern/` — SillyTavern source adapter. Status: wip.
- `lib/platform/apps/system_dashboard/` — system dashboard BFF (search, packs, projections, output). Status: stable.

## Game / generative / simulation

- `lib/automata/` — NFA/DFA construction + simulation. Status: stable.
- `lib/automata_2d/` — advanced 2D CA (Game of Life variants, totalistic). Status: stable.
- `lib/cellular_automata/` — 1D Wolfram + 2D totalistic. Status: stable. **Parallel to `lib/automata_2d/`.**
- `lib/finite_automata/` — finite automata. Status: stable. **Parallel to `lib/automata/`.**
- `lib/behavior_tree/` — behavior tree. Status: stable.
- `lib/circuit_sim/` — analog circuit MNA simulator. Status: stable.
- `lib/logic_circuit/` — digital logic + Quine-McCluskey. Status: stable.
- `lib/midi/` — Standard MIDI File parser/encoder. Status: stable.
- `lib/network_sim/` — network simulator (deterministic LCG). Status: stable.
- `lib/solitaire/` — headless Klondike engine. Status: stable.
- `lib/solitaire_cli/` — interactive CLI renderer and runner for Klondike Solitaire; wraps `lib/solitaire` with injected I/O. Status: stable.
- `lib/state/`, `lib/state_machine/`, `lib/statemachine/`, `lib/state_machine_hsm/`, `lib/fsm/` — FSM/HSM family (5 parallel-ish impls; `state_machine_hsm` and `statemachine` are HSM/Harel charts; others are flat). Status: stable.
- `lib/steering/` — Reynolds-style 2D steering behaviors. Status: stable.
- `lib/tilemap/` — tilemap. Status: stable.

## Reliability / observability / config

- `lib/config/` — layered config (args > env > layers > defaults). Status: stable.
- `lib/feature_flags/` — feature flags with rollout/rules/variants. Status: stable.
- `lib/log/` — structured logging with sinks. Status: stable.
- `lib/metric/` — Prometheus-compatible counter/gauge/histogram/summary. Status: stable.
- `lib/openapi/` — OpenAPI 3.x parser + request validation + typed routes. Status: stable.
- `lib/pagination/` — offset/page/cursor pagination. Status: stable.
- `lib/schema_gen/` — JSON Schema inference + validation. Status: stable.
- `lib/schema_validator/` — schema validator. Status: stable. **Parallel to `lib/json_schema/`, `lib/jsonschema/`, `lib/validate/`, `lib/validation/`.**
- `lib/service_registry/` — in-process service registry. Status: stable.
- `lib/tracing/` — OTel-inspired spans/traces/exporters. Status: stable.
- `lib/validate/`, `lib/validation/` — validation libs. Status: stable. **Two parallel impls.**

## FP / optics / monads

- `lib/fp/` — typeclass hierarchy: `adt/`, `alt/`, `applicable/`, `bifunctor/`, `chainable/`, `either/`, `first/`, `fn/`, `foldable/`, `last/`, `mappable/`, `max/`, `maybe/`, `min/`, `monoid/`, `optics/`, `product/`, `profunctor/`, `semigroup/`, `sum/`, `traversable/`. See `lib/fp/CLAUDE.md`. Status: wip — design in flux.
- `lib/curry/` — composition + currying + partial application. Status: stable.
- `lib/either/` — top-level Either<L,R> + Maybe<T> with functor/monad. Status: stable. **Parallel to `lib/fp/either/` and `lib/fp/maybe/`.**
- `lib/functional/` — comprehensive FP toolkit. Status: stable.
- `lib/iter/` — iterator combinators. Status: stable.
- `lib/option/` — Option/Maybe. Status: stable. **Parallel to `lib/fp/maybe/` and `lib/either/` Maybe.**
- `lib/result/` — Result with Ok/Err sentinels. Status: stable.
- `lib/stream/` — stream combinators. Status: stable.

## Misc / utilities

- `lib/agent/` — agent (no header — entry is the test file?). Status: wip.
- `lib/ai/` — provider registry (lazy-loaded). Status: wip.
- `lib/bayesian_filter/` — see Numerics.
- `lib/command/`, `lib/command_queue/` — command pattern. Status: stable.
- `lib/conversation/` — see Storage / DB.
- `lib/crdt/` — CRDT primitives. Status: stable.
- `lib/deepcopy/` — deep copy + table utilities. Status: stable.
- `lib/hot_reload/` — hot module reload. Status: stable.
- `lib/image_processing/` — image processing. Status: stable.
- `lib/ir/` — intermediate representation. Status: stable.
- `lib/memoize/` — memoize/once/debounce/lru/ttl/weak/multi. Status: stable.
- `lib/merge/` — table merge. Status: stable.
- `lib/merkle/`, `lib/merkle_tree/` — Merkle tree. Status: stable. **Two parallel impls.**
- `lib/search/` — search. Status: stable.
- `lib/semver/` — Semver 2.0 parser/comparator. Status: stable.
- `lib/string_ext/`, `lib/table_ext/` — extended Lua stdlib utilities. Status: stable.
- `lib/spreadsheet/` — spreadsheet grid with formula eval + dep tracking. Status: stable.
- `lib/vm/` — stack-based bytecode VM. Status: stable.
