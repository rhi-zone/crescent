# Crescent: Batteries Included

The goal is an ecosystem so complete that you reach for crescent regardless of what
you're building — a PIM, a web service, a game, a language server, an RP engine, an
LLM pipeline. The motivating examples are not the point; the foundation is the point.
The examples just prove the foundation is real.

## Motivating targets

### Lumen

A local-first personal information manager: ingest (text, markdown, PDF, images, audio,
links), full-text search, tagging, self-hosted E2E-encrypted sync, voice transcription,
web archiving. Every piece maps to a crescent primitive:

| Lumen feature | Crescent primitive |
|---|---|
| Ingest pipeline | `lib/taskgraph`, `lib/fs`, `lib/process` |
| PDF/image/audio parsing | `lib/format/*`, `lib/process` (subprocess) |
| Web archiving | `lib/http`, `lib/html` |
| Full-text search | `lib/sqlite` (FTS5) |
| Tag inference | `lib/taskgraph/executor/ai` |
| E2E encrypted sync | `lib/http`, `lib/crypto` (AES-GCM, HKDF) |
| CLI | `lib/cli` (arg parsing) |

Lumen is the proof that crescent's stdlib is broad enough for real applications.

### Distribution thesis

The complete crescent ecosystem — every library in this document implemented — is
approximately **~8MB of pure Lua** plus ~4MB of runtime (LuaJIT binary, SQLite,
vendored stb binaries). **~12MB total.**

SillyTavern, for comparison, is 433MB installed (334MB `node_modules` alone). A
typical Node.js app's dependency tree exceeds the entire crescent ecosystem before
the first line of application code runs.

This isn't just "lean" — it's small enough to travel inside other things. An RP
frontend, a game, a dev tool, a CLI utility: anything users will download without
asking questions. The download is honest about what it is; users just have a small
mental model of what "RP frontend" implies. What they actually install is a complete,
hackable, vendorable computing substrate.

The propagation mechanism is inspection. Every file is readable Lua with no build step.
Someone opens the install directory, reads `lib/reactive/init.lua`, understands it,
copies it into their own project. That's how the ecosystem spreads — not through a
registry, through curiosity.

**The goal:** get LuaJIT + crescent onto every machine by being the best version of
whatever people actually want to download. The OS layer arrives as a footnote.

### Portable application substrate

Self-contained, portable applications: logic + state + UI bundled into a single
distributable artifact that runs anywhere LuaJIT runs. Zero setup, zero dependencies
beyond the vendored runtime. The entire app is the artifact.

Motivating targets: an LLM interaction platform (replacing SillyTavern, Talemate,
Claude Code), a file manager, a markdown viewer, a unified workspace (Deskspace-in-Lua)
— each dissolving an artificial app boundary. The long-term direction: every user-facing
layer of the OS-as-Lua goal.

**LLM interaction platform** — generic enough to replace SillyTavern, Talemate, and
Claude Code, not by being all three, but by being the substrate they're programs on
top of.

**Core thesis (from `lib/taskgraph`):** the LLM is a stateless oracle. Conversation
is context poisoning. The right unit is a function call. The orchestrator is a program,
not an agent. ST/Talemate/Claude Code are different programs that call LLMs — the
platform gives primitives and requires you to write the loop.

**Distribution format:** programs embedded in PNG metadata. A "character" or scenario
is a Lua script in a PNG tEXt chunk — the image is the distributable. Visual
representation and executable loop in one file, zero extra dependencies (LuaJIT is
already vendored). The card carries:
- The interaction loop (turn script)
- The world state schema
- The editor UI (via `lib/reactive_optics`)
- Its own import/export logic for CCv2/charx/etc — the card is self-describing,
  the platform has no hardcoded knowledge of any card format

**What this fixes about SillyTavern:**
- No database → SQLite, search is instant, tags are joins
- Conversation-as-foundation → loop is user code; accumulation is a choice
- LLM-derived worldstate → state is written by the program, read by the LLM, never held by it
- Entity isolation → each character is a function call with explicit inputs; cross-contamination impossible by construction
- Lorebook triggers = fields pretending to be a language → predicates are code
- 23k characters, no index, full CCv2 JSON blob → indexed, virtualized, thumbnails on import

**Security:** capability-based. The turn script gets exactly the capabilities it's
handed — LLM oracle, worldstate read/write, render surface. No ambient authority. The
threat surface is "what capabilities did the platform hand this card?" — auditable and
small. UI code (Rainbow/reactive_optics) is lower-risk; sanitization at the render
boundary is sufficient.

**Architecture:** Lua HTTP server + SQLite + `lib/reactive_optics` frontend. Cap'n Proto
for the control plane if latency becomes a problem (promise pipelining eliminates
roundtrip chains). Thumbnail generation via stb_image_resize compiled into the binary
(zero runtime dep).

**Other frontends follow the same pattern:**
- File manager — browse, preview, edit as one surface (Deskspace-in-Lua)
- Markdown viewer / editor
- Archive tool
- Eventually: the entire user-facing OS layer

**CCv2/lorebook compatibility** is best-in-class but a footnote: CCv2 is lossless
import, lossy export. The card embeds its own import/export logic — the platform has
no hardcoded knowledge of CCv2, charx, or any other format. Lorebooks dissolve into
worldstate queries; the lorebook editor is only needed for the compatibility surface.

| Component | Crescent primitive |
|---|---|
| World state | `lib/sqlite` + entity model |
| LLM task dispatch | `lib/taskgraph` + `lib/taskgraph/executor/ai` |
| Prose assembly | Lua string ops (no dedicated library needed) |
| Reactive UI | `lib/reactive_optics` |
| HTTP server/API | `lib/http` |
| Card format (PNG + metadata) | `lib/png` (chunk r/w, tEXt helpers) |
| Capability sandbox | `lib/sandbox` |
| Platform runner + cap factories | `lib/platform` (card loader, `caps.png`, `caps.llm`, `caps.render`, `caps.fs`) |
| Thumbnail generation | stb_image_resize via FFI (compiled in) |

### Full-stack dashboard

A production admin dashboard/control plane: web backend, auth, database with
migrations, realtime updates, structured logging, frontend via `lib/reactive_optics`
+ `lib/lua2ts`. Not a new library — an application pattern that exercises the entire
stack end-to-end. If this works without reaching outside crescent, the ecosystem is
real for the web/ops crowd.

The key insight: the model is not the container of state. State lives in a real data
structure; the model is a function over it. The context window is a view, not the truth.

## What "batteries included" means

### Already exists (lib/)

- **Test infrastructure** — runner, property testing, fuzz testing, fixture/snapshot,
  integrated shrinking, parallel execution
- **Typechecker** — static checker, LSP daemon, SARIF/JSON output; constraint-based
  inference (v2 flat-array AST + arena allocation, v3 constraint solver); fuzz suite
  (algebra invariants, eval-tier computation contracts, grammar-tier end-to-end);
  lint rule passes (unannotated exports, assert-in-lib, naming, bare-bit, dead-locals,
  predicate return type); type search by signature; generic parameter defaults;
  interface declarations (`--:: Name: Base`) with oracle; partial application of generic
  aliases; `$EachField` flatMap; `$Throw`/`$Catch` type-level error pair;
  spread-in-tuple-position for multi-return; `%Name` capture sigil and `{ ...[%K]: %V }`
  all-fields pattern; function-type and indexer arm patterns in match types
- **Network** — HTTP (client + server), WebSockets, DNS, TLS (partial)
- **Storage** — SQLite
- **Encoding** — JSON, CBOR, base64, UTF-8, URL encoding, MessagePack
- **Hashing** — SHA-1, SHA-256, HMAC
- **System** — fs, process, path, env, time, signal, epoll, inotify, timerfd
- **Concurrency** — epoll event loop (partial), fork-based parallelism in test runner
- **Random** — CSPRNG (getrandom / /dev/urandom)
- **Functional** — fp/ typeclasses (Maybe, Either, lens, prism), iter combinators
- **AI** — provider dispatch (Anthropic, OpenAI, Google), streaming, embeddings, tools
- **Orchestration** — task graph, execution engine, combinators (map/retry/refine),
  LLM executor at `lib/taskgraph/executor/ai`
- **Package manager** — semver, manifest, lockfile (install not yet implemented)
- **Markdown** — `lib/mdast`: CommonMark parser (Phase 1) producing mdast-compatible AST
  nodes; block structure (headings, paragraphs, fenced/indented code, thematic breaks,
  blockquotes, lists, HTML, link definitions) + inline parsing (emphasis, strong,
  inline code, links, images, hard breaks); `mdast.stringify` for basic round-trip
- **HTML AST** — `lib/hast`: mdast-to-hast transformer + HTML serializer. Converts a
  mdast tree to a hast tree (element/text/raw nodes), then serializes to an HTML string.
  Convenience: `hast.md_to_html(source)` runs the full mdast → hast → HTML pipeline.
  Covers all mdast Phase 1 node types including tables.

### Missing — stdlib tier

These belong in `lib/` and block real applications:

**Async I/O / event loop** — the largest gap. Without a proper event loop (io_uring on
Linux, kqueue on macOS), crescent can't do high-concurrency servers or multiplex
connections. Everything currently blocks. This is the single change that unlocks the
most use cases. Design: sans-I/O core, injectable scheduler, `lib/reactor` or
`lib/loop`.

**Datetime** (`lib/datetime`) — implemented. Date/time library exists.

**Time** (`lib/time`) — **implemented**. Durations and timestamps. Duration stored as
integer nanoseconds; supports ns/us/ms/s/min/h/d units. `components()`, arithmetic
(`+`/`-`/`*`/`/`), `format()`/`format_short()`/`format_precise()`, `duration_parse("5h30m")`.
Timestamps: `from_unix`/`from_unix_ms`/`now()`, `format_rfc3339`, `parse_rfc3339` (TZ offset,
fractional seconds). 116 assertions.

**Regex** (`lib/regex`) — implemented. PCRE2 FFI system tier + pure Lua backtracking
fallback. API: `compile`, `match`, `find`, `gmatch`, `gsub`, `split`. Compiled regex
objects for reuse. 70+ assertions with parity tests between tiers.

**CLI arg parsing** (`lib/cli`) — implemented. Declarative spec API: subcommands,
typed flags/options, auto-generated help/version, shell completions (bash/zsh/fish),
combined short flags, array options, positionals. 70 assertions.

**Structured logging** (`lib/log`) — implemented. Named loggers with level filtering,
structured fields, and pluggable sinks. API: `log.new(name, opts)`, `:trace/debug/info/warn/error(msg, fields?)`,
`:child(suffix)`, `:set_level(level)`, `:add_sink(fn)`, `:remove_sink(fn)`.
Built-in sinks: `stderr_sink`, `stdout_sink`, `file_sink`, `collect_sink` (testing).
Formats: `text` (2026-04-10T12:00:00Z INFO  [name] msg key=val), `json` (one JSON object per line),
`ansi` (colored, uses lib/ansi, falls back to text when disabled).
OpenTelemetry trace IDs not yet implemented.

**UUID** (`lib/uuid`) — implemented. v4 (random) and v7 (timestamp+monotonic, sortable).
FFI tiers: getrandom (Linux) → arc4random_buf (macOS/BSD) → /dev/urandom → pure Lua.
API: `uuid.v4()`, `uuid.v7()`, `uuid.parse(s)`, `uuid.fmt(b)`, `uuid.is_valid(s)`, `uuid._tier`.

**Compression** (`lib/compress`) — implemented. System tier (zlib FFI: full deflate +
inflate, streaming, zlib/gzip/raw formats) + pure Lua tier (inflate only, RFC 1951).
Parity-tested. zstd deferred. 24 assertions.

**Mustache** (`lib/mustache`) — implemented. Spec-compliant Mustache template engine:
variable interpolation (escaped/unescaped), sections (conditional/iteration/lambda),
inverted sections, comments, partials with indentation inheritance, set delimiter,
dot notation, implicit iterator, standalone line handling, context stack. 43 assertions.

**Crypto** (`lib/crypto`) — implemented. AES-256-GCM (system libcrypto FFI),
ChaCha20-Poly1305 (system + pure Lua reference), HKDF-SHA256 (RFC 5869),
random_bytes. Pure Lua tier has ChaCha20+HKDF; AES requires libcrypto.
36 assertions + 10 skipped without libcrypto.

**Ed25519** (`lib/ed25519`) — **implemented**. Ed25519 digital signatures (RFC 8032). Two
tiers: system (`libsodium` FFI) and pure Lua (inline SHA-512 + GF(2^255-19) field
arithmetic + extended Edwards coordinates). `keypair(seed)`, `sign(privkey, msg)`,
`verify(pubkey, msg, sig)`. Verified against libsodium. 55 assertions.

**ChaCha20** (`lib/chacha20`) — **implemented**. ChaCha20 stream cipher and
ChaCha20-Poly1305 AEAD (RFC 7539). `encrypt/decrypt`, `keystream`, `aead_encrypt/
aead_decrypt`. Pure Lua with FFI `uint64_t` for Poly1305 130-bit arithmetic.
Verified against RFC 7539 test vectors. 66 assertions.

**MurmurHash3** (`lib/murmurhash`) — **implemented**. All three MurmurHash3 variants:
`x86_32` (32-bit output), `x86_128` (128-bit, 32-bit platform), `x64_128` (128-bit,
64-bit platform, uses FFI `uint64_t`). `hash32`/`hash128` aliases. `*_hex` variants.
Verified against Python mmh3 and C reference. 63 assertions.

**scrypt** (`lib/scrypt`) — **implemented**. scrypt password-based KDF (RFC 7914).
`derive(password, salt, N, r, p, dklen)`, `derive_hex`, `verify`. Pure Lua Salsa20/8
core + scryptBlockMix + scryptROMix. Uses `lib/pbkdf2` for HMAC-SHA256 steps.
Verified against RFC 7914 §12 test vectors. 41 assertions.

**ASN.1** (`lib/asn1`) — **implemented**. DER (Distinguished Encoding Rules) parser and
writer (RFC 5280). `decode_tlv`, `decode_sequence`, typed decoders (`decode_integer`,
`decode_boolean`, `decode_oid`, `decode_bit_string`, `decode_string`, `decode_time`),
`decode` dispatcher. Encoders: `encode_tlv/null/boolean/integer/octet_string/
utf8_string/sequence/oid`. Round-trip verified. 146 assertions.

**PBKDF2** (`lib/pbkdf2`) — **implemented**. Password-Based Key Derivation Function 2
(RFC 8018 §5.2). `derive(password, salt, iterations, dklen)`, `derive_hex`,
`verify` (timing-safe). Supports SHA-1 and SHA-256 PRFs via `lib/hash/hmac`.
Verified against all RFC 6070 test vectors. 37 assertions.

**SipHash** (`lib/siphash`) — **implemented**. SipHash-2-4 and SipHash-1-3 PRF (64-bit
output). `hash/hash_hex/hash_pair` (SipHash-2-4), `hash13/hash13_hex` (SipHash-1-3).
LuaJIT FFI `uint64_t` for 64-bit arithmetic. Verified against reference vectors.
42 assertions.

**LZ4** (`lib/lz4`) — **implemented**. LZ4 block and frame format (pure Lua).
`compress_block`/`decompress_block` (raw LZ4 block), `compress`/`decompress` (LZ4
frame with magic + end-mark). Greedy hash-table compressor; overlapping-match
copy support. `encode`/`decode` aliases. 81 assertions.

**TOTP** (`lib/totp`) — **implemented**. HOTP (RFC 4226) and TOTP (RFC 6238) one-time
passwords. `hotp(key, counter)`, `totp(key, opts)`, `totp_base32(secret, opts)`,
`verify(secret, code, opts)` (time-window), `new_secret()`, `otpauth_uri()` for QR codes.
Verified against RFC 4226 Appendix D and RFC 6238 Appendix B vectors. 66 assertions.

**Base58** (`lib/base58`) — **implemented**. Base58 and Base58Check encoding (Bitcoin/IPFS
alphabet). `encode`/`decode`, `encode_check`/`decode_check` (double-SHA256 checksum).
Leading zero bytes map to leading '1' characters. 70 assertions.

**PEM** (`lib/pem`) — **implemented**. PEM format parser/writer (RFC 7468). `decode`,
`decode_all`, `encode(label, data)`, `is_pem`, `label`. Handles CRLF, blank lines,
label validation. Base64 body decode/encode. Used for TLS certs, keys, CSRs. 85 assertions.

**JWT** (`lib/jwt`) — **implemented**. JSON Web Tokens (RFC 7519). `encode(payload, secret)`
/ `decode(token, secret)` / `decode_unverified(token)`. HS256 (HMAC-SHA256) signing and
verification; timing-safe signature comparison; `exp`/`nbf` claim validation; `now()`/
`exp_in(seconds)` helpers. 59 assertions.

**AES** (`lib/crypto/aes`) — **implemented**. AES-128/192/256 block cipher, pure Lua.
ECB, CBC, CTR modes; PKCS#7 padding/unpadding; streaming CTR encryption; key caching.
Verified against NIST FIPS 197 Appendix B and AES-192/256 vectors. 45 assertions.

**Base85** (`lib/codec/base85`) — **implemented**. Three Base85 variants: RFC 1924
(alphanumeric-safe), Z85 (ZeroMQ), Ascii85/btoa (Adobe). `encode`/`decode` per variant,
streaming encoder (chunk-at-a-time with flush). Verified against published test vectors.
104 assertions.

**JSON** (`lib/json`) — **implemented**. Pure Lua JSON parser and serializer. Full
RFC 8259: all value types, Unicode escapes (`\uXXXX`), surrogate pairs, all escape
sequences. Options: `indent` (pretty-print), `sort_keys`, `allow_nan`. `encode`/`decode`
codec aliases. 281 assertions.

**TOML** (`lib/toml`) — implemented. Full TOML v1.0 parser and encoder. All value
types, dotted keys, table headers, array of tables, inline tables/arrays, all string
types with escapes, datetime types. Round-trip encode/decode. 93 assertions.

**CSV** (`lib/csv`) — implemented. RFC 4180 CSV parser and encoder: quoting, doubled-quote
escaping, embedded newlines, CRLF/LF/CR, `headers` mode (keyed tables), `coerce` (auto
number/bool), `trim`, custom separator. `decode_row`/`encode_row`, `encode_records`,
`iter`, streaming push `decoder`. Codec aliases: `decode`/`encode`. 220 assertions.

**Diff** (`lib/diff`) — implemented. Myers diff algorithm (O(ND)): `diff` (arrays),
`diff_strings` (line-level), `unified` (unified format output), `patch` (apply edits),
`lcs` (longest common subsequence). 135 assertions.

**Bundle** (`lib/bundle`) — implemented. Lua module bundler: resolve static `require()`
calls, inline transitive dependencies, emit self-contained single file. Circular
dependency handling, shebang injection, `analyze` for dependency listing. 99 assertions.

**Graph** (`lib/graph`) — implemented. Directed/undirected graphs with adjacency list.
Node/edge API with optional data; directed in/out neighbors; auto-creates nodes on `add_edge`.
Algorithms: BFS, DFS, topological sort (Kahn's), Dijkstra shortest path (O(V²)), cycle detection,
connected components, Kruskal MST (union-find), Tarjan's SCC, `transpose`. 179 assertions.

**Cache** (`lib/cache`) — implemented. LRU cache with optional TTL. Doubly-linked list
for O(1) promote/evict, injectable clock for testing, eviction callbacks, resize,
bulk get/set. 102 assertions.

**LRU** (`lib/lru`) — **implemented**. LRU cache + LFU + 2Q variants. All O(1) via
doubly-linked lists. TTL with injectable clock, per-entry override, `on_evict` callback.
`get_or_set`, `mget`/`mset`, `iter`/`keys`/`values` (MRU order), hit_rate/stats.
LFU: O'Neil algorithm, frequency introspection. 2Q: "in" FIFO + "out" LRU + ghost set.
176 assertions.

**Validate** (`lib/validate`) — implemented. Schema validation for Lua tables. Composable
validators: string/number/integer/boolean/table/func/any/nil/literal, optional, one_of,
all_of, array, map, record, custom. Dotted error paths. 193 assertions.

**JSON Schema** (`lib/json_schema`) — **implemented**. JSON Schema draft-7 validator.
`compile(schema)` → reusable validator; `validate(value, schema)` one-shot. All keywords:
type/enum/const, string (minLength/maxLength/pattern/format), number (min/max/exclusive/
multipleOf), array (items/additionalItems/uniqueItems/contains), object (properties/
required/additionalProperties/patternProperties/dependencies), allOf/anyOf/oneOf/not,
if/then/else, `$ref`+definitions, format (email/uri/date/ipv4/ipv6), OpenAPI `nullable`.
Error objects with RFC 6901 paths. 212 assertions.

**Stream** (`lib/stream`) — implemented. Lazy iterator combinators: from_array, range,
generate, iterate. Transforms: map, filter, take, drop, flat_map, zip, chain, enumerate,
unique, dedup, scan, chunks, intersperse. Terminals: to_array, reduce, count, sum, min,
max, find, any, all, join, partition, group_by. 120 assertions.

**Color** (`lib/color`) — implemented. Color spaces: RGB, HSL, HSV, hex, named CSS
colors. Constructors: `rgb`/`rgba`/`rgbf`/`hex`/`hsl`/`hsv`. Conversions, manipulation
(lighten, darken, saturate, desaturate, rotate, complement, invert, mix). WCAG luminance
and contrast ratio, `is_light`/`is_dark`, `gradient(colors, t)`, 20 named colors.
172 assertions.

**Cron** (`lib/cron`) — implemented. Cron expression parser and scheduler. 5-field
expressions, ranges, steps, lists, named months/days, shorthands (@hourly, @daily, etc).
matches(), next/prev occurrence, next_n(), describe(). 185 assertions.

**FSM** (`lib/fsm`) — implemented. Finite state machine: declarative config with states,
transitions, guards, actions, on_enter/on_exit callbacks. Wildcard and multi-source
transitions, history tracking, introspection. 125 assertions.

**State** (`lib/state`) — **implemented**. Finite state machine with richer runtime model:
`add_state`, `add_transition` with guard callbacks, `on_enter`/`on_exit` per state,
`on_transition` listeners, `trigger(event, payload)`, `can(event)`, `state()`/`history()`.
114 assertions.

**VM** (`lib/vm`) — **implemented**. Stack-based bytecode virtual machine. 30 opcodes:
stack (PUSH/POP/DUP/SWAP/ROT), arithmetic, comparison, logic, LOAD/STORE (named env),
control flow (JMP/JMP_IF/JMP_IFNOT/CALL/RET), HALT/NOP/PRINT. Label resolution at
program build time. Step mode for debugging. 89 assertions.

**Grammar** (`lib/grammar`) — **implemented**. PEG parser combinator library with packrat
memoization. Primitives: `lit`, `any`, `eof`, `range`, `set`, `not_set`. Combinators:
`seq`, `alt`, `opt`, `star`, `plus`, `times`, `between`, `not_`, `and_`, `capture`.
`G.grammar({rules})` for recursive grammars with `G.ref()` forward references.
178 assertions.

**Bencode** (`lib/bencode`) — **implemented**. BitTorrent bencode (BEP 3) encoder/decoder.
Integers, strings, lists, dicts (sorted keys). Strict validation: no leading zeros,
no negative zero, sorted dict keys, non-string dict key error. `decode_all` for streams.
Codec aliases. 152 assertions.

**K-d Tree** (`lib/kdtree`) — **implemented**. Spatial index for k-dimensional points.
Median-split build (O(n log n)). Nearest neighbor (NN with pruning), knn (max-heap),
range (radius), box (AABB). Dynamic `insert` + `rebuild`. Arbitrary dimensions.
Points or `{point, data}` pairs. 164 assertions.

**Automata** (`lib/automata`) — **implemented**. NFA/DFA construction and simulation.
NFA with epsilon transitions, DFA with single-state stepping. Algorithms: subset
construction (NFA→DFA), Hopcroft minimization, complement, product construction
(intersection/union). Thompson's construction from regex (`.`, `|`, `*`, `+`, `?`,
`()`, literals). `to_dot()` for GraphViz output. 184 assertions.

**Heap** (`lib/heap`) — implemented. Binary heap (priority queue): min/max/custom
comparator, O(n) heapify, merge, heap sort, keyed mode with push_or_update/remove,
drain iterator. 615 assertions.

**Set** (`lib/set`) — implemented. Mathematical set: union, intersection, difference,
symmetric difference, subset/superset/disjoint tests, map/filter/reduce. O(1)
membership. 108 assertions.

**Skip List** (`lib/skiplist`) — **implemented**. Probabilistic ordered data structure,
O(log n) insert/delete/search. Augmented with order statistics: `rank(key)`, `at_rank(r)`.
Forward and reverse iterators, `min`/`max`, `range(lo, hi)`, custom comparator.
127 assertions.

**Geo** (`lib/geo`) — **implemented**. Geospatial utilities: Haversine distance, Vincenty
ellipsoidal distance (WGS-84), bearing (initial/final), destination point, midpoint.
Geohash encode/decode/neighbors (all 8 directions). Point-in-polygon (ray casting),
bounding box. `deg_to_rad`/`rad_to_deg`. 96 assertions.

**Ring Buffer** (`lib/ringbuf`) — implemented. Fixed-size circular buffer: O(1)
push/pop from both ends, overflow wrapping, sliding window, 1-based indexing,
drain, iterator. Byte-oriented variant (`ringbuf.bytes`) for streaming I/O:
`write`/`read`/`peek`/`discard`. 143 assertions.

**Humanize** (`lib/humanize`) — **implemented**. Human-readable formatting: `bytes` (B/KB/MB/…
binary and SI), `parse_bytes`, `duration` (w/d/h/m/s/ms, compact/long/max_parts options),
`parse_duration`, `ordinal` (1st/2nd/3rd/nth, teen exceptions), `number` (thousands separator),
`percentage`, `relative` (past/future fuzzy), `plural` (irregular forms), `list` (Oxford comma). 85 assertions.

**Path** (`lib/path`) — **implemented**. Cross-platform filesystem path manipulation (pure
string ops, no I/O): `join`, `split`, `basename`, `dirname`, `splitext`, `ext`, `is_absolute`,
`normalize` (resolves `..`/`.`), `relative`, `parts`, `commonpath`, `expanduser`. Platform
sep/pathsep from `package.config`. 78 assertions.

**CRC32** (`lib/hash/crc32`) — **implemented**. CRC32 checksum (reflected polynomial 0xEDB88320,
ISO 3309 / zlib / gzip / PNG). Pre-computed 256-entry lookup table. One-shot `crc32(data, seed?)`
and `crc32_hex`, streaming `new(seed?)` with `update`/`digest`/`hex`/`reset`. Seeded chaining:
`crc32(b, crc32(a)) == crc32(a..b)`. 39 assertions.

**Table Extensions** (`lib/table_ext`) — **implemented**. 50+ table utilities: `map`, `filter`,
`reduce`, `flat_map`, `flatten`, `find`, `any`/`all`/`none`, `group_by`, `unique`, `zip`/`unzip`,
`chunk`, `sort_by`, `keys`/`values`/`entries`/`from_entries`, `merge`/`deep_merge`, `pick`/`omit`,
`invert`, `deep_copy`, `deep_equal`, `is_array`, `range`, `shuffle`, `sample`. 194 assertions.

**String Extensions** (`lib/string_ext`) — **implemented**. 40+ string utilities: `starts_with`,
`ends_with`, `contains`, `count`, `trim`, `pad_left`/`pad_right`/`center`, `truncate`, `wrap`,
`snake_case`/`camel_case`/`pascal_case`/`kebab_case`, `split`/`split_n`/`lines`/`chars`, 
`replace`/`replace_all`, `escape_pattern`, `escape_html`/`unescape_html`, `escape_uri`/`unescape_uri`.
147 assertions.

**Math Extensions** (`lib/math_ext`) — **implemented**. `clamp`, `lerp`, `remap`, `smoothstep`,
`sign`, `round`/`round_to`/`wrap`/`snap`, `approx_eq`. Number theory: `gcd`, `lcm`, `is_prime`,
`primes` (sieve), `factorize`, `is_power_of_two`. Statistics: `mean`, `median`, `mode`, `variance`,
`stddev`, `percentile`, `histogram`. Easing: quad/cubic/sine in/out/in-out. Geometry: `deg_to_rad`,
`polar_to_cart`, `distance`, `dot2d`/`cross2d`. 151 assertions.

**Trie** (`lib/trie`) — implemented. Prefix tree: insert/get/has/remove, has_prefix,
find_prefix, count_prefix, longest_prefix (routing), autocomplete/completions with limit,
sorted iteration via `iter`/`all`. `compressed` option (radix-trie interface). 150 assertions.

**Bench** (`lib/bench`) — **implemented**. Micro-benchmarking framework. `bench.run(fn, opts)` with
warmup, auto-batching, injectable clock. Result: `mean_ns`/`median_ns`/`min_ns`/`max_ns`/`stddev_ns`/
`ops_per_sec`, `:format()`. `bench.suite` for named comparisons with speedup ratios.
`bench.throughput` for bytes/sec. `bench.stats`, `bench.format_ns`, `bench.format_ops`.
`bench.calibrate()` measures loop overhead. 89 assertions.

**Bloom Filter** (`lib/bloom`) — **implemented**. Probabilistic set membership. `bloom.new(n, p)`
(capacity + false-positive rate) or `bloom.new_raw(m, k)`. FNV-1a + polynomial double hashing
(Kirsch-Mitzenmacher). `add`/`has`/`clear`/`count`/`union`/`intersection`/`to_string`/`from_string`.
Counting filter (`counting_new`) with `remove` and `count_of`. 468 assertions.

**Glob** (`lib/glob`) — implemented. Glob pattern matching: `*` (any non-/), `**`
(recursive), `?` (single char), `[abc]`/`[a-z]`/`[!abc]` (char classes), `{a,b}`
(brace alternation). compile/match/filter/to_pattern/is_glob. 151 assertions.

**Matrix** (`lib/matrix`) — implemented. 2D matrix math: flat row-major storage,
arithmetic (add/sub/mul/scale), transpose, trace, determinant, inverse, solve Ax=b
via Gaussian elimination with partial pivoting, map/zip, reshape, LU decomposition,
Frobenius norm, slice, `__add`/`__sub`/`__mul`/`__eq` metamethods. 281 assertions.

**Bits** (`lib/bits`) — implemented. Bitset (32-bit word array): set/clear/toggle/get,
popcount, any/none/all, and/or/xor/not set operations. Bloom filter: optimal sizing,
double-hashing FNV-1a, add/test/union, FP rate estimation. Uses LuaJIT `bit` when
available. 157 assertions.

**Promise** (`lib/promise`) — implemented. Promises/A+ for async composition:
resolve/reject, and_then/catch/finally chaining, nested promise unwrapping.
Combinators: all, race, all_settled, any. Synchronous execution model. 92 assertions.

**Interval** (`lib/interval`) — implemented. Interval arithmetic with half-open endpoint
support (`lo_closed`/`hi_closed`). Contains, overlaps, intersection, union, difference,
shift/scale/clamp, before/after. `M.range(lo, hi, step)` integer iteration. `M.set(intervals)`
with normalize/union/intersection. Collection ops: merge, gaps, span. Interval tree for
efficient point/overlap queries. 191 assertions.

**Deque** (`lib/deque`) — implemented. Growable double-ended queue: O(1) amortized
push/pop both ends, 1-based get/set, rotate, forward/reverse iteration, contains.
1160 assertions.

**Rope** (`lib/rope`) — **implemented**. Persistent rope data structure for efficient
large-string editing. Leaf + concat nodes, auto-rebalance (depth threshold), O(log n)
`char_at`/`sub`/`insert`/`delete`/`split`/`concat`. `..` operator and `__eq` metamethods.
DFS `iter()` over leaves. 77 assertions.

**Bitset** (`lib/bitset`) — **implemented**. Dense bitset backed by 32-bit integer words.
`set`/`get`/`clear`/`flip`, popcount, `any`/`none`/`all`, `band`/`bor`/`bxor`/`bnot`/
`difference`, `iter()` over set positions, `to_array`/`to_string`/`to_hex`/`from_hex`.
Dynamic bitset (auto-grows). Bounds check with `(nil, errmsg)` on out-of-range. 223 assertions.

**Signals** (`lib/signals`) — **implemented**. Fine-grained auto-tracking reactive signals
(SolidJS/Preact Signals style). `create`/`computed`/`effect`/`batch`/`memo`/`untrack`/`on`.
Two-phase propagation (glitch-free). Lazy computed with dirty tracking. `stop()` cleanup.
`sig:peek()` method. 96 assertions. (Distinct from `lib/reactive` which uses explicit dep arrays.)

**BigInt** (`lib/bigint`) — implemented. Arbitrary precision integers: base 10^7
chunks, add/sub/mul/div/mod/pow, GCD/LCM, factorial, hex conversion. Full metamethods
(+, -, *, /, %, ^, ==, <). 172 assertions.

**BigNum** (`lib/bignum`) — **implemented**. Arbitrary precision decimal floating-point
(`{sign, digits, exp}` representation). `new`/`parse`/`from_number`; arithmetic (`+`,`-`,`*`,`/`,
`%`); rounding (`round`, `floor`, `ceil`, `trunc`); `sqrt` (Newton-Raphson), `pow`, `pi`
(Machin's formula); `set_precision`/`get_precision` (default 50 digits). 157 assertions.

**Router** (`lib/router`) — implemented. Radix tree URL router: static segments,
`:param` captures, `*wildcard` catch-all, inline params, method dispatch, route
groups with prefix nesting. Static > param > wildcard priority. 158 assertions.

**Retry** (`lib/retry`) — implemented. Retry with configurable backoff (none, linear,
exponential, fibonacci, custom), jitter, retry_on predicate, on_retry callback.
Reusable policies. Circuit breaker (closed/open/half_open). 177 assertions.

**Base64** (`lib/base64`) — implemented. RFC 4648 Base64 encode/decode: standard and
URL-safe alphabets, padding control, whitespace stripping. Codec aliases per
conventions. 145 assertions.

**Event** (`lib/event`) — implemented. Event emitter / pub-sub: on/once/off, wildcard
patterns (`user.*`, `*`), priority ordering, stop propagation, listener IDs,
`event.mixin()` for adding to any table. 107 assertions.

**INI** (`lib/ini`) — implemented. INI file parser/encoder: `[section]` headers,
`key=value` pairs, `;`/`#` comments, quoted values, backslash continuation,
configurable delimiter. Codec aliases. 90 assertions.

**Pool** (`lib/pool`) — implemented. Object pool: create/destroy/validate/reset
callbacks, acquire/release, `with()` convenience, stats tracking, drain. Specialized
buffer pool. 117 assertions.

**Schema** (`lib/schema`) — implemented. Database DDL migration DSL: create/alter/drop
table, column types (integer/text/real/blob/boolean/timestamp), constraints (PK, NOT NULL,
UNIQUE, DEFAULT, FK, CHECK), indexes. Generates portable SQL strings. 137 assertions.

**MIME** (`lib/mime`) — implemented. MIME type database: 120+ extension-to-type mappings,
reverse lookup, charset detection, text/binary classification, content_type header
generation. Compound extensions (tar.gz). 102 assertions.

**URL** (`lib/url`) — implemented. RFC 3986 URL parser/builder: parse into components,
build from parts, query string encode/decode, percent-encoding, reference resolution,
normalization. IPv6, protocol-relative, data URIs. 152 assertions.

**Net** (`lib/net`) — **implemented**. Network address data structures (no I/O). IPv4:
parse, to_number, is_private/loopback/multicast/broadcast/link_local. IPv6: parse with
`::` compression, RFC-compliant to_string. CIDR: network/broadcast/netmask, contains,
iter_hosts, supernet. URL parse/build (complements lib/url), url_encode/decode,
query_encode/decode. MAC: parse colon/dash, is_broadcast/multicast, OUI. 163 assertions.

**Template** (`lib/template`) — implemented. String template engine: `{{ expr }}` (escaped),
`{{{ expr }}}` (raw), `{% code %}` (Lua), `{# comment #}`. Compiles to Lua functions.
Built-in filters (upper, lower, trim, length, default). 100 assertions.

**Rate Limit** (`lib/ratelimit`) — implemented. Rate limiting algorithms: token bucket,
sliding window, fixed window, leaky bucket. Per-key multi-tenant support. Injectable
clock for testing. 367 assertions.

**i18n** (`lib/i18n`) — implemented. Internationalization: translation lookup with
`{{var}}` interpolation, dot-notation nested keys, pluralization with built-in rules
for en/es/fr/de/ja/zh/ar, locale switching, fallback locale. 85 assertions.

**Codec** (`lib/codec`) — implemented. Codec registry and composition utilities.
`register`/`get`/`list`; `chain(...)` (encode left→right, decode right→left).
`lib/codec/hex`: encode/decode, case-insensitive decode, `upper` flag, `encode_chunks`,
hex dump (`dump`), streaming `encoder`. Aliases: `string_to_hex`/`hex_to_string`.
74 assertions (codec_test). Plus older composition utils (rot13, reverse, xor, conditional,
map, identity).

**Observable** (`lib/observable`) — implemented. Reactive push-based streams: create, of,
from_array. Operators: map, filter, take, skip, distinct, reduce, scan, flat_map, tap,
concat, merge, take_while, skip_while, buffer, to_array. Combinators: merge, concat,
zip, combine_latest. Subjects and replay subjects. 510 assertions.

**Bencode** (`lib/bencode`) — **implemented**. Bencode encoder/decoder (BitTorrent
encoding format): integers, byte strings, lists, dictionaries with sorted keys.
Codec aliases: `encode`/`decode`, `table_to_string`/`string_to_table`. 90 assertions.

**Either** (`lib/either`) — **implemented**. `Either<L,R>` (Left/Right) and `Maybe<T>` (Some/None)
algebraic data types. Full functor/monad interface: `map`, `map_left`, `and_then`, `or_else`, `fold`,
`unwrap`/`unwrap_or`/`unwrap_or_else`. Conversions: `to_pair`/`from_pair`, `to_maybe`/`to_right`.
`None` is a callable singleton. 95 assertions.

**Circuit Breaker** (`lib/circuit_breaker`) — **implemented**. Circuit breaker pattern for fault
tolerance. States: closed/open/half_open. Configurable `failure_threshold`, `success_threshold`,
`timeout`, `clock` (injectable), `is_failure` predicate, `on_state_change` callback. `call(fn)` via
pcall. `trip`/`reset`. `wrap(fn)` for permanent wrapping. 85 assertions.

**Config** (`lib/config`) — **implemented**. Layered configuration management. Chainable:
`:defaults(t)`, `:layer(t)`, `:env(prefix)` (APP_DB_HOST → db.host), `:args(t)`. Priority:
args > env > layers > defaults. Typed accessors: `int`/`float`/`bool`/`string`/`list`. `:ns(prefix)`
namespace view. `:to_table()` snapshot. `:validate({required, types})`. Injectable `env_reader`. 76 assertions.

**PubSub** (`lib/pubsub`) — **implemented**. In-process pub/sub event bus with topic routing.
Wildcard patterns: `*` (one segment), `**`/`#` (any depth), `?` (single char). `subscribe`/`once`/
`unsubscribe_all`/`use` (middleware). `publish`/`publish_async`+`flush`. `filter` predicate per
subscription. `subscriber_count`/`topics`/`clear`. 67 assertions.

**Pipeline** (`lib/pipeline`) — **implemented**. Lazy data pipeline: `from`/`range`/`generate`/
`repeat_val`/`concat_sources`/`empty` sources. Transforms (all lazy): `map`, `filter`, `flat_map`,
`take`/`drop`/`take_while`/`drop_while`, `enumerate`, `zip`, `batch`, `flatten`, `unique`, `tap`,
`scan`, `window`. Sinks: `collect`, `reduce`, `each`, `count`, `first`, `last`, `sum`, `min`/`max`,
`any`/`all`, `find`, `to_map`, `group_by`, `join`, `drain`. 108 assertions.

**Schema Gen** (`lib/schema_gen`) — **implemented**. JSON Schema inference, generation, validation,
and DSL. `infer(data)` produces schema from sample. `infer_many(samples)` merges (required keys = present
in all). `generate(schema)` produces deterministic examples; `generate_random` for random. `validate(schema, data)`
checks type/required/properties/enum/min/max. DSL: `M.string/number/object/array/enum/one_of/nullable/ref`.
138 assertions.

**Patch** (`lib/patch`) — **implemented**. JSON Patch (RFC 6902) and JSON Pointer (RFC 6901).
Pointer: `get`/`set`/`remove`, `~0`/`~1` escaping, 0-based array indexing. Patch ops: `add`,
`remove`, `replace`, `move`, `copy`, `test`. `diff(a, b)` generates minimal patch. Round-trip:
`apply(diff(a,b), a) ≡ b`. 109 assertions.

**Semaphore** (`lib/semaphore`) — **implemented**. Coroutine concurrency primitives: counting
`semaphore` (acquire/release/try_acquire), `mutex` (lock/unlock/with RAII), `cond` (wait/signal/
broadcast), `waitgroup` (add/done/wait), `once`. Built-in `go`/`run` scheduler (no external deps).
52 assertions.

**Wire** (`lib/wire`) — **implemented**. Binary protocol framing: Writer (builds binary strings) and
Reader (cursor into binary data). Types: uint8/16/32, int8/16/32, float32/64 (LE+BE), unsigned
LEB128 varint, signed LEB128 (zigzag), raw bytes, length-prefixed strings (u8/u16/u32/varint prefix).
`M.frame`/`M.unframe` for length-prefixed messages. Streaming `unframer` for TCP chunks. 141 assertions.

**Struct** (`lib/struct`) — **implemented**. C-style struct pack/unpack (Python `struct`-compatible
format strings). Byte order: `<`/`>`/`!`/`=`. Format chars: `b B h H i I l L q Q f d s Ns c ? x`.
Repeat counts (`4B`). `pack`/`unpack`/`calcsize`/`compile`. FFI unions for float/double/int64. 97 assertions.

**S-Expressions** (`lib/sexp`) — **implemented**. Lisp-style S-expression parser and serializer.
`M.sym(name)`/`M.is_sym(v)` for symbols. `decode`/`encode`, `decode_all`/`encode_all`. Comment
stripping, `'x` quote shorthand → `(quote x)`, `#t`/`#f` booleans. Round-trip correct. 137 assertions.

**Statemachine** (`lib/statemachine`) — **implemented**. Hierarchical statechart library (Harel/XState
style). Compound states with sub-states, `initial`, entry/exit actions, guards, event transitions,
context object, relative target resolution. Immutable `transition(state, event)` and mutable `service`.
`matches("active.working")` pattern. 74 assertions.

**MessagePack** (`lib/msgpack`) — **implemented**. MessagePack binary serialization:
nil, boolean, integer (fixint through uint32/int32), float64, string, binary, array,
map. Pure Lua, big-endian byte packing. `M.bin(s)` for binary-typed strings. Codec
aliases. 524 assertions.

**Result** (`lib/result`) — **implemented**. Result type (Ok/Err) like Rust's
`Result<T, E>`. Monadic chaining: `map`, `and_then`, `or_else`, `map_err`, `inspect`.
`from`/`to_pair` for Lua convention interop, `try` for pcall wrapping, `all`/`any`
combinators. 124 assertions.

**SemVer** (`lib/semver`) — **implemented**. Semantic Versioning 2.0.0 parser,
comparator, and constraint solver. Comparison metamethods, `inc_major`/`minor`/`patch`,
constraint parsing (`>=`, `<`, `^`, `~`, `*`, `x`/`X` wildcards, compound AND). `sort`,
`max`, `min`, `is_valid`. 234 assertions. (Separate from `lib/pkg/semver.lua`.)

**Base32** (`lib/base32`) — **implemented**. Base32 encoding and decoding (RFC 4648): standard
alphabet (A-Z2-7), extended hex alphabet (0-9A-V, order-preserving), and Crockford variant
(human-friendly, case-insensitive, maps I/L→1 and O→0, no padding). `encode`/`decode` plus
`encode_hex`/`encode_crockford` variants. 62 assertions.

**CBOR** (`lib/cbor`) — **implemented**. CBOR (RFC 7049) binary encoder/decoder. All major
types: unsigned/negative integers, byte strings, text strings, arrays, maps, tagged values,
floats (16/32/64-bit decode, 64-bit encode), true/false/null. Indefinite-length arrays, maps,
and strings. `M.bytes(s)` wrapper for byte strings. Pure Lua + FFI float64 tier. 171 assertions.

**Chan** (`lib/chan`) — **implemented**. Go-style coroutine channels. Buffered and unbuffered
(rendezvous), `send`/`recv`/`close`, non-blocking `try_send`/`try_recv`, `M.select(cases)` for
multiplexing, `M.go(fn)` coroutine spawn, `M.run(fn)` round-robin scheduler for driving
coroutines to completion in tests. 65 assertions.

**Proto** (`lib/proto`) — **implemented**. Protocol Buffers 3 wire format encoder/decoder.
Schema-as-Lua-tables (no .proto parser). All wire types: varint (int32/int64/uint/sint/bool/enum),
64-bit (double/fixed64), LEN (string/bytes/embedded message/packed repeated), 32-bit (float/fixed32).
Zigzag encoding for sint32/sint64. Repeated fields. 75 assertions.

**NDJSON** (`lib/ndjson`) — **implemented**. Newline-Delimited JSON (JSON Lines) encoder and
decoder. `encode(array)` / `decode(str)` bulk, `encode_line(v)` / `decode_line(line)` per-line,
`iter(str)` lazy iterator, stateful `encoder()` with `:write`/`:lines`. Skips blank lines and
`#`-prefixed comment lines. 81 assertions.

**Markdown** (`lib/markdown`) — **implemented**. Markdown to HTML and plain text renderer.
Block elements: ATX/setext headings, paragraphs, blockquotes, unordered/ordered lists, fenced
and indented code blocks, thematic breaks. Inline: bold, italic, bold+italic, inline code,
links, images, auto-links, HTML escaping, hard line breaks. `to_html`/`to_text`. 86 assertions.

**Multipart** (`lib/multipart`) — **implemented**. MIME multipart encoder/decoder (RFC 2046).
Builder API: `new(boundary)`, `:field`, `:file`, `:part`, `:body`, `:content_type`. One-shot
`encode(parts)`. `decode(body, boundary)` parses headers, name/filename, body per part. 
`parse_boundary(Content-Type header)`. Handles `\r\n` and `\n` line endings. 85 assertions.

**INI** (`lib/ini`) — **implemented**. INI file parser and serializer. Sections, global keys,
`;`/`#` comments, inline comments, quoted values, blank lines. Options: `coerce` (numbers/bools),
`lowercase`, `sort`. `get(t, section, key)` helper. `encode`/`decode` with `string_to_table`/
`table_to_string` aliases. 130 assertions.

**MD5** (`lib/hash/md5`) — **implemented**. Pure Lua MD5 digest (RFC 1321). One-shot
`md5(data)` returns 16-byte binary digest; `md5_hex(data)` returns 32-char hex string.
Streaming `new_md5()` with `update`/`digest`/`reset`. 62 assertions.

**xxHash** (`lib/hash/xxhash`) — **implemented**. xxHash32 (pure Lua) and xxHash64
(LuaJIT FFI uint64). One-shot `xxh32`/`xxh64` plus streaming `new32`/`new64` with
`update`/`digest`/`reset`. Official spec test vectors verified. 43 assertions.

**YAML** (`lib/format/yaml`) — **implemented**. YAML 1.2 decoder and encoder. Block
and flow styles, nested mappings/sequences, anchors/aliases, multi-document streams,
literal/folded block scalars, scalar type resolution. `decode`/`encode`/`decode_all`.
99 assertions.

**IR** (`lib/ir`) — **implemented**. In-memory intermediate representation graph.
Typed nodes with attributes, directed edges with labels, CFG/SSA helpers, DFS/BFS
traversal, dominator trees, liveness analysis. 163 assertions.

**Cursor** (`lib/cursor`) — **implemented**. Cursor-based and offset pagination helpers.
`encode_cursor`/`decode_cursor` (opaque base64-encoded JSON tokens), `paginate(items, opts)`
returns `{items, next_cursor, prev_cursor, has_next, has_prev}`. `page_by_offset` for
offset/limit. Works with any sortable key type. 118 assertions.

**Money** (`lib/money`) — **implemented**. Monetary value arithmetic using integer minor
units to avoid float precision issues. `new(amount, currency, decimals)`, arithmetic
(`add`, `sub`, `mul`, `div`), comparison, rounding modes (floor, ceil, round, banker's),
`allocate(ratios)` for split-without-loss, `format` with currency symbol/locale. 107 assertions.

**Expr** (`lib/expr`) — **implemented**. Safe arithmetic and boolean expression evaluator.
Recursive-descent parser: operators (`+`, `-`, `*`, `/`, `%`, `^`), comparisons, logical
(`and`/`or`/`not`), ternary (`? :`), string concat (`..`), variables from an environment
table. No `load`/`dostring` — fully sandboxed. `eval(expr, env)` and `parse(expr)` for
AST access. 92 assertions.

**Debounce** (`lib/debounce`) — **implemented**. Debounce, throttle, once, and batch
utilities with injectable clock for deterministic testing. `new(fn, delay_ms)` fires after
quiet period; `throttle(fn, interval_ms)` rate-limits; `once(fn)` single-fire with `reset`;
`batch(fn, delay_ms)` collects `push(...)` calls and fires with full batch. All have
`flush`/`cancel`/`pending`/`check(now)`. 74 assertions.

### Missing — binary serialization

**`lib/protocol/capnp`** — Cap'n Proto zero-copy binary serialization. LuaJIT FFI can
read Cap'n Proto messages with near-zero allocation by casting directly into the wire
buffer (fixed-width fields + typed pointers, no varint parsing). Wire format reader +
writer first; `.capnp` schema parser deferred (hand-write schemas as Lua tables
initially). RPC layer (`lib/capnprpc`) separate. Genuine capability gap over JSON/CBOR
for high-throughput IPC and inter-process data sharing.

### Missing — protocol bindings

Protocol libraries that expose a typed API, not just a raw wire format:

**`lib/jsonrpc`** — request/response dispatch layer over stdio or TCP. The substrate
for LSP, MCP, and any other JSON-RPC protocol. Design: transport abstraction (stdio,
TCP, HTTP), method registry, typed handler registration. **Done** — dispatcher,
stdio transport (Content-Length framing), table transport (testing), batch requests,
error codes, and test suite implemented.

**`lib/lsp`** — implemented. LSP method bindings on top of `lib/jsonrpc`. Server builder
with `on_*` registration for all core LSP methods, auto-capability detection from
registered handlers, lifecycle management (initialize/shutdown/exit), server-to-client
notifications (publishDiagnostics, logMessage, showMessage). 60 assertions.

**`lib/mcp`** — implemented. MCP server on top of `lib/jsonrpc`. Tool/resource/prompt
registration, URI template resources, capability negotiation, logging with level filtering,
argument completions. Protocol version 2025-11-25. 44 assertions.
(Note: `lib/mud_cp/` is the existing MUD Client Protocol implementation — unrelated.)

**`lib/openapi`** — implemented. OpenAPI 3.x spec parser with `$ref` resolution,
request/response validation (JSON Schema subset), and `lib/web` router integration
via `spec:mount(app, handlers)`. 111 assertions.

### Missing — frontend vertical

**`lib/reactive_optics`** — reactive optics. Signals focused through optics (lenses, prisms,
traversals) as the reactivity primitive. `signal:focus(lens)` produces a derived signal
that reads and writes structurally through the lens; reactivity flows through optic
composition rather than imperative synchronization functions. Lawful by construction —
lens laws (get-set, set-get, set-set) guarantee derived state is always consistent.

Built on `lib/fp/` (lenses, prisms, traversals already exist there). The novel piece is
the marriage: optics as the *structure* of derived state, signals as the *propagation*
mechanism. Prior art: `~/git/rhizone/rainbow/` (TypeScript prototype).

Paired with `lib/lua2ts`: write reactive UI logic in Lua, emit typed TypeScript, run in
the browser. Same optic algebra server-side and client-side, no impedance mismatch.

### World state

**`lib/ecs`** — SQLite-backed entity-component store. Entities have integer IDs;
components are named typed values (any Lua value, JSON-encoded) attached to entities.
API: `create` / `destroy` / `set` / `get` / `remove` / `query` / `components`. Query
supports optional predicate filtering. Schema uses `ON DELETE CASCADE` so destroying an
entity removes all its components atomically. 30 assertions. Status: **done**.

Possible future extension: spatial indexing, graph-style edges, or a document-store
variant. The current design is intentionally minimal — derive shape from real consumers
(Lumen, RP) before adding complexity.

### Missing — application verticals

Higher-level libraries that assemble primitives into complete vertical solutions.
A new user building in a given domain shouldn't need to compose primitives themselves.
The vertical is complete — not 90%, 100%. Partial verticals create the same pressure
to abandon as partial stdlib implementations.

**`lib/web`** — implemented. Web application framework: middleware pipeline,
pattern-based routing with `:param` capture, route groups, query string parsing.
Built-in middleware: logger, CORS, static file serving, JSON body parsing, cookies,
CSRF protection. Response helpers: json/html/redirect. Fully testable via
`app:handle(req)` without a network. 56 assertions.

**`lib/db`** — implemented. Database vertical on `lib/sqlite`: version-tracked
migrations (transactional), chainable query builder (select/insert/update/delete),
convenience helpers (query returning named row tables, query_one, transaction).
60 assertions.

**`lib/auth`** — implemented. Authentication primitives: JWT (HS256) encode/decode with
exp/nbf validation, PBKDF2-SHA256 password hashing (PHC-format), random token generation,
HMAC-SHA256, timing-safe comparison. 44 assertions. OAuth 2.0/OIDC deferred.

**`lib/email`** — implemented. Email composition (RFC 5322 MIME: text/html/multipart,
attachments, inline images, quoted-printable, base64, RFC 2047 encoded subjects) +
SMTP client (EHLO, STARTTLS, AUTH LOGIN/PLAIN, send with dot-stuffing) with injectable
transport. Mock transport for testing. 71 assertions.

**`lib/queue`** — implemented. SQLite-backed task queue (original): push/pop/ack/fail with
exponential backoff, priority ordering, delayed jobs, recurring schedules, dead-letter
queue. 69 assertions. Also: in-memory priority queue (binary min/max-heap), FIFO queue
(growable ring buffer with push_front/pop_back), fixed-capacity ring buffer.
`heapify`/`heapsort`. 209 assertions (queue_test.lua).

**`lib/search`** — implemented. SQLite FTS5 full-text search + brute-force vector
cosine similarity (via `lib/vec`) + hybrid search with configurable weights.
Collections with typed fields, metadata, document CRUD. 65 assertions.

**`lib/realtime`** — implemented. In-process pub/sub hub with wildcard patterns,
presence tracking with join/leave/update hooks, event store with stream aggregation.
83 assertions. Network integration (WebSocket bridge) deferred.

**`lib/tui`** — terminal UI. Layouts, widgets, keyboard input, color/style. Needed
for `cr` (the package manager CLI) and any interactive CLI tool. Builds on
`lib/cli` (arg parsing) and raw terminal FFI.

**`lib/ansi`** — low-level terminal: escape codes, colors, cursor movement, terminal
queries (size, capabilities). Pure Lua, no deps. The primitive everything TUI builds on.

**`lib/tui`** ✓ — widget layer: layouts, boxes, text, input, scrolling, borders. Builds
on `lib/ansi`. Imperative API — draw what you want, when you want.

**`lib/tui/reactive`** *(opt-in)* — reactive binding for `lib/tui`. Wire
`lib/reactive_optics` signals to widget state; only affected widgets redraw on change.
Same model as the browser frontend (`lib/reactive_optics` + `lib/lua2ts`), different
render target. The terminal is just another output surface.

**`lib/notify`** — **implemented**. Notification dispatch: channels (email/webhook/console),
router (rule-based routing), batch aggregation, rate limiting, retry with backoff,
template rendering. 78 assertions.

**`lib/ml`** *(data/ML vertical)* — classical ML and inference, not training. Tiered
as everywhere else: pure Lua reference implementations (hackable, readable, the thing
you study to understand the algorithm) + FFI bindings to real libraries as the fast tier.

- `lib/vec` — **implemented**. Dense vector math with FFI and pure Lua tiers:
  new/zeros/ones/random/linspace, add/sub/mul/div/scale/neg, dot/norm/cosine/distance,
  sum/mean/min/max/argmin/argmax, normalize. 192 assertions.
- `lib/tfidf` — **implemented**. TF-IDF text scoring, corpus search ranking, keyword
  extraction, cosine similarity. Tokenizer with stopword filtering. 61 assertions.
- `lib/knn` — **implemented**. k-nearest neighbors: brute-force top-k, classify (majority
  vote + weighted), regress, euclidean/cosine/manhattan + custom distance. 55 assertions.
- `lib/xgboost` — **implemented**. Gradient boosted trees: MSE/logistic objectives,
  max_depth/min_samples/learning_rate/subsample, feature importance, serialization.
  Pure Lua reference implementation. 95 assertions.
- `lib/onnx` — ONNX runtime FFI bindings. Run any exported model from PyTorch, sklearn,
  etc. FFI-only (no pure Lua equivalent — the model format is the spec).
- `lib/embed` — **implemented**. In-memory vector index: add/remove/search with cosine,
  euclidean, or dot-product metrics. Metadata filtering, batch add, serialize/deserialize.
  Brute-force kNN on `lib/vec`. 112 assertions.

**`lib/logic`** *(logic programming)* — relational/logic programming substrate.

- `lib/ukanren` — **implemented**. microKanren port: unification, goals (eq, conj, disj),
  fresh variables, reification, fair interleaving (zzz/pull), run/run_all. 52 assertions.
- `lib/datalog` — **implemented**. Pure Lua Datalog engine: naive bottom-up evaluation
  to fixpoint, recursive rules, guard functions, query with wildcards and named bindings.
  87 assertions.

These serve both the language tooling crowd (type inference helpers, program analysis)
and anyone who wants declarative query semantics without a full SQL engine.

**`lib/parse`** — **implemented**. Parser combinators: literal, pattern, seq, alt, many,
many1, opt, map, sep_by, between, lazy, whitespace, number, string, identifier.
Composable grammar construction. 92 assertions. Also: `lib/asm` (assembler utilities,
implemented) and `lib/ir` (intermediate representation, **implemented**) as stretch
goals for the language tooling niche.

### Missing — typechecker features (load-bearing for the ecosystem)

**Record spread union distribution** — `{ ...(A | B), k: V }` where the spread inner
type is a union. The basic `{ ...T, k: V }` spread is implemented; what remains is
distribution over union members in `env.lua:substitute_inner`. Needed for builder
patterns and mapped-type aliases instantiated with union types.

### Done — transpiler

**`lib/lua2ts`** — Lua → TypeScript transpiler. Walks the crescent AST (from
`lib/type/static/parse`) and emits TypeScript. Handles: `local` → `const`/`let`,
`==`/`~=` → `===`/`!==`, `^` → `**`, `and`/`or`/`not` → `&&`/`||`/`!`,
`#foo` → `foo.length`, `x:method(args)` → `x.method(args)`, `x.new(...)` →
`new x(...)`, `error("msg")` → `throw new Error("msg")`, `require("lib.foo")` →
ESM `import * as foo from "./lib/foo"`, `for i = 1, n` → 0-indexed for loop,
`ipairs(t)` → `t.entries()`, `pairs(t)` → `Object.entries(t)`, `pcall(f, ...)` →
try/catch IIFE, `--:` annotations → TypeScript type signatures. FFI/debug/bit.* calls
emit `/* TODO */` comments. Metatables are emitted as plain objects. 112 tests.

## Priority order

Ordered by how many other things unblock:

1. **Async I/O / event loop** — unlocks: concurrent HTTP servers, multiplexed
   connections, everything network-bound. Largest single gap.
2. **Datetime** — unlocks: Lumen timeline, logging, any timestamped data.
3. **CLI arg parsing** — unlocks: every CLI tool (Lumen CLI, `cr` package manager CLI).
4. **Structured logging** — unlocks: production-grade observability in any service.
5. **`lib/jsonrpc`** — unlocks: LSP, MCP, any JSON-RPC protocol.
6. **`lib/lsp`** — unlocks: building language servers with crescent (including
   crescent's own LSP daemon, which currently lives in `lib/type/static/lsp.lua`
   and would benefit from a proper protocol layer).
7. **UUID** — done (`lib/uuid`). Unblocks entity IDs everywhere.
8. **TOML** — unblocks package manager config, application config.
9. **Regex** — unblocks search syntax, text processing.
10. **Compression** — unblocks HTTP content encoding, sync.
11. **More crypto** — unblocks E2E sync (AES-GCM, HKDF).
12. **Template engine** — unblocks prose assembly, HTML generation.
13. **World state lib** — unblocks RP substrate, Lumen entity model.

## The logical conclusion

The verticals compound. Web backend + CLI tooling + system primitives + package manager
+ typechecker + shell utilities + TUI = a complete userspace. Not a goal, but a natural
endpoint: if crescent is genuinely batteries-included, you could build everything above
the kernel line in it. coreutils, a shell, a service manager, a text editor. All
vendorable, all typed, all cross-platform.

The package manager already exists. The typechecker already exists. The rest is just
a long TODO list.

## Why vendor-first doesn't mean bloat

The npm cautionary tale is not about vendoring — it's about **fragmentation**. Thousands
of packages with no shared conventions, no coherent design, no single source of truth.
Each package is its own island. Modularity without coherence produces a dependency graph
that no one can audit or reason about.

Crescent's modularity is within a bounded, coherent system. `lib/` has one error
convention, one iterator protocol, one type annotation syntax, one naming convention.
Any two libraries compose because they were designed together. The dependency direction
is always *toward* `lib/`, never outward into an unbounded third-party graph.

Vendoring `lib/http` means vendoring `lib/http` — not `lib/http` plus its transitive
dependencies, because those dependencies are also in `lib/`, which is already there.
The graph is shallow by design, not by accident.

The LuaJIT binary is ~500KB. A typical application's `dep/` is a handful of `.lua`
files. The whole thing fits in a git repo. That's not bloat — that's a complete,
auditable, self-contained artifact.

## Vendored runtime

LuaJIT binaries are vendored directly in the repo — one per platform
(linux-x86_64, linux-aarch64, macos-x86_64, macos-aarch64, windows-x86_64).
A bootstrap script selects the right one.

LuaJIT's release cadence is effectively frozen (2.1 beta has been stable for years),
so the binary doesn't change without a deliberate commit. Vendoring it means:

- No "install LuaJIT" step in the getting-started story
- No version variance across users (distro packages, 2.0 vs 2.1, patched forks)
- The repo is the complete runtime — clone and run, nothing else required
- Full vertical ownership: libraries, tooling, and runtime are all in one place,
  all auditable, all yours

The only external dependency left is a C compiler for any FFI work that needs
it — which is as close to a universal assumption as exists.

## The typed ecosystem flywheel

Every library in `lib/` is fully annotated with crescent-style `--:` types. The
typechecker reads these directly. The result:

- **Discovery** — type search (`lib/type/static/`) finds functions by signature, not
  name. New library → immediately searchable.
- **Composition** — libraries snap together without glue code because their interfaces
  are explicit contracts, not conventions.
- **Protocol bindings** — a pre-typed protocol library (`lib/lsp`, `lib/mcp` (Model Context Protocol)) means
  you implement handlers and the typechecker validates them against the spec. You never
  write a schema; the types are the schema.
- **Typed holes** — `_: unknown` in a stdlib definition is a typed hole. `unknown`
  forces narrowing at every use site, propagating "not designed yet" through the type
  graph automatically. Incomplete APIs are loud, not silent.

The flywheel: more typed libraries → better discovery → easier composition → more
libraries built → repeat.
