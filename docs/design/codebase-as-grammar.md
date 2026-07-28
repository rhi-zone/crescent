# Codebase as one flat grammar: a first prototype

**Status: exploratory; the core mechanism has been automated and run at
whole-`lib/` scale (see "Automated induction" below), but scale-wide
conclusions remain partial** — real new gaps surfaced (comment-embedded
slots invisible to the AST tool, no discriminator between meaningful and
noise slots) alongside real confirmations (the ground-truth ternary/if-else
unification holds, and generalizes to dozens of independent instances
across `lib/`). This started as a sketch against one family of 5 files;
read the "What's proven vs. aspirational" section (and its "Automated
induction" update near the end of this document) before citing this
document as justification for anything.

## The mechanism

Model a codebase as **one flat grammar** of production rules, in the
SEQUITUR/RePair sense: repeated structure gets promoted into a named,
parameterized rule (a *production*); every symbol in the corpus is either a
terminal (literal content) or a reference to a production.

The core claim, and the one that took several wrong turns to reach, is:
**there is no separate "convention layer" vs. "decision layer."** A
production referenced 100 times and a production referenced once are the
same kind of object — differing only in reuse count, which is a statistical
fact you read off the corpus after induction, not a distinction you design
in ahead of time. What reads as "a convention" is just a production with
high reuse. What reads as "a one-off decision" is a production with
low/unique reuse.

A "decision," in this model, is always the same move: **at a slot** (a
position in the grammar where more than one production could apply) **,
which production gets used here.** This splits into two cases that turn out
to be the same case:

- **Branch-selection**: the slot already has established alternatives
  elsewhere in the corpus, and authoring an instance means picking one.
  Cheap — bounded, roughly `log2(k)` over `k` known options.
- **Minting**: none of the existing alternatives fit, so a new production is
  created on the spot. Expensive, unbounded — but *not a separate
  mechanism* from branch-selection. It's the same act (choose a production
  for this slot) where the chosen production simply didn't exist yet before
  this instance. Once minted, it is an ordinary alternative available at
  that slot for the next instance. No separate "update the model" step,
  because minting already was branch-selection.

The generator is a **decoder for this grammar**: given the induced grammar
(productions + their alternatives, discovered by finding what repeats in
the actual corpus) plus a **derivation** (a sequence of slot→production
choices for one instance, including any newly-minted productions), expand
it into real source code.

Two real, separable parts:

1. **Grammar induction** — find what actually repeats across the corpus and
   identify the slots: positions where multiple established alternatives
   already coexist across instances that are "the same shape" in some real
   sense. Done here by hand-diffing the five files, not by a general
   RePair/SEQUITUR implementation.
2. **Derivation-as-authoring** — once productions/slots exist, a module's
   decision-set is a derivation against that grammar: a small set of
   (slot, chosen-production) pairs, expanded mechanically into the file.

## The corpus, as it actually is (not as summarized)

The originating brief named 12 files as "crescent's tiered-dispatcher
`init.lua` family." Reading all 12 before doing anything else (per the
brief's own instruction) surfaced a real discrepancy worth recording rather
than smoothing over: **only 5 of the 12 are actually that shape.**

Genuine tiered dispatchers — pick a tier via `pcall(require, ...)` at load
time, then re-export a fixed API as a thin, mostly-generated-feeling layer:

- `lib/compress/init.lua`
- `lib/crypto/init.lua`
- `lib/format/json/init.lua`
- `lib/encode/base64/init.lua`
- `lib/regex/init.lua`

Not this shape at all — full implementations with a hardcoded
`M._tier = "pure"` and no fallback chain (`lib/lz4`, `lib/x509`,
`lib/csv_query`, `lib/word_wrap`, `lib/text_justify`), or tier-selecting but
structurally unlike the other 5 in ways that would need their own,
separately-induced grammar rather than forcing them into this one:

- `lib/keyring/init.lua` — does tier-select via `pcall`, but the three
  tiers' *implementations* (hundreds of lines of FFI/crypto code each) live
  inline in `init.lua` itself, selection is lazy (`load_backend()` on first
  call, not at load time), and there is no thin re-export layer at all.
- `lib/stb/init.lua` — tier-selects at load time like the core 5, but each
  tier function mutates the module table directly inside its own `try_*`
  function rather than building one narrowed table literal at the end.

This prototype only covers the 5 genuine dispatchers. `keyring` and `stb`
are real members of a *looser* family ("things that pick an implementation
tier") but not of *this* grammar. Folding them in without inducing their own
slots would have been exactly the "invent a plausible-sounding alternative"
move the brief warned against.

## What the induction actually found

Diffing the 5 files pairwise (not designing categories up front) surfaced
these productions. Each entry names its reuse count — the thing that
distinguishes "convention" from "decision" is visible directly in this
list, not asserted separately.

### `path_bootstrap` — 5 instances, 2 independent slots

Every file starts with the same `package.path` guard, but two things vary
*independently*:

- **indent** of the body line: `"  "` (compress), `"\t"` (crypto, regex),
  `"    "` (base64, json). This turned out to be a **file-level** choice —
  every file uses one indent style throughout, not just in this one spot —
  so it's not really a `path_bootstrap`-local slot; it's a top-of-derivation
  parameter that many productions read.
- **find_string** passed to `package.path:find`: `"./?/init.lua"` (4 of 5)
  vs. `"?/init.lua"` (base64 only). The base64 one is very likely a
  copy-paste slip — `:find` without pattern-anchoring still matches, so it
  works, but it is a different string, produced by a different (if
  accidental) choice. The grammar records what the corpus contains, not
  what it should contain: `productions.lua`'s comment on this says so
  explicitly, and the base64 derivation reproduces the anomaly rather than
  "fixing" it.

### `tier_select` — one slot, two established alternatives

How a module selects and narrows across tiers is a single slot with two
real alternatives, not two different mechanisms:

- **`cast_narrow`** (compress, crypto, regex): try one optional tier via
  `pcall`; on success or failure, end up with an `impl` of type `unknown`;
  force-cast the whole thing once into a `{ field: unknown, ... }` probe
  shape (`impl_t`), then cast each field individually when building `M`.
  This pattern itself has a sub-slot (the ok-check): **`plain`**
  (compress, crypto — if/else) vs. **`ternary_cache_clear`** (regex — a
  ternary plus `package.loaded[...] = nil` so a failed require can be
  retried later). Two established productions at one sub-slot; regex didn't
  invent a third thing, it picked (or minted, the first time) the second of
  two.
- **`incremental_override`** (base64, json): require the pure tier directly
  (keeps its static type, no cast needed), then try each optional tier in
  turn, overriding `impl`/`tier` on success. The "try this tier" block
  inside this pattern is itself a repeated sub-production: it occurs twice
  in base64 (ffi, simd) and twice in json (ffi, simd) — 4 occurrences of
  one production, found structurally by diffing, not asserted because it
  seemed plausible.

These two alternatives don't just differ in the tier-select code — they
carry a whole accompanying commenting convention with them
(`── Public module ──` / `── Tier selection ──` banner comments appear only
in the `incremental_override` files) and a different position for the
type-narrowing line relative to the type declaration (see below). Choosing
between them is not "pick a tier-select snippet," it's picking a whole
file-organization alternative.

### `type_alias_block` — 5 instances, 1 alternative (the closest thing here to a pure convention)

Every file declares one `--::` alias per exported function shape, composes
them into a `<Name>Module` struct type, in the same visually-aligned
`--::     field:  Type,` format (field names right-padded to the widest
name in the block — computed here, not eyeballed per file). Nobody picked
among options at this slot; the single production that exists is what
everybody used. That's what "high reuse, zero variance" looks like when you
actually check.

One real per-file anomaly reproduced rather than corrected: json's
`JsonModule` struct omits the trailing comma on its last field (`schema`),
and json also has its `── Public module ──` banner comment duplicated
verbatim, twice in a row. Both look like copy-paste artifacts. Both are in
the generated output because the generator's job is fidelity to the corpus,
not silent cleanup.

### `narrow_comment` — position varies with the tier_select choice

The `--: TypeName` line that narrows the table literal below it is a tiny,
universal production, but *where it sits* is not independent — it's
downstream of the `tier_select` choice. In `cast_narrow` files it sits
right under the struct declaration. In `incremental_override` files the
struct is declared early (before tier selection) and the narrow line is
deferred until immediately before `local M = {`, i.e. split apart from the
struct by the entire tier-selection block. This is a real example of slots
not being independent dimensions you can freely cross-product — some are
downstream consequences of an earlier choice.

### `m_table_cast_narrow` / `m_table_incremental` — one per tier_select alternative

Building the final `local M = { ... }` table has its own two alternatives,
correlated 1:1 with the `tier_select` choice (not actually a separate,
independently-varying slot once you look closely): `cast_narrow` files cast
every field individually off `impl_t`; `incremental_override` files read
fields straight off the already-typed `impl`, plus `_impl = impl`.

Field/value alignment (padding names — and, in `cast_narrow`, the
`impl_t.<name>` expressions too — to the widest one in the block) is
computed generically from the field list, not hardcoded per file. It
happens to fall out correctly for `cast_narrow` because the right-hand-side
expression is `"impl_t." .. name`: a constant prefix means the padding
needed to align the value column is exactly the same amount as the padding
needed to align the name column. That's a genuine, derived fact about the
naming convention, not a coincidence I asserted.

### The one real escape hatch: crypto's `random_bytes`

`lib/crypto/init.lua`'s `random_bytes` is left with no type cast in the `M`
table, with a comment explaining that the two tiers take incompatible
argument lists (`(n)` vs. `(random_bytes_fn, n)`). This is the case the
brief specifically asked to be preserved rather than papered over: **no
existing alternative at the "field cast" slot fits, and none should be
minted** — a union type or a force-cast here would lie about the call
shape, not describe it. The `m_table_cast_narrow` production models this
as a field with no `type` (and an optional `comment`), which is a real,
distinct production output, not a special case bolted onto the function:
every other field also goes through the same function, just with `type`
set.

## What's proven vs. aspirational

**Proven, by actually running it:**

- The 5 productions above, hand-induced by diffing the real files, are
  real — every one of them is exercised by at least one derivation, most by
  two or more.
- All 5 real files (`compress`, `crypto`, `regex`, `base64`,
  `lib/format/json`) are reproduced **byte-for-byte** from their
  derivations by `tooling/grammar_gen/generate.lua`. This is checked by
  diffing generated output against the actual file on disk, not asserted —
  run `bin/luajit tooling/grammar_gen/generate.lua --all --diff` to
  reproduce the check.
- The escape hatch (crypto's `random_bytes`) round-trips correctly as a
  first-class "no cast, has a comment" production output, not a hardcoded
  special case in the generator.
- Some real anomalies in the corpus (base64's `find_string` typo, json's
  duplicated banner comment, json's missing trailing comma) are preserved
  by the derivations rather than corrected — the generator's job is
  fidelity, and "fixing" them would have been generating a file that never
  existed.

**Not proven — genuinely open:**

- **Scale.** This is 5 files. Whether the same one-flat-grammar model holds
  up over crescent's ~150+ libraries, or fragments into many small
  unrelated grammars (one per API shape), is unknown. The `lz4`/`x509`/etc.
  discrepancy above is a small, concrete data point *against* naive
  scaling: a plausible-sounding category ("tiered dispatcher init.lua
  files") turned out to be two-fifths accurate on inspection.
- **Grammar induction itself.** Nothing here runs SEQUITUR or RePair.
  Finding the slots was done by a person (this session) diffing 5 files by
  hand. Whether an automated induction pass would find the *same* slots —
  or find spurious ones, or miss the file-level "indent style" slot that
  only becomes visible once you check whether it's really local to one
  production — is untested.
- **Compression-ratio claims at scale.** See the numbers below for this
  one family; they should not be extrapolated to a codebase-wide ratio
  without doing the same induction work elsewhere.
- **The `keyring`/`stb` case.** These are real members of a *looser* family
  the corpus contains but this grammar doesn't cover. Whether they warrant
  their own grammar, an extension of this one, or neither, is open.
- **Whether "decisions as slot-selection" holds for logic-heavy code.**
  Everything in this prototype is boilerplate-shaped (dispatch + re-export).
  Whether the same framing usefully applies to, say, `lib/lz4`'s actual
  compression algorithm (which has no obvious "slots" — it's one coherent
  implementation, not an instance of a repeated shape) is a different and
  much harder question this prototype does not attempt.

## The prototype

Lives at `tooling/grammar_gen/` (not `lib/` — crescent's CLAUDE.md is
explicit that `lib/` carries no framework/generic-dispatch code, and this
is exactly that: a generic expander over a hand-induced grammar, useful for
this one analysis, not a reusable library).

- `tooling/grammar_gen/derivations.lua` — the grammar's productions (as
  plain Lua functions) and the 5 real derivations, in one file. See that
  file's header comment for why productions and derivations aren't split
  across two files as originally structured — a real crescent typechecker
  substrate gap around narrowing `require()` results for local modules
  (below), not a design preference.
- `tooling/grammar_gen/generate.lua` — the decoder: expands a derivation
  into source text, and (with `--diff`) diffs it against the real file on
  disk.

Implemented in Lua, run via crescent's vendored LuaJIT
(`bin/luajit tooling/grammar_gen/generate.lua`), consistent with crescent's
pure-Lua-first ethos even though this is throwaway analysis tooling rather
than a shipped library.

### Verification

```
$ bin/luajit tooling/grammar_gen/generate.lua --all --diff
base64: IDENTICAL (2690 bytes)
compress: IDENTICAL (1925 bytes)
crypto: IDENTICAL (2485 bytes)
json: IDENTICAL (4142 bytes)
regex: IDENTICAL (2176 bytes)
```

`timeout 30 bin/cr check tooling/grammar_gen/derivations.lua
tooling/grammar_gen/generate.lua` reports 0 errors, 0 warnings.

### A real typechecker substrate note, surfaced while building this

Getting the prototype to typecheck cleanly surfaced a genuine, verifiable
gap, not specific to this tool: **`bin/cr check` currently rejects the
force-cast pattern (`--[[:! T]]`) that the real corpus files themselves use
at their tier-selection pcall boundary.**

```
$ timeout 30 bin/cr check lib/encode/base64/init.lua lib/format/json/init.lua
lib/encode/base64/init.lua:47:12: error: force cast — fix the upstream type annotation instead; see CLAUDE.md
lib/encode/base64/init.lua:55:12: error: force cast — fix the upstream type annotation instead; see CLAUDE.md
lib/format/json/init.lua:68:12: error: force cast — fix the upstream type annotation instead; see CLAUDE.md
lib/format/json/init.lua:76:12: error: force cast — fix the upstream type annotation instead; see CLAUDE.md
```

This means two of the five files this prototype reproduces byte-for-byte do
not, themselves, currently pass `bin/cr check` with zero errors — a
pre-existing fact about the shipped corpus, not something this session
introduced. It surfaced only because building `tooling/grammar_gen` hit the
identical pattern (narrowing a `require()` result across a module boundary
without an established non-force-cast path) and the checker rejected it
there too. Framed as substrate per this repo's own planning rules: the gap
is "narrowing an `unknown`-returning `require()` result for a local
(non-stdlib) module surface has no non-force-cast path today," not "these
two files are broken." See `TODO.md` for the entry recording this without
attempting a fix here — fixing it is typechecker work, out of scope for a
grammar-induction prototype.

## Compression, in this one family, measured (not estimated)

Two numbers, both measured directly rather than eyeballed — see
`tooling/grammar_gen/` for how to reproduce both:

**Generated-output split** (run a small script over `derivations.lua` that
sums, per file, how many generated bytes came from `raw` terminal segments
vs. `rule` production-expansion segments):

| file | generated bytes | from raw terminals | from productions |
|---|---:|---:|---:|
| compress | 1925 | 531 | 1394 |
| crypto | 2485 | 755 | 1730 |
| regex | 2176 | 474 | 1702 |
| base64 | 2690 | 1290 | 1400 |
| json | 4142 | 1971 | 2171 |

Roughly half to two-thirds of each file's bytes come from productions, not
free-form prose — consistent with the corpus actually being boilerplate-
shaped, not just "mostly comments with a bit of structure."

**Derivation source size vs. generated size** (the `D.<name> = { ... }`
literal as written in `derivations.lua`, by line range, vs. the file it
generates):

| file | derivation source bytes | generated bytes | ratio |
|---|---:|---:|---:|
| compress | 2372 | 1925 | 1.23:1 (larger) |
| crypto | 3088 | 2485 | 1.24:1 (larger) |
| regex | 2517 | 2176 | 1.16:1 (larger) |
| base64 | 2949 | 2690 | 1.10:1 (larger) |
| json | 4844 | 4142 | 1.17:1 (larger) |
| **total** | **15770** | **13418** | **1.18:1 (larger)** |

**The honest reading: at n=5, the derivations are bigger than the code they
generate.** This is not the result I expected going in, and it's worth
being precise about *why*, because the reasons are prototype limitations,
not evidence against the mechanism itself:

1. **The free-text doc header is stored as a raw terminal, in full,
   separately from the generated output it produces.** It doesn't compress
   anything because it doesn't repeat — it's prose specific to one file —
   but it's real weight in the derivation source (531–1971 bytes per file
   above, and the derivation-source count double-pays for it: once as the
   `raw(...)` string literal, once implicitly since that's most of what
   makes derivation source exceed generated bytes for the low-tier-count
   files).
2. **Field lists are repeated 2–3 times per derivation** — once for the
   `--::` alias declarations, once for the struct type, once for the
   `M`-table construction — because this prototype passes each list as a
   fresh table literal at each call site rather than naming it once per
   file and referencing it three times. That's a real, fixable redundancy
   in *this prototype's derivation format*, not in the underlying
   mechanism: a field name and its type is one decision, used in three
   productions, and a more careful derivation encoding would say so once.
   Doing that refactor was out of scope for a first sketch but is recorded
   in `TODO.md`.

Neither of these is a property of "decisions as slot-selection" being
wrong — they're both about *how compactly this prototype's derivation
format expresses a decision*, which is a separate, fixable engineering
question. But reporting a rosy ratio without measuring it would have been
exactly the kind of unearned confidence this repo's disposition rules rule
out. The real, load-bearing claim this prototype supports is qualitative,
not a byte ratio: writing a derivation for a 6th file in this family (a
tier list, an indent choice, a variant choice, and one set of field
signatures) is a much smaller act than writing a 53-line `init.lua` by
hand, because most of the file's bytes are productions already proven to
exist. Whether that qualitative win survives contact with a properly
factored derivation format, at a scale beyond 5 files, is exactly the open
question flagged above.

## Automated induction (2026-07-28 session)

The prior section's induction was entirely by hand — a person diffing 5
files. This session built an actual induction pass and ran it, first
against the same 5 files (to check whether automation rediscovers what the
hand-induction found) and then against all of `lib/`. Read this section as
an update to, not a replacement of, everything above; the hand-induced
productions and the honesty sections above still stand.

### The representation, and the parser decision

`tooling/grammar_gen/luaparse.lua` is a new, independent Lua 5.1/LuaJIT
recursive-descent parser producing a plain nested-table AST (`{ tag =
"binop", op = "+", lhs = ..., rhs = ... }` and so on — one shape per tag,
matched at runtime).

The alternative was building on `lib/type/static/parse.lua`, crescent's
existing typechecker parser — CLAUDE.md is explicit that a second parser is
a real cost and to grep before adding one. Reading that parser settled the
question rather than leaving it as a coin flip: `lib/type/static/parse.lua`
emits flat `ASTNode` records into an FFI arena, addressed by integer index,
with node "kind" as a numeric code (`defs.NODE_*` constants) and children
reached through a paired list-pool/intern-pool, explicitly designed
("no intermediate tables" — the file's own header comment) for typechecker
throughput on a hot path. Reusing it here would mean either pulling in its
arena/intern machinery just to walk trees for shape comparison — a real
coupling cost for a tool that needs none of the typechecker's actual
concerns — or re-flattening its output back into an ordinary tree shape
before any of `canon.lua`'s canonicalization could run, at which point most
of the reuse benefit is gone anyway. `lib/type/static/parse.lua` remains
the right parser for the typechecker; it is the wrong shape for "is this
if/else the same shape as that ternary," which is this tool's entire job.
This tradeoff is not close: the two parsers serve genuinely different
consumers with genuinely different performance/ergonomics requirements, so
this session built the second parser rather than forcing one representation
to serve both.

`luaparse.lua` covers the practical Lua-5.1-plus-LuaJIT-extensions subset
`lib/` actually uses, including two things a naive Lua-5.1 grammar misses:
`0b`-prefixed binary integer literals (crescent's vendored LuaJIT fork
accepts them; confirmed by `bin/luajit -e 'return 0b0000'` succeeding) and
`ULL`/`LL`-suffixed cdata literals. Deliberately NOT covered: Lua 5.4
attribute names, bitwise operators (crescent targets LuaJIT, which has
neither; the `bit` library is used instead). Measured coverage: parses
1691/1698 `lib/` `.lua` files (99.6%); see TODO.md for the 7 known failures
and the class of syntax not yet isolated.

`tooling/grammar_gen/canon.lua` does two jobs on top of that AST:

1. **Canonicalization**: rewrites `local x = C and A or B` (ternary) and
   `if C then x = A else x = B end` (if/else, both branches a single
   same-target assignment) into one shared `cond_assign` node — a real,
   generic AST rewrite (fires on shape, not on file identity or variable
   names) rather than a hand-picked special case for the known dispatcher
   files.
2. **Fingerprinting**: a structural key that abstracts identifiers and
   literal values to placeholders (`ID`, `STR`, `NUM`, ...) while keeping
   tags, operators, and arity, so two instances of "the same production"
   collide textually. For `cond_assign` specifically, the fingerprint
   deliberately EXCLUDES the condition's own shape and the if_else-vs-
   ternary syntactic form, keeping only the coarse shape of the then/else
   branches — see `canon.lua`'s header for the full reasoning. This is the
   one modeling choice that makes the ground-truth case below pass, and
   it's stated as a choice with a named tradeoff, not asserted as free.

`tooling/grammar_gen/discover.lua` clusters occurrences (single statements,
and sliding windows of 2–5 contiguous statements within one block) by
fingerprint across an arbitrary corpus. A cluster of size 1 is residue. A
cluster of size ≥2 where every occurrence has the identical concrete
"hole" content (the abstracted-away identifiers/literals) is a **rule**
(zero variance — a pure convention). A cluster where the hole content
varies is a **slot**, and each distinct hole-tuple is a named alternative.
This is a direct, mechanical reading of the design doc's own framing:
reuse count and hole variance are read off the corpus, not asserted ahead
of time.

`tooling/grammar_gen/induce.lua` is the CLI entrypoint (the one place this
tool touches `io.*` directly, same bootstrapping pattern as
`generate.lua`): `--dispatchers` for the 5 ground-truth files, `--lib` for
the whole tree.

### Ground-truth check: does it catch the ternary/if-else case?

Yes. Running `bin/luajit tooling/grammar_gen/induce.lua --dispatchers
--verbose` and searching its single-statement output for the tier-select
ok-check shape:

```
SLOT (3 occurrences, 3 alternatives): COND_ASSIGN(NAME;CALL(1))
  alt 1 (1x): lib/compress/init.lua:20  [if_else | impl | ok | impl_raw | require("lib.compress.pure")]
  alt 2 (1x): lib/crypto/init.lua:20    [if_else | impl | ok | sys | require("lib.crypto.pure")]
  alt 3 (1x): lib/regex/init.lua:23     [ternary | impl_raw | (ok and type(mod) == "table") | mod | require("lib.regex.pure")]
```

compress's and crypto's `if/else` and regex's ternary — the exact case the
brief named as the one prior art (normalize's `--scope blocks --mode exact
--elide-identifiers`) misses because it compares AST node shapes directly
(if/else vs. ternary are different node shapes at the token/AST-shingling
level) — land in the same slot here, because `canon.lua` rewrites both into
one `cond_assign` shape before fingerprinting and the fingerprint itself
drops the condition (see above). This is the load-bearing result: the
representation is abstract enough to catch this class of equivalence.

The tool also independently rediscovered `path_bootstrap` as one slot with
the same alternative split the hand-induced grammar documents (4 files
using `"./?/init.lua"`, base64 alone using `"?/init.lua"`) — found by the
same generic single-statement fingerprinting, not hand-keyed to this
specific pattern.

What it did NOT rediscover: `type_alias_block` and `narrow_comment`. Both
live entirely inside `--:`/`--::` **comments** in the real source —
crescent's type-annotation syntax rides on top of ordinary Lua comments,
which `luaparse.lua`'s lexer discards like any other comment. A real,
significant chunk of the hand-induced grammar (the piece the design doc
calls "the closest thing to a pure convention," 100% reuse across all 5
files) is structurally invisible to an AST-only tool. See TODO.md — a
second extraction pass over raw contiguous comment blocks, classifying
line-shapes independently of the Lua AST, would be needed to close this.

### Whole-`lib/` run: real numbers

```
$ time bin/luajit tooling/grammar_gen/induce.lua --lib
files: 1698 read, 0 unreadable, 7 failed to parse, 6.73s elapsed
real    0m7.6s
-- single-statement: 2134 rules, 6205 slots, 13081 residue
-- 2-statement windows: 3662 rules, 9513 slots, 35224 residue
-- 3-statement windows: 3611 rules, 6937 slots, 45530 residue
-- 4-statement windows: 2720 rules, 4601 slots, 45761 residue
-- 5-statement windows: 1908 rules, 3260 slots, 42692 residue
```

Performance is not a concern at this corpus size: parsing, canonicalizing,
and clustering all of `lib/` (1698 files) takes under 8 seconds wall-clock
on ordinary hardware, no narrowing of scope was needed to get a result.

The `COND_ASSIGN(NAME;CALL(1))` slot — the exact tier-select shape above —
generalizes past the 3 dispatcher files at whole-corpus scale: it grows to
22 occurrences / 18 alternatives, picking up real, independent instances of
the same "use an existing value, or else compute a fresh one" idiom in
`lib/type/static-v4/`'s constraint-solving code, `lib/memoize/init.lua`'s
nil-sentinel handling, `lib/spell_check/init.lua`, `lib/css/property.lua`,
and others — a genuine mix of `if_else`-form and `ternary`-form instances,
correctly unified. `COND_ASSIGN(STR;STR)` (picking between two string
literals) shows the same pattern even more clearly: 74 occurrences across
sixty-some files spanning wildly different subsystems (`lib/cr/init.lua`'s
path separators, `lib/unified/mdast/`'s markdown AST tag names,
`lib/css_parser/init.lua`'s pseudo-selector punctuation), if_else and
ternary forms freely mixed within the same slot. This is real, structural
evidence for the design doc's core claim — a production's reuse count is a
statistical fact read off the corpus, and "conditional value assignment" is
a real production with dozens of independent instances, not an artifact of
the 5 hand-picked files.

**The honest cost of the same modeling choice**, visible only at this
scale: dropping the condition's shape to catch the ternary/if-else case
also merges instances that share nothing but branch shape. The tier-select
idiom and `lib/type/static-v4`'s constraint solver end up in the same
`COND_ASSIGN(NAME;CALL(1))` bucket despite having no real semantic kinship
beyond "assign an existing name, or else call something" — a false-positive
cost of exactly the kind the ternary/if-else fix trades for. See TODO.md.

The other large finding, also only visible at scale: single-statement
fingerprinting floods with clusters like `RETURN(ID)` (6417 occurrences,
925 "alternatives" — nearly one per distinct returned variable name across
the whole corpus). This is real, correctly-computed reuse, but it is not
"a slot with a bounded set of deliberate alternatives" in the `tier_select`
sense; it is closer to "returning a local is universal, and locals have
many names." The tool as built has no way to distinguish a slot whose
alternative-count reflects genuine design variance from one whose
alternative-count is just "how many distinct identifiers happen to exist."
Recorded as an open gap, not silently filtered — filtering it out
after the fact, tuned to make the ground-truth case look cleaner, would
have been exactly the kind of result-shaped hardcoding this project's
planning rules rule out.

**Compression ratio**: this session did not build or measure a derivation-
generator for the wider corpus (that remains the `tooling/grammar_gen/
derivations.lua` + `generate.lua` machinery, scoped to the original 5
files) — discovery and derivation-authoring are the two separable halves
the earlier section names, and this session's work is entirely on the
discovery half. The n=5 compression-ratio numbers in the section above are
therefore unchanged by this session and should not be read as validated or
refuted at scale; that remains open, tracked in TODO.md.

### What's proven vs. aspirational, updated

**Newly proven:**
- Automated induction over an independent, non-typechecker AST finds the
  same ground-truth slot (tier-select, if/else vs. ternary unified) the
  hand-induction found, via a documented, generic canonicalization rule —
  not tuned to the 5 files.
- The same induction scales to all of `lib/` (1698 files) in under 8
  seconds with no scope-narrowing, and surfaces real slot growth beyond the
  original 5-file family for the same production.

**Newly falsified / narrowed:**
- "Grammar induction itself... untested" (previous section) — now tested,
  and the answer is a genuine mix: it works for the specific ground-truth
  case, and it also surfaces two real, previously-unknown limitations
  (comment-embedded slots invisible to an AST tool; statement-shape
  fingerprinting alone doesn't distinguish meaningful design-decision slots
  from "any distinct identifier ever used here").

**Still open:** everything the prior section marked open that this session
didn't touch — derivation-format compactness, the keyring/stb looser-family
question, and compression ratio at scale — plus the new items above,
recorded in TODO.md rather than closed by assertion.

## Where this fits in crescent's docs

Filed under `docs/design/` (new directory) rather than `docs/decisions/`:
the `docs/decisions/` shape (see `metatable-representation.md`,
`why-not-external-lua-typechecker.md`) is for a ratified verdict between
named, weighed alternatives — "we evaluated X, Y, Z and chose Y, here's
why, here's what would make us revisit it." Nothing here has been decided
against alternatives; this is a first sketch that either gets built on in a
later session or doesn't. If a future session evaluates "should crescent
adopt derivation-based authoring for family F" as a real yes/no choice with
named alternatives, that's a `docs/decisions/` entry, separate from this
one.
