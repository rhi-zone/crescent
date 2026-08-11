# Datapack-style layer: purely declarative, no-code reconfiguration

**Status: DESIGN PROPOSAL — not committed, not built, awaiting owner sign-off.**
Everything below is a proposal for review, per `docs/genre-battery-design.md`'s
distinction between owner-directed settled direction and undecided design
questions. Nothing in this document should be read as a decision; it presents
options and tradeoffs for the owner to choose among (or reject outright).

## Relationship to sibling work

This document was commissioned alongside a parallel design effort for a
Factorio-style structured data-merge library, intended to land at
`docs/genre-battery/data-merge-lifecycle.md`. That sibling document did not
exist at the time this one was written (verified: the directory was empty
before this file was added). The two are named in
`docs/genre-battery-design.md`'s "Mod-loader shape" section as **separate,
distinct paradigms** — not a single mechanism with two frontends:

- **Factorio-style data-merge** — full prototype authorship. Mods can define
  brand-new item/entity/recipe *types*, merged field-by-field across a staged
  `data.lua` → `data-updates.lua` → `data-final-fixes.lua` lifecycle, with
  conflict resolution intrinsic to the merge.
- **Minecraft-datapack-style (this document)** — reconfiguration only. A
  datapack can change the recipe for an existing item, add a new loot table
  entry to an existing table, tweak drop chances — but cannot mint a type the
  base system doesn't already know about. This is the source of datapacks'
  comparative stability in Minecraft (`docs/genre-battery-design.md`,
  "Minecraft (Forge/Fabric vs. datapacks)": "Mojang keeps both because
  datapacks structurally can't add new block/item/entity types").

Section 3 below evaluates whether this layer should be a restricted
application mode over the *same* frozen prototype table the data-merge
library would produce, or a structurally separate mechanism. Because the
sibling design doesn't exist yet, this document can't verify what shape that
prototype table takes — Option A in Section 3 is written contingent on that,
and flagged as blocked pending the sibling doc, not resolved here.

## Existing substrate — grep findings

Searched `lib/` for a config-loading, schema-validation, or datapack-shaped
layer already partway to this design, per the task's request.

**Nothing already does this job.** What exists, and how it relates:

- **`lib/schema_validator`** — a Zod-style chainable schema builder
  (`string()`, `object({...})`, `.min()`, `.strict()`, etc.) with
  `schema:parse(data)` / `schema:safe_parse(data)` returning issues with
  `path`/`message`/`type`. Pure Lua tier (`M._tier = "pure"`). This is a
  strong candidate *building block* for Section 2's schema/validation model —
  it already has the "reject unknown fields" primitive (`.strict()`) that the
  "no new types" safety property needs. It has no concept of datapacks,
  recipes, or game data; it's a general-purpose value validator.
- **`lib/schema_gen`** — JSON Schema inference/generation/validation
  (`M.infer`, `M.validate`, DSL constructors). Another general-purpose
  validation candidate, JSON-Schema-shaped rather than Zod-shaped. Two
  independent schema-description approaches exist in the repo already
  (Zod-style vs. JSON-Schema-style) — worth the design owner picking one
  rather than introducing a third for this layer.
- **`lib/env_schema`** — typed environment-variable validation
  (`M.string(opts)`, `.validate(raw)` → `(value, errmsg)`). Same
  `(value, errmsg)` convention this layer needs; narrow to env vars, not
  reusable as-is, but confirms the convention pattern to follow.
- **`lib/pkg/config.lua`** — loads a **trusted, first-party** Lua file
  (`loadfile` + `pcall`) as user config for the package manager. This is the
  closest thing in the repo to "load a Lua table as data," but it is the
  opposite trust model from what this layer needs: it executes arbitrary Lua
  from a config the *user* controls locally, with no schema check against a
  base system's known fields/types. Not reusable for a mod-content channel
  where the loaded file may come from an untrusted third-party mod.
- **No mod-loader, no prototype/recipe/loot-table system, no "datapack"
  anything** exists anywhere in `lib/`. This is confirmed greenfield, matching
  `docs/genre-battery-design.md`'s gap map (Minecraft: "Inventory/items and
  crafting/recipes are flat gaps — no library found").

Conclusion: this library has no existing partial implementation to extend.
`lib/schema_validator` (or `lib/schema_gen`) is the natural dependency for
Section 2's validation model — build on one of them, don't hand-roll a third
schema mechanism.

## 1. Format: JSON, or a restricted Lua-table format?

Minecraft's datapacks are JSON because Minecraft's engine is Java and
embedding a full scripting language purely to read config data would mean
building and sandboxing an entire interpreter layer for content that should
never need general computation. JSON's safety property in that context is
almost accidental: it's safe because it has no functions, not because Mojang
designed a safety property into it deliberately — a data-interchange format
that happens to have no code in it.

Crescent's situation is different in the one way that matters here: **Lua is
already the host language.** `loadfile`/`load` on a `return { ... }` literal
is a one-line trusted-config pattern already in use (`lib/pkg/config.lua`).
The question is real, not a rhetorical setup for "just use JSON" — Crescent
is Lua-native, so a Lua-table format is at least worth naming as a live
option, per the task's instruction not to assume JSON by default.

The two candidates and what each actually buys:

### Option A: JSON

- **Safe by construction, not by discipline.** A JSON parser cannot execute
  code — full stop, no matter how the parser is implemented or what happens
  to run afterward. There's no `load`/`loadstring` step in the pipeline at
  all, so there's no sandboxing surface to get right. This is a strictly
  stronger safety property than "restricted Lua, validated after parse,"
  because it holds regardless of validator correctness.
- Crescent already has JSON tooling to build on (grep confirms JSON-adjacent
  work exists — `lib/openapi`, `lib/schema_gen`'s JSON-Schema output — a
  canonical JSON parser is assumed available per `docs/conventions.md`'s
  "one canonical parser per format" rule; this document doesn't re-verify
  which library owns it, since Section 2's validator dependency is the more
  load-bearing choice here).
- Cost: JSON is not Lua-native. Datapack authors write in a syntax
  disconstant with the rest of the ecosystem (no comments, no trailing
  commas, string keys only, no distinguishing int/float ambiguity cleanly).
  For a Lua-native ecosystem this is a real authoring-ergonomics tax, paid on
  every datapack file, forever.
- This mirrors Minecraft's actual reasons least well of the two options —
  Minecraft picked JSON to *avoid needing a scripting sandbox at all*, and
  Crescent already has one (Lua) it can't avoid having regardless, since
  control-stage code is plain sandboxed Lua per
  `docs/genre-battery-design.md`.

### Option B: restricted/validated Lua-table format

A file that is *read*, never executed with ambient capability — e.g. loaded
via `load(src, chunkname, "t", restricted_env)` with an environment that has
no globals at all (not even a restricted subset — zero), so the only thing
the chunk can do is construct and `return` a literal table. Any attempt to
call a function, index a global, or do anything beyond table/literal
construction fails at load time because the name doesn't exist in the
environment.

- **Idiomatic to the ecosystem.** Datapack authors write plain Lua table
  literals — comments, trailing commas, local variables for repeated
  sub-structures within one file, `..` for string building at author-time
  (not runtime) — all the ergonomic wins of the host language, with none of
  JSON's syntax friction.
- **Safety property is real but conditional**, not unconditional the way
  Option A's is. It depends on: (a) `load` being called with `"t"` mode
  (text-only, blocks bytecode — bytecode is a known Lua sandbox-escape
  vector since a crafted bytecode chunk can violate invariants a text parse
  can't), and (b) the environment table genuinely having zero ambient
  capability, not merely a "restricted" table that happens to still expose
  `pairs`/`pcall`/metatables an attacker could pivot from. Every one of these
  is a place a future edit could reintroduce a hole without it being obvious
  from the call site — the safety property lives in how the loader is built,
  not in the format itself the way JSON's does.
- Still fundamentally different from — and much narrower than — the
  control-stage sandboxing problem `docs/genre-battery-design.md` leaves
  explicitly open ("Explicitly open questions": what does 'sandbox it
  properly' mean concretely for control-stage Lua). Control-stage sandboxing
  needs to support *general computation* safely (loops, conditionals,
  function calls, resource limits) — a much harder problem. This layer needs
  to support *no computation at all* — closer to "does this file merely
  construct data" than "is this code safe to run." Getting the narrower
  property right (zero-capability load environment, text-only mode) is
  tractable in a way the general control-stage sandbox is not, but it is
  still a mechanism to build and verify, not a free consequence of using Lua
  syntax.
- If Crescent ever needs the general control-stage sandbox for other reasons,
  this layer's restricted loader is *not* a stepping stone toward it — it's
  deliberately closer to zero than to "restricted but Turing-complete." Don't
  conflate the two mechanisms even though both involve `load`.

**This is a genuine open design choice, not a preference to be assumed.**
Named tradeoff, not resolved here: Option A's safety is unconditional and
free of an ecosystem-specific mechanism to get right, at the cost of syntax
friction foreign to a Lua-native codebase. Option B is idiomatic and
ergonomic, at the cost of the safety property being conditional on a loader
mechanism (`load(..., "t", zero_cap_env)`) that must be built once, verified
carefully, and never silently weakened in a later edit — the kind of thing
`CLAUDE.md`'s "no special-casing" and "substrate before consumers" rules
would want built as real, auditable substrate rather than assumed safe by
association with "it's just Lua."

A third sub-option exists and is named for completeness, not endorsed:
Option B could still forbid `load()` entirely and instead require the
datapack file be data-only in a stricter sense — e.g. authored as nested Lua
table constructors with only literals (numbers, strings, booleans, nested
tables) as values, checked by walking the *parsed* AST (via Crescent's
existing Lua parser, if `docs/conventions.md`'s "canonical parser per format"
rule has one) rather than by executing it at all. This would make Option B's
safety property unconditional like Option A's (no `load` call exists in the
pipeline, so there's no environment-capability question to get right) while
keeping Lua-native syntax. Not evaluated in depth here — it depends on
Crescent having a Lua AST parser already usable for this (unverified in this
pass), and it's a meaningfully different implementation shape (parse-and-walk
vs. load-and-restrict) that the owner may want named as a fourth quadrant
rather than folded into B.

## 2. Schema / validation model

The core safety property this whole layer exists to provide is: **a datapack
can only reference fields and values the base system already declared it
understands.** Unknown fields, unknown value types, and unknown top-level
categories (e.g. a `"widget"` key when the base system only knows `"recipe"`
and `"loot_table"`) must all be rejected before the datapack is applied —
not warned about, not ignored-and-passed-through, rejected.

Proposed shape, contingent on Option A/B above being settled first (both
options below can implement whichever format wins):

- Each *system* that wants to be datapack-configurable (recipes, loot
  tables, ...) registers a schema describing exactly the shape of a valid
  reconfiguration entry for that system — using `lib/schema_validator`'s
  `.strict()` object mode (rejects unknown keys) as the enforcement
  primitive, or `lib/schema_gen`'s JSON-Schema validator if the owner prefers
  that description style (see the grep findings above — pick one, don't add
  a third).
- A datapack file declares which system it targets (e.g. a `kind` or `type`
  field naming a system that must already be registered) and a body that is
  validated against that system's registered schema.
- **No new `kind` can be invented by a datapack.** The set of valid `kind`
  values is exactly the set of systems the base game/mod-loader registered
  schemas for at data-merge time (or at build time, depending on where this
  layer sits relative to the data-merge lifecycle — see Section 3). This is
  the literal enforcement point of "no new types the base system doesn't
  already know about."
- Validation happens **before** any merge/apply step touches the target
  system's live data — reject-first, never partially apply then roll back.

This is a design sketch, not a spec — the exact registration API
(`M.register_schema(kind, schema)` or similar) is left unnamed pending the
Option A/B format decision, since the registration call's shape depends on
whether schemas validate a parsed JSON tree or a loaded-and-restricted Lua
table.

## 3. Application model: same frozen prototype table, or separate mechanism?

Two real options, genuinely open, contingent on the sibling data-merge
lifecycle document (not yet written) for what shape its "frozen prototype
table" even takes:

### Option A: merge into the same frozen prototype table

The data-merge lifecycle (Factorio-style, sibling doc) produces some frozen
structure after its staged `data.lua`/`data-updates.lua`/`data-final-fixes.lua`
passes — call it the prototype table. Under this option, a datapack-style
file is a *restricted mutation* against that same table: it can only touch
fields the schema for that prototype's `kind` already declares, using the
same underlying merge/patch primitive the data-merge library itself uses
internally, just gated by a strict schema instead of arbitrary mod code.

- **Pro:** one source of truth for "what recipes/loot tables exist," no
  risk of the two layers disagreeing about the current state of a prototype.
  A mod author could plausibly use either mechanism against the same data
  without the two fighting.
- **Con:** couples this library's implementation directly to the sibling
  library's internal table shape and merge primitive — a shape that doesn't
  exist yet (the sibling doc hadn't been written at time of this document).
  Building Option A now means designing against an unverified, possibly-
  changing target. This is the kind of ordering problem `CLAUDE.md`'s
  "substrate before consumers" planning rule flags directly: this layer
  would be a consumer of the data-merge library's prototype-table substrate,
  and that substrate isn't built or even designed yet.

### Option B: separate, narrower mechanism

This layer maintains its own restricted store — a table of
"known systems and their current reconfigurable state" — populated by
whatever registers each system (which may itself be informed by, but is not
the same table as, the data-merge lifecycle's output). Datapacks apply
against this narrower store; the "real" prototype table used by control-stage
code either reads through this store or is synced from it by a small
explicit adapter that either mechanism's maintainer writes when the two
libraries are actually combined.

- **Pro:** buildable and testable in complete isolation from the sibling
  library, regardless of the sibling's design or even its existence. Matches
  `docs/genre-battery-design.md`'s "What this reframing leaves open" note
  that cross-paradigm composition "is discovered at point of use, not
  adjudicated up front: two paradigm libraries either compose cleanly or
  they don't, and that's found out when someone actually combines them in a
  genre core" — i.e. the owner has already rejected pre-adjudicating this
  exact kind of composition question in the abstract.
- **Con:** if a genre core does want both mechanisms live against the same
  game, something has to reconcile two views of "current recipe for iron
  gear" — a real integration cost deferred, not eliminated.

**Recommendation for a decision path, not a decision:** Option B is the only
one of the two that doesn't block on an as-yet-unwritten sibling document.
Building Option A now would mean guessing at the sibling's prototype-table
shape — exactly the kind of guess `CLAUDE.md`'s disposition rules forbid
("Guessing is forbidden, full stop... unless the user has explicitly asked
for speculation"). If the owner wants Option A's tighter integration, the
sequencing implied is: sibling doc lands and gets signed off → this
document's Option A gets revisited against the sibling's actual shape →
implementation. This document does not decide which of A/B the owner wants;
it names that the sibling's non-existence is a real blocker specifically for
A, not for B.

## 4. Error handling

Follows `docs/conventions.md` exactly — no library-specific exception here:

- Malformed file (bad JSON syntax under Option A; a Lua chunk that fails to
  load, or that the zero-capability environment traps, under Option B) →
  `(nil, errmsg)` from the parse step. Never throw.
- Well-formed but schema-violating (unknown field, unknown `kind`, wrong
  value type for a known field) → `(nil, errmsg)` from the validate step,
  with the error message identifying the offending path (mirroring
  `lib/schema_validator`'s `Issue = { path, message, type }` shape, or
  equivalent) — a mod author debugging a rejected datapack needs to know
  *which* field, not just that validation failed somewhere in the file.
- Valid datapack whose target `kind`/prototype doesn't exist in the
  currently-registered system set (e.g. a recipe patch naming an item ID no
  registered recipe system knows about) → `(nil, errmsg)`, not a silent
  no-op. Silent no-ops on a bad reference are exactly the kind of thing that
  produces "why didn't my datapack do anything" bug reports with no signal.
- No partial application: if a datapack file contains multiple entries and
  one fails validation, none of them apply. (This is stated as the
  conservative default consistent with "reject-first, never partially apply
  then roll back" in Section 2 — whether per-entry partial application is
  ever desirable is a product question the owner may want to weigh in on
  later; not assumed settled here.)

## Design options summary (2-3 concrete options, no forced winner)

Combining Sections 1 and 3's independent axes, three concrete top-level
designs, named for reference:

1. **JSON + separate store** (Option A format + Option B application). Safety
   unconditional (no `load` anywhere in the pipeline), buildable today with
   zero dependency on the sibling data-merge doc. Authoring ergonomics are
   JSON's, not Lua's. Lowest risk, least idiomatic.
2. **Restricted Lua-table + separate store** (Option B format + Option B
   application). Idiomatic authoring, buildable today independent of the
   sibling doc. Safety property is conditional on a carefully-built
   zero-capability `load` environment (or, per the Section 1 sub-option, an
   AST-walk-only loader that removes even that condition) — real mechanism
   to design and verify, not assumed by "it's just Lua."
3. **Either format + same-prototype-table merge** (Option A of Section 3).
   Tightest integration with the sibling data-merge library, but blocked on
   that library's design landing first — not buildable in isolation today.
   Named for completeness; not a near-term option regardless of which format
   wins, given the sibling doc doesn't exist yet.

No winner is named. Format (Section 1) and application model (Section 3) are
independent axes the owner can decide separately; the three numbered designs
above are illustrative combinations, not the only three combinations
possible.
