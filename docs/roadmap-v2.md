# Crescent roadmap

> Derived from the value landscape analysis, the existing library inventory,
> and the batteries-included scope document. This document does not repeat the
> value landscape's reasoning -- read `docs/value-landscape.md` for the
> evidence and methodology behind the priority ranking.

## The argument

The value landscape identifies a structural opportunity: **local-first tools
that work under constrained assumptions (offline, low-bandwidth, low-storage,
non-English, cheap devices) have the highest marginal value in software today.**
Current solutions fail these populations most completely, and the absence of
network effects means quality alone drives adoption.

Crescent is unusually well-positioned to deliver here:

- **~12MB total footprint** (runtime + entire library ecosystem) vs 433MB for
  a typical Node.js app. Entry-level phones in 2026 have 4 GB RAM and 64 GB
  storage; crescent fits where most stacks do not.
- **Zero-dependency, vendoring-first.** `git clone` and run. No package
  registry, no build step, no internet required after clone.
- **LuaJIT performance.** Fast enough for real applications on constrained
  hardware. Pure Lua baseline means nothing hard-depends on system libraries.
- **Copy-paste-ownable.** Every library is a directory you can vendor into your
  own project. No upstream to break you.

The question this roadmap answers: given that positioning and the value
landscape's priorities, what should be built, in what order?

## Strategic framing

Crescent is a substrate, not an application company. The batteries-included
thesis (see `docs/batteries.md`) is that motivating applications prove the
substrate is real -- the applications are the demo, the substrate is the
product. The propagation mechanism is inspection: someone opens `lib/`, reads
the code, copies it into their own project.

This means the roadmap has two interleaved tracks:

1. **Substrate work** -- filling gaps in `lib/` that block entire categories
   of application.
2. **Motivating applications** -- concrete apps that exercise the substrate
   end-to-end, proving it works and attracting users who then discover the
   ecosystem.

The value landscape drives which applications to motivate and therefore which
substrate to prioritize. The ordering principle is: **substrate before
consumers** (per CLAUDE.md hard constraint), but the value landscape chooses
*which* substrate matters most by identifying which consumers are
highest-leverage.

---

## Phase 1: Make the existing stack production-grade

These are substrate gaps that block nearly every application category, not just
one. They are already partially built; the work is completion and adoption, not
greenfield.

### 1a. Async I/O adoption -- done (2026-07-22)

**Status: closed as cleanup, not adoption.** Auditing this item found
`lib/http/server.lua` was already a coroutine-per-connection server wired
through the `lib/async` + `lib/io_poll` integration (from earlier work,
predating this roadmap's 1a framing) -- the "no existing server uses the
integrated loop yet" premise below was stale by the time it was checked. What
actually remained was cleanup: commit `8e161785` fixed an idle-timeout race
(the keep-alive timer could still fire and close a connection that had just
read data successfully in the same poller tick; replaced with `async.race()`
over the readable promise and the sleep timer, keeping only the first
settler), added `lib/http/server_concurrency_test.lua` (proves concurrent
handlers interleave rather than serialize), and removed the dead fork()-based
`lib/http/server_fork.lua`.

<details>
<summary>Original framing (superseded)</summary>

`lib/async` is integrated with `lib/io_poll` and tested (133 assertions). No
existing server or multiplexed connection code uses the integrated loop yet.

**What remains:** Wire `lib/http` server through the async event loop so a
single process can handle concurrent connections. This unblocks every
network-bound application -- web dashboards, sync servers, API backends.

**Why first:** Without this, every crescent application that serves HTTP is
single-connection. The motivating applications below all need a web interface
(crescent's browser story is Lua HTTP server + `lib/web/reactive_dom`).

</details>

### 1b. TLS completion -- architecture decided, Linux x86_64 shipped (2026-07-22)

**Decision: FFI-first, vendor libtls, pure-Lua fallback stays in scope but low
priority.** Commit `6ec2a858` vendors LibreSSL 4.3.2 portable source in full
under `dep/libressl/` (checksum-verified against the OpenBSD-published
SHA256, rebuildable offline with no network access) plus musl-linked Linux
x86_64 binaries (`libcrypto.so.57`, `libssl.so.60`, `libtls.so.33`,
`$ORIGIN`-rpathed so the three resolve each other's SONAMEs wherever the
directory ends up) under `dep/libressl/linux-x86_64/`. `build-vendored.yml`
gained a matching build job. `lib/tls/init.lua`'s loader tries the vendored
path first, then falls through to system library search -- the same tier
pattern `lib/sqlite` already uses.

This resolves the open question below in favor of the system-tier path: it
ships faster and LibreSSL is a mature, audited implementation, which matters
more for a security-critical protocol than the zero-dependency purity of a
from-scratch pure-Lua stack. The pure-Lua crypto primitives (AES-GCM,
ChaCha20-Poly1305, X25519, HKDF, X.509 parsing) that already exist remain
in scope as a genuine fallback tier -- per CLAUDE.md's "no library may
hard-depend on a system lib" pure-Lua-baseline rule -- but are now explicitly
low priority given the FFI tier works for the common platform.

**What remains:** Only Linux x86_64 has a vendored libtls; macOS, Linux
aarch64, and Windows fall through to an unguaranteed system library search
(tracked in `TODO.md`, "Vendoring gaps"). The pure-Lua TLS state machine and
record-layer framing (the fallback tier) are not built.

<details>
<summary>Original framing (superseded)</summary>

`lib/tls` is wip. `lib/https` is wip. Production HTTP requires TLS. Without
it, crescent applications can only serve localhost or sit behind a reverse
proxy.

**What remains:** This is genuinely unclear -- the current TLS state needs
audit to determine how much is done vs how much remains. The pure-Lua crypto
primitives exist (AES-GCM, ChaCha20-Poly1305, X25519, HKDF, X.509 parsing),
but the TLS state machine and record-layer framing may be incomplete.

**Open question:** Is the goal a pure-Lua TLS implementation, or system-tier
FFI to a TLS library (OpenSSL/LibreSSL/mbedTLS) with pure-Lua fallback? The
pure-Lua path is more aligned with crescent's zero-dependency principle but
significantly harder to get right (TLS is a security-critical protocol where
implementation bugs have real consequences). The system-tier path is faster to
ship but adds an optional system dependency.

</details>

### 1c. Package manager install algorithm

`lib/pkg` has semver, manifest, and lockfile parsers. The install algorithm is
not yet implemented.

**Why it matters:** The propagation story today is "clone the monorepo and copy
what you need." A working package manager enables a lighter path: install just
the libraries you want. This matters for adoption -- the monorepo is the right
development model for crescent itself, but users building applications want to
pull in specific pieces.

**Open question:** The design is documented in `docs/pkg-design.md` (not read
for this roadmap). The install algorithm's scope and approach are presumably
specified there.

---

## Phase 2: Substrate for the highest-value application categories

These are gaps in `lib/` that block specific high-value application categories
identified by the value landscape. Ordered by how many top-ranked categories
they unblock.

### 2a. PDF codec -- foundation + forms path + text-extraction path shipped (2026-07-22)

**Status: substantial progress, not complete.** A four-commit sequence built
the shared foundation and both entry points the "open question" below asked
about, instead of choosing one first:

- Foundation: object-model lexer/parser for all 8 PDF object types plus the
  indirect-object wrapper (`c6ec40ff`), cross-reference table parser
  covering both traditional xref tables and xref streams with PNG-predictor
  un-filtering (`32d69333`), and a filter-decoding module (FlateDecode +
  PNG predictors) wired into a top-level `lib/pdf/init.lua` document loader
  (`b68305d5`).
- Forms path: AcroForm field extraction/filling plus incremental-update
  writing (`70c78a57`) -- serves value-landscape categories #1 and #2.
- Text-extraction path: content-stream operator parsing, font/encoding
  mapping (3 base encodings + `/ToUnicode` CMaps), text positioning, and
  reading-order reconstruction (`6824d63d`) -- serves categories #3 and #5.

388 assertions total across `lib/pdf/*_test.lua`, 0 typecheck errors.

**What remains, documented as explicit out-of-scope rather than silently
half-done:** Type0/CID composite fonts beyond Identity-H/V + `/ToUnicode`,
per-glyph-width text advance (no `/Widths` array parsing), non-FlateDecode
stream filters, Object Streams (xref entry type 2 -- entries are represented
but not resolved), and AcroForm appearance-stream regeneration (needs
font/text layout, a parallel effort). No PDF generation-from-scratch path
(only incremental updates to an existing document) and no image extraction
yet -- both still open against the value-landscape categories this library
targets. System-tier FFI to MuPDF/Poppler for the long tail (scanned
documents, complex rendering) is untouched.

Five typechecker substrate gaps were found and worked around during this
work; see `TODO.md`'s "Typechecker substrate gaps (found while implementing
lib/pdf/...)" sections for repros and revert conditions.

A PDF parser and writer is the single largest substrate gap when measured
against the value landscape. It blocks:

- **Personal finance (#1):** Importing bank statements, generating reports.
- **Bureaucratic forms (#2):** The entire category -- government forms are PDFs.
  Parsing form fields, filling them, producing completed PDFs.
- **Accessibility (#3):** Document remediation of inaccessible PDFs (heading
  structure, reading order, alt text).
- **Data format conversion (#5):** PDF is one of the most common conversion
  targets (DOCX-to-PDF, HTML-to-PDF, merge PDFs).

No other single library unblocks as many top-5 value categories.

**Scope:** At minimum: parse PDF structure (pages, text content, form fields,
images). Write/modify PDFs (fill form fields, add text, set document
structure). The PDF spec is enormous (ISO 32000-2 is 1000+ pages), but the
subset needed for forms + text extraction + basic generation is bounded.

**Tier approach:** Pure Lua parser for the common subset. System-tier FFI to
something like MuPDF or Poppler for the long tail of edge cases (scanned
documents, complex rendering).

**Open question:** How much of the PDF spec to target initially. A forms-first
approach (parse form fields, fill them, write back) serves categories #1
and #2 directly. A text-extraction-first approach serves #3 and #5. These are
different entry points into the same library. Which to start with depends on
which motivating application comes first.

### 2b. Internationalization depth -- bidi implemented and integrated (2026-07-26)

The value landscape's strongest cross-cutting finding: "The single strongest
predictor of underserved populations is whether a tool can function offline in
a non-English context."

Crescent has `lib/i18n` (translation lookup, pluralization for 15+ languages,
locale switching) and `lib/locale` (number/currency/date formatting, CLDR
plural rules). These cover the basics.

**Status: RTL text layout done.** `lib/bidi` implements the Unicode
Bidirectional Algorithm (commit `1fe14493`, classification data and
`visual_runs` API expanded in `6ef53d89`) and is wired into `lib/word_wrap`
and `lib/text_justify`, so those utilities no longer assume left-to-right.
This closes the RTL bullet below for Arabic and Hebrew.

**What's still missing for real non-English applications:**

- **Complex script shaping.** Hindi (1B+ internet users, <0.1% of web
  content) and other Indic scripts use conjunct consonants, vowel signs, and
  reordering rules that basic Unicode rendering does not handle. This is a
  hard problem -- HarfBuzz exists because it's hard -- but crescent's text
  utilities need at least awareness of script directionality and cluster
  boundaries. Bidi (above) covers directionality; cluster-boundary awareness
  and shaping itself remain open.
- **Input method support.** CJK input methods, Indic transliteration. This
  matters for any text-input application.
- **Locale-specific financial formats.** `lib/money` has 22 ISO 4217
  currencies. Real micro-business bookkeeping needs locale-aware number entry
  (comma vs period as decimal separator), date formats, and tax period
  conventions.

**Open question:** How deep to go on shaping. Full complex script shaping is a
multi-year effort (HarfBuzz is 200K+ lines of C). The pragmatic path might
be: keep bidi as the directionality layer (done), add cluster-boundary
awareness, and provide locale-aware formatting -- then let system-tier font
rendering handle the shaping itself. But this depends on what rendering
surface crescent applications target (terminal? browser? native?).

### 2c. Double-entry bookkeeping library -- domain model done (2026-07-26)

The value landscape ranks personal finance / micro-business bookkeeping #1.
Crescent has the arithmetic primitives (`lib/decimal`, `lib/money`,
`lib/finance`) and storage (`lib/sqlite`); `lib/bookkeeping` now models the
domain (commit `6105015f`).

**Status: core domain model implemented.** `lib/bookkeeping/` has
`account.lua` (chart of accounts), `journal.lua` (double-entry journal
entries, debits/credits), `ledger.lua` (derived ledger), and
`trial_balance.lua` (trial balance), each with its own test file.

**What remains:** Income statement / balance sheet reports built on top of
the trial balance, multi-currency exchange-rate tracking, cash-basis vs.
accrual-basis views, and import from OFX/QIF/CSV bank statements are not yet
covered by the current `lib/bookkeeping` files -- these were listed as
target capabilities and haven't been individually confirmed done or
outstanding in this pass; check `lib/bookkeeping/init.lua` and the test
files directly before assuming any one of them is missing or present.

**Resolved:** The original open question (standalone `lib/bookkeeping` vs. a
pattern on top of `lib/ecs`) was decided in favor of the standalone library.

### 2d. Form/document structure library -- substantially built via lib/unified

For bureaucratic forms (#2) and accessibility (#3): a library that models
document structure independent of format.

**Status: largely done, not greenfield.** The original open question below
(new library vs. extend `lib/unified`) is resolved in favor of `lib/unified`:
it's no longer "wip with many empty shells" -- mdast, hast, and remark_gfm
are at 59/61 rows implemented, and the broader `lib/unified/` tree now
spans ~60 plugin/util directories (remark/rehype/retext/unist/xast families:
frontmatter, footnotes, math, directives, sanitize, highlight, slug,
autolink-headings, external-links, accessible-emojis, and more -- see
`lib/unified/` for the full list). What's described below as forward-looking
scope is now largely present as `lib/unified` node kinds and plugins;
remaining work is incremental extension (new importers/exporters, WCAG
validation logic) on an existing foundation, not building the AST layer from
scratch.

**rescribe evaluated as prior art, not adopted as canonical.** `rescribe`
(a Rust document-IR project) was audited in detail as a candidate for this
role -- see `docs/rescribe-gaps.md`. Conclusion: `rescribe::Document` does
not become crescent's canonical document/PDF representation. There is no
`pdf-fmt` crate in rescribe and PDF is not queued in rescribe's own vertical
order, so waiting on it would mean waiting on a vertical that doesn't exist.
Instead: `rescribe::Document` is an optional interchange target for
non-PDF-specific parts of a pipeline (e.g. a Markdown/HTML/DOCX conversion
step); it is not something crescent's own document/PDF models route through.
**crescent's PDF models stay native and authoritative** --
`lib/pdf/text.lua`'s `Span` and `lib/pdf/form.lua`'s `FormField` remain the
source of truth for PDF structure, including for the field/widget
shared-identity problem that `rescribe::Document`'s pure tree model can't
express structurally (crescent already solves it by flattening). Two small
fixes worth raising with rescribe's maintainers directly (RTF `lang`
namespacing bug; documenting the ResourceId-style ID/reference convention)
are non-blocking drive-by items, not part of this roadmap item.

- Headings, paragraphs, lists, tables, form fields, reading order.
- Importers from HTML (already have `lib/xml`, `lib/css_parser`), PDF (needs
  2a), DOCX (needs a DOCX/OOXML parser -- ZIP + XML, both exist).
- Exporters to accessible HTML, remediated PDF.
- WCAG validation (heading hierarchy, alt text presence, form labels, color
  contrast -- `lib/color` already has WCAG contrast ratio).

This is a larger effort than bookkeeping but serves two top-5 categories.

---

## Strategic direction: Rescribe fixture alignment

Crescent's format libraries (PDF, DOCX, SVG, image codecs, and others) should eventually align with rescribe's cross-language fixture suite for conformance testing. Rescribe (~/git/rhizone/rescribe/) is not a document converter — its primary deliverable is a language-agnostic conformance suite (`fixtures/`) paired with standalone format libraries across multiple languages. Since crescent aims to cover the full software ecosystem, aligning with rescribe's fixtures avoids rediscovering format edge cases independently.

**Status: high-value work but not immediately urgent.** Rescribe's own format crates and fixture suite are still in progress. Rather than a dedicated alignment project, pick this up per-format as specific format work comes up in crescent — when a new format codec is implemented or when an existing one is substantially enhanced, run it against rescribe's fixtures for that format (if available) as part of validation.

---

## Phase 3: Motivating applications

Each application exercises the substrate end-to-end and delivers direct value
to users in a high-leverage category. Per the batteries-included thesis, the
application is the thing people download; crescent is what they discover
inside.

### 3a. Personal finance / micro-business bookkeeping tool

**Value landscape rank:** #1.

**Why this first:** Highest marginal value x tractability. The gap left by
Mint's shutdown (March 2025) is real and growing. 500M-1B micro-business
operators globally track finances on paper or not at all. The 2026 device
regression (RAM prices up 50%, NAND up 90%) makes crescent's ~12MB footprint
a genuine advantage over Electron-based alternatives.

**What it needs from crescent:**
- `lib/bookkeeping` or equivalent (Phase 2c)
- `lib/sqlite` (exists, stable)
- `lib/money`, `lib/decimal`, `lib/finance` (exist, stable)
- `lib/csv` for bank statement import (exists, stable)
- PDF import for bank statements (Phase 2a)
- `lib/i18n`, `lib/locale` for non-English, non-Western formats (exist, need
  depth per Phase 2b)
- `lib/web` + `lib/web/reactive_dom` for browser UI (exist, stable)
- `lib/http` through async event loop (Phase 1a)

**What the value landscape says it must get right:**
- Data format that outlives the app (plain files or SQLite, not proprietary).
- Works offline by default.
- Handles cash-based workflows, not just bank-synced ones.
- Runs on low-end devices.
- Does not assume English or Western financial structures.

**Open questions:**
- Multi-frontend (TUI + web + mobile PWA?) or web-only initially?
- Sync story: `lib/crdt` exists for data-type CRDTs, but text/sequence CRDTs
  (y.js compat) are listed as missing in batteries.md. Is sync needed for v1
  of a personal finance tool, or is single-device sufficient?
- Whether this is a crescent-native app (using `lib/platform` app format) or a
  standalone application that happens to use crescent libraries. The app format
  is designed for exactly this, but adoption depends on there being a host
  that runs it.

### 3b. Developer tools (ongoing, not a phase gate)

**Value landscape rank:** #4 (very high tractability).

This is not a new direction -- crescent already IS a developer tool ecosystem.
The typechecker, test runner, LSP, MCP server, package manager, and bundler
are all developer tools. This track continues in parallel with everything
else.

**Specific next steps driven by the value landscape:**

The value landscape notes: "44% of profitable SaaS products are now run by a
single founder -- doubled since 2018 -- meaning more solo developers need
better tooling." Crescent's zero-dependency, vendoring-first model is
particularly well-suited for solo developers who want to understand and own
their entire stack.

- **Package manager install** (Phase 1c) lowers the adoption barrier.
- **Type search** (`lib/type/search/`, wip) -- find functions by signature.
  The value landscape notes AI coding tool trust has dropped to 29%; a
  type-search tool that gives exact, trustworthy results fills a gap.
- **MCP server** (`lib/mcp`, implemented) -- crescent libraries as MCP tools
  for LLM-powered development workflows.

### 3c. Data format conversion tool

**Value landscape rank:** #5 (very high tractability).

A local-first, privacy-respecting format converter. The gap is real: consumer
converters (CloudConvert, Zamzar) upload files to third-party servers.

Crescent already has an enormous codec inventory: JSON, CBOR, YAML, TOML, XML,
CSV, MessagePack, Protobuf, BSON, HTML, Markdown, INI, NDJSON, S-expressions,
bencode, base64/32/58/85, PNG (chunk-level), WAV, MIDI, SVG, tar, and
compression (gzip, brotli, zstd, lz4, snappy). Plus image processing
(`lib/image_processing`, `lib/stb`).

**What a conversion tool would need beyond existing libraries:**
- PDF (Phase 2a) -- the most-requested conversion target.
- DOCX parser (ZIP container + OOXML; ZIP is the gap, XML exists).
- A routing layer that maps source format + target format to a conversion
  pipeline.
- CLI interface (`lib/cli` exists).

This is high tractability because most of the conversion logic already exists
in `lib/`. The value is the integration -- a single `cr convert` command that
handles common cases well.

**Speculation:** This might be the easiest motivating application to ship
first, since it requires the least new substrate. The PDF gap (Phase 2a)
limits what conversions are possible, but many useful conversions (JSON to
YAML, CSV to JSON, Markdown to HTML, image format conversion) work today.

---

## Phase 4: Deeper value-landscape alignment (speculative)

These are directions the value landscape suggests but where crescent's path is
less clear. They are included because the value landscape analysis is strong,
not because they are committed direction.

### 4a. Accessibility tooling

**Value landscape rank:** #3.

Two sub-categories:

1. **Document remediation:** Take an inaccessible document, produce an
   accessible version (heading structure, alt text, reading order, form
   labels). This needs the PDF codec (Phase 2a), the document structure
   library (Phase 2d), and LLM integration for alt text generation
   (`lib/taskgraph/executor/ai` exists).

2. **Developer-side tooling:** Tools that surface WCAG failures during
   development. Crescent already has `lib/css_parser` (specificity, selector
   matching), `lib/color` (WCAG contrast ratio), and `lib/xml`/`lib/xpath`
   (DOM traversal). A `lib/a11y` that runs WCAG checks against an HTML AST
   is tractable.

**Open question:** Whether accessibility tooling is a crescent application or
a library that other tools embed. The developer-side tooling direction (a
linter or checker) aligns more naturally with crescent's identity as
infrastructure.

### 4b. Offline-first structured data tool

**Value landscape rank:** #8.

The gap: spreadsheets are the most widely used "programming" tool, but Google
Sheets requires internet, Excel requires a license, and none handle structured
data well. Crescent has `lib/sqlite`, `lib/spreadsheet` (formula evaluation
with dependency graph), `lib/csv_query` (SQL-like query engine for tabular
data), and `lib/reactive_db` (reactive in-memory relational DB with live
queries).

**Speculation:** A SQLite-backed structured data tool with formula evaluation,
reactive live queries, and a web UI could be a compelling Airtable alternative
that works offline and fits in 12MB. The primitives mostly exist; the work is
integration and UX. But this is a design problem (the "abstraction level"
challenge the value landscape identifies), and the design space is littered
with failed attempts.

### 4c. Caregiver coordination

**Value landscape rank:** #7.

The value landscape identifies this as high marginal value but notes "the
design problem has defeated many attempts." The crescent primitives exist
(calendar, recurring events, SQLite, reactive state, web UI), but the hard
part is modeling the right abstractions for household logistics.

**Not a near-term priority** -- the design risk is high and crescent's
strength is infrastructure, not UX research. Including it here because the
value landscape ranks it highly and the substrate is mostly present.

---

## What the value landscape suggests that crescent's inventory does NOT cover

These are directions the value landscape points toward where crescent has no
existing library or clear path:

1. **USSD/feature phone interface.** The value landscape notes that mobile
   money via USSD is "the most successful technology deployment to underserved
   populations in history." Crescent targets LuaJIT on Linux/macOS/Windows.
   Feature phones running KaiOS or bare RTOS firmware are not a natural target.
   Reaching the 2.1B feature phone users requires a different delivery
   mechanism than crescent's current model.

2. **Mobile app distribution.** The value landscape emphasizes smartphones
   (5.8B users, 4 GB RAM entry-level). Crescent applications can serve web UIs
   that work on mobile browsers, but there is no native Android/iOS story. A
   PWA served from a local crescent HTTP server is one path; a crescent
   runtime compiled for Android via LuaJIT's ARM support is another. Neither
   is explored.

3. **Voice interface / audio processing.** Several value landscape categories
   (education, accessibility, forms) benefit from voice input. Crescent has
   `lib/wave` (WAV codec) and `lib/dsp` (signal processing), but no speech
   recognition pipeline. This likely requires system-tier FFI to something
   like Whisper.cpp rather than a pure-Lua implementation.

These are noted as gaps, not proposals. Whether crescent should pursue any of
them is an open question that depends on where the project's energy is best
spent.

---

## Ordering summary

| Priority | Item | Depends on | Unblocks | Status |
|----------|------|------------|----------|--------|
| 1a | Async I/O adoption | -- | Every networked app | Done (2026-07-22) |
| 1b | TLS audit + completion | -- | Production HTTPS | Linux x86_64 done (2026-07-22); other platforms + pure-Lua fallback open |
| 1c | Package manager install | -- | Adoption | Not started |
| 2a | PDF codec | -- | Finance, forms, a11y, conversion | Foundation + forms + text extraction done (2026-07-22); see scope gaps above |
| 2b | i18n depth (RTL, locale) | -- | Non-English applications | Bidi implemented + integrated with word_wrap/text_justify (2026-07-26); shaping, input methods, locale-aware financial formats open |
| 2c | Bookkeeping library | 2a (for PDF import) | Finance app | Domain model done (account/journal/ledger/trial_balance, 2026-07-26); reports, multi-currency, bank-format import not yet confirmed |
| 2d | Document structure lib | 2a | Forms app, a11y tooling | Substantially built via `lib/unified` (mdast/hast/remark_gfm 59/61 rows); rescribe evaluated as prior art, not adopted as canonical -- see `docs/rescribe-gaps.md` |
| 3a | Finance/bookkeeping app | 1a, 2a, 2b, 2c | Proves substrate for #1 value category | Not started |
| 3b | Developer tools | 1c, 1d | Ongoing | Ongoing |
| 3c | Format conversion tool | 2a (optional) | Proves substrate for #5 value category | Not started |
| 4a | Accessibility tooling | 2a, 2d | #3 value category | Not started |
| 4b | Structured data tool | 1a | #8 value category | Not started |
| 4c | Caregiver coordination | 1a | #7 value category (design-risk) | Not started |

Phase 1 items are independent and can be worked in parallel.
Phase 2 items are mostly independent (2c and 2d both depend on 2a).
Phase 3 items depend on their respective substrate from Phases 1-2.
Phase 4 items are speculative.

---

## Note: Typechecker replacement is parked

The legacy typechecker (`lib/type/static/`, v2/v3 lineage, 53K lines) is the
working tool and gates all commits. A replacement has been pursued through 8
rewrite attempts (v4, v5, v6, v7, framework, v9, toy_checker, declc) without
success. The last viable candidate (v9) measured ~3% hard-true precision. The
follow-up (toy_checker) encountered an unsolved hard problem in the type
inference engine.

**As of 2026-07-08:** Typechecker replacement work is parked. Autonomous
agent-directed development was declared dead by owner verdict (supervision
cost exceeded value). This does not block other work — applications and
libraries continue to be built and tested against the working legacy checker.

Resuming typechecker work requires either solving the hard problem or finding
a fundamentally different approach. This is noted here because earlier phases
of this roadmap (v1) listed the typechecker as a Phase 1 priority; it is not.

---

## What this roadmap does NOT cover

- **Consolidation of duplicate library clusters.** The inventory has ~25
  duplicate pairs/triplets (5 FSM impls, multiple bloom filters, parallel
  LRU caches, etc.). `docs/duplicate_clusters.md` has the triage. This is
  maintenance work, not roadmap-level.
- **Games.** `docs/batteries.md` lists chess, mahjong, spider solitaire,
  freecell as motivating targets. These prove the substrate for game
  development but are not high-priority per the value landscape (games are
  not among the top-11 marginal-value categories).
- **The SillyTavern/RP vertical.** `docs/batteries.md` describes this in
  detail. It is a legitimate motivating application but serves a niche
  community rather than a high-marginal-value population per the value
  landscape.
- **The "logical conclusion" (coreutils, shell, service manager, text
  editor).** These are noted in `docs/batteries.md` as the natural endpoint
  of batteries-included, but they are not high-marginal-value per the
  landscape -- existing solutions (bash, systemd, vim/emacs) are mature and
  well-served.
