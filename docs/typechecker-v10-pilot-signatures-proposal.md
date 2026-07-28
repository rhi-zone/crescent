> **PROPOSAL — fable-delegation-tier, awaiting orchestrator review.**
> Every choice below marked "fable-delegation-tier" is a delegated-execution
> decision made to produce a concrete artifact for review, not a settled
> ratification — it is re-openable on challenge. One section (§4) is **not**
> a delegated choice at all: it is a substrate gap discovered by reading the
> ratified core's actual code, and this proposal deliberately stops short of
> resolving it. Implementation must not proceed past §4 without an explicit
> orchestrator decision.

# Pilot flow-narrowing signatures: program-point addressing + type vocabulary

Scope: pilot step 1+2 only (design two `declare_signature` specs). No rules,
no axioms, no replayer wiring — that is step 3+, gated on this proposal and
on §4 being resolved.

Substrate read: `docs/decisions/typechecker-v10-core-charter.md`,
`docs/decisions/typechecker-v10-core-design.md`,
`lib/type/v10_kernel/term_algebra/{init,shared,reference}.lua`,
`lib/type/v10_kernel/replayer/{registry,certificate,replay}.lua`,
`lib/type/v10_kernel/theories/hm.lua` (the one existing worked example of a
declared signature + vocabulary in the new core), `docs/typechecker-framework-postmortem.md`,
`docs/decisions/typechecker-version-history.md` (declc/Hole H1), and
`lib/type/static/{narrow,ctx_types,env}.lua` (v3, post-core reference only,
per charter item 3 — pattern lineage, not design or code authority).

---

## 1. Program-point addressing signature (`addr-v1`)

### 1.1 Design questions and choices

**Child-index encoding — Peano `nat`, fable-delegation-tier.**
Flat sorts forbid an indexed operator family (`child_0`, `child_1`, ...
would be an unbounded operator set, which `declare_signature` cannot express
and which would reintroduce exactly the kind of ad-hoc per-value special
casing the charter forbids). A single `nat` sort with `zero`/`succ` gives
unboundedly many indices from two fixed operators, at the cost of unary
size — acceptable here because child-index and lexical-depth values in real
ASTs are small (single/double digits), unlike the file-identity case below.

**File identity — content-hash-as-structural-term, fable-delegation-tier.**
Two mechanisms were enumerated per the task's explicit instruction to decide
and justify:

- **(A) Content-hash encoded as a term over a fixed finite alphabet**
  (`bit`/`bitstring` cons-list below). Fully structural: no string payload,
  no signature mutation, comparable by the kernel's existing `equal` with no
  new primitive. Same file content (same hash) ⇒ literally the same term
  after interning. Cost: a 256-bit hash is 256 cons cells — verbose but
  bounded and cheap relative to peano-encoding (see below for why peano is
  wrong here).
- **(B) An indexed 0-ary constant declared per file at prover time**
  (`declare_signature` called again per discovered file to add `file_7`,
  etc.). Rejected: `declare_signature` takes a whole spec and returns an
  immutable signature; there is no incremental "add one more op to an
  existing signature" primitive in the read code, so this would mean either
  re-declaring (and thus re-versioning) the whole addressing signature per
  file — defeating "declared once, shared by every future theory" outright
  — or accumulating file constants in one giant signature that grows across
  a run, which has no expressible closure point and reintroduces exactly
  the cross-run vocabulary-coincidence risk this design is supposed to
  foreclose (is `file_7` in run A the same file as `file_7` in run B? Only
  by accident of allocation order — the same shape as H1's "vocabularies
  never coincided," just relocated to file identity instead of claim sites).

Chose (A). Peano-`nat` was considered and rejected specifically *for the
hash* (not for child indices) because a 256-bit hash as a peano numeral is a
term of size ~2^256 `succ` nodes — not merely slow, unrepresentable. Hence
two different unbounded-value encodings for two different value shapes:
small dense counters get peano `nat`; large sparse identifiers get a
bit-list.

**Flow-point granularity — implicit `entry_of`/`exit_of` wrapping a path,
fable-delegation-tier, explicitly re-openable.** Two options:

1. **AST-node-only, implicit entry/exit operators wrapping a path.** A
   "point" is not its own free-standing sort with graph structure; it is
   exactly `entry_of(file, path)` or `exit_of(file, path)` — two 0-cost
   projections of a path. "x : T at the entry of the then-branch" is
   `entry_of(f, path_to_then_branch)`. Cost: cannot express a flow point
   that isn't in 1:1 correspondence with an AST node (e.g. a loop-back-edge
   join point, a phi-like merge after two branches recombine) — there is no
   AST path that IS such a point.
2. **Explicit `point` sort with its own successor/predecessor/join algebra**
   (a real CFG), independent of the `path` sort. Strictly more expressive —
   handles loop-carried and merge-point narrowing — at the cost of a second,
   larger algebra (join operators, path-to-point lowering, likely a
   reachability notion) that the pilot's actual target (v3's
   `narrow.lua`, confirmed by reading it: narrowing is extracted per
   `if`/`while`/`repeat` **test expression** and applied to the AST-structural
   then/else/body branches — no general CFG, no loop-carried join is
   currently modeled in v3 either) does not yet require.

Chose (1): it covers the pilot's actual target (branch-local narrowing at
if/while/repeat) with the minimum algebra, and is a strict sub-case of (2) —
upgrading later means adding a `point` sort and a lowering map, not
discarding anything built now. Flagged for reopening the moment a
loop-carried or merge-point narrowing rule is drafted.

### 1.2 Signature spec

```lua
term_algebra.declare_signature({
  name = "addr-v1",
  version = 1,
  sorts = { "nat", "bit", "bitstring", "file_id", "path", "point" },
  ops = {
    zero        = { result = "nat", args = {} },
    succ        = { result = "nat", args = { { sort = "nat" } } },

    b0          = { result = "bit", args = {} },
    b1          = { result = "bit", args = {} },
    bs_nil      = { result = "bitstring", args = {} },
    bs_cons     = { result = "bitstring", args = { { sort = "bit" }, { sort = "bitstring" } } },
    file_id_of  = { result = "file_id", args = { { sort = "bitstring" } } },

    path_root   = { result = "path", args = {} },
    path_child  = { result = "path", args = { { sort = "path" }, { sort = "nat" } } },

    entry_of    = { result = "point", args = { { sort = "file_id" }, { sort = "path" } } },
    exit_of     = { result = "point", args = { { sort = "file_id" }, { sort = "path" } } },
  },
})
```

11 operators, 6 flat sorts, zero binders (`binds` omitted everywhere —
nothing in this signature introduces object-language variable scope; that
is signature 2's concern). No string payload anywhere: file content enters
only as a bit-list built from two nullary constants.

A path denotes a location by literal descent from the chunk root:
`path_child(path_child(path_root, succ(zero)), zero)` = "child 1, then child
0 of the chunk root" (0-indexed via peano `zero`/`succ`). `entry_of`/`exit_of`
turn a bare structural coordinate into a flow point without a second sort.

### 1.3 Evaluation against the postmortem lessons + Hole H1

- **Lesson 1 (source binder names are never semantic identity).** Nothing
  in `addr-v1` carries a name at all — a path is a pure structural
  coordinate (child-index chain from root), never a source identifier.
  Directly satisfies the lesson by construction, not by discipline.
- **Lesson 2 (capture-avoidance must be checkable, not assumed).** N/A at
  this signature — no binders are declared here, so there is nothing to
  capture. (Signature 2 revisits this for variable identity — see §2.3.)
- **Lesson 3 (alpha-stable digests / identity).** A path/point built the
  same way from the same file-hash is the same interned term under the
  kernel's own `equal`/hash-consing — there is no alpha-equivalence
  question because there is no binder-introducing operator in this
  signature to rename around.
- **Hole H1 (vocabularies never coincided — `harvest_stated` vs
  `harvest_mined` vs `harvest_axiom` each spoke an unshared site/slot
  vocabulary, so cross-provenance corroboration structurally could never
  fire).** The intended counter-move is precisely "declare the addressing
  vocabulary once, as one signature object, and have every theory cite that
  same object" — two claims about "the same program point" from two
  different theories become the same interned term, comparable by `equal`
  with no translation layer, IF both theories are actually building terms
  through the same declared operator objects. **This is exactly the premise
  §4 below finds is not fully supported by the read core** — the operator
  side of this promise holds (operator identity is object+version-keyed,
  confirmed by reading `reference.lua`'s `equal`), but the *sort* side does
  not carry the same protection, and the pilot's own judgment (§2) needs to
  reference this signature's sorts from a second, separately-declared
  signature. Flagging now; resolved in §4, not here.

---

## 2. Pilot type vocabulary signature (`narrow-pilot-v1`)

### 2.1 Primitive tags

Per the task, tags matching `lua`'s `type()` classes needed for narrowing:

```
tag_nil, tag_boolean, tag_number, tag_string, tag_table, tag_function : -> prim_tag
```

Each its own nullary operator (no string payload), following the precedent
already established in the ratified core: `theories/hm.lua`'s header
explicitly records this as a named finding, not an improvised choice —
"the retired prototype's `con(name)` took an arbitrary string;
`term_algebra` operators carry no such payload field, so each concrete base
type is its own declared nullary operator instead."

### 2.2 Truthiness / falsy — one extra pair beyond the six `type()` tags

The task calls out that truthy/falsy narrowing needs `nil|false` reasoning.
`type()` alone cannot express this: `type(true) == type(false) == "boolean"`,
so a `prim_tag` vocabulary limited to the six `type()` classes cannot state
"exclude `false` but keep `boolean`" — the positive branch of `if x then`
on an `x : nil | boolean` needs to narrow to exactly the literal-true
singleton, which no combination of the six tags can express.

Chose (fable-delegation-tier): add **`tag_true` / `tag_false`** as two more
nullary `prim_tag` operators, siblings of `tag_boolean` (not a refinement of
it — flat sorts, no subsorting is a hard rule, so `tag_boolean` and
`tag_true`/`tag_false` are three unrelated tags at the grammar level; the
relationship "a value classified `tag_true` or `tag_false` is also, loosely,
a boolean" is a fact the *narrowing theory's rules* will need to state and
prove when this pilot reaches step 3, not something the term grammar
encodes). `tag_boolean` remains for "some boolean, literal unknown, not
narrowed." `falsy` is then not a new operator at all — it is the composite
`ty_union(ty_of(tag_nil), ty_of(tag_false))`, expressible from pieces
already declared below. Rejected alternative: splitting `tag_boolean`
entirely into only `tag_true`/`tag_false` with no coarse fallback — rejected
because un-narrowed boolean locals (the common case before any guard is
seen) need a representable "don't know which" type, which a strict
true/false split cannot state without a union at every unnarrowed boolean
site.

### 2.3 Union type and the judgment operator

```
ty_of    : prim_tag -> ty
ty_union : ty, ty -> ty     -- binary; n-ary unions nest, avoids variable arity
```

**Variable identity — checked against real code, not assumed.** `lib/type/static/env.lua`
was read directly: `scope.bindings[name_id] = type_id`, and `lookup`
(`env.lua:88`) walks the scope chain outward on the SAME `name_id` key —
i.e. v3's `name_id` is an **interned-name key**, reused across every scope
where that source name occurs, with shadowing resolved by *which scope
table* holds the entry, not by a stable per-declaration identity. This is
lineage evidence, not design authority (charter item 3: v3 contributes only
the abstract pattern, and its ad-hoc `ctx._foo`-style field-passing is the
documented failure mode, not something to port). Read against postmortem
lesson 1 ("binder IDs are source labels only; semantic binder identity is
lexical position") and against the fact that replay certificates must be
closed, structural, byte-offset-independent terms comparable across
separate runs — an identity that depends on "which scope-chain table you
are currently walking" does not translate into a flat term at all.

Chose (fable-delegation-tier): identify a variable in the judgment **by the
structural path to its binding site** — i.e. reuse `addr-v1`'s `path` sort
for variable identity, not a fresh de-Bruijn-style counter and not a
name/name_id. `holds_at(point, path, ty)` reads as "at this program point,
the local declared at this path has this type." This is strictly more
precise than v3's name_id (no shadowing ambiguity — a shadowed `x` in a
nested block is a different path, unconditionally) and needs no new sort:
one address vocabulary answers both "where in the code" and "which
variable," which is a cheaper and more consistent design than adding a
redundant second nat-slot mechanism (the pilot task description's own
suggested "var" as an index is answered here by "reuse the address
vocabulary" rather than inventing a second one) — but this choice is what
makes the sort-sharing question in §4 load-bearing rather than incidental:
this signature's one judgment operator needs to cite **two** sorts
(`point`, `path`) that only `addr-v1` declares.

```
holds_at : point, path, ty -> judgment
```

### 2.4 Side conditions

None are needed for this vocabulary — every guard form in scope for the
pilot (`type(x) == "..."`, bare truthiness, `x ~= nil`) reduces to
comparing/uniting `prim_tag` terms structurally; nothing requires a
side-condition slot (arithmetic range checks, numeric comparisons, etc. are
out of the stated pilot scope). Per the task's explicit instruction: if a
side condition were needed, this would be a STOP, not a workaround — noting
compliance, not inventing a mechanism that does not exist in the schema
language (`registry.lua`'s `RuleDecl`/`AxiomDecl` shapes were read directly
and confirmed to have no side-condition field of any kind).

---

## 3. Signature spec (as far as it can be written without §4)

```lua
term_algebra.declare_signature({
  name = "narrow-pilot-v1",
  version = 1,
  sorts = { "prim_tag", "ty", "judgment" },  -- + "point", "path" — see §4
  ops = {
    tag_nil      = { result = "prim_tag", args = {} },
    tag_boolean  = { result = "prim_tag", args = {} },
    tag_true     = { result = "prim_tag", args = {} },
    tag_false    = { result = "prim_tag", args = {} },
    tag_number   = { result = "prim_tag", args = {} },
    tag_string   = { result = "prim_tag", args = {} },
    tag_table    = { result = "prim_tag", args = {} },
    tag_function = { result = "prim_tag", args = {} },

    ty_of        = { result = "ty", args = { { sort = "prim_tag" } } },
    ty_union     = { result = "ty", args = { { sort = "ty" }, { sort = "ty" } } },

    -- holds_at = { result = "judgment", args = { { sort = "point" }, { sort = "path" }, { sort = "ty" } } },
    -- ^ cannot be declared as written: "point" and "path" are not in this
    --   signature's own `sorts` list, and declare_signature validates every
    --   operator's argument sorts against ITS OWN sorts set only (confirmed
    --   by reading shared.lua's declare_signature — see §4).
  },
})
```

This spec is **not committable as-is** — the commented-out `holds_at`
operator is the crux of §4.

---

## 4. Open substrate gap — NOT resolved here, escalation required

**This is a finding from reading the ratified core's actual code, not a
design preference, and it blocks committing a working `holds_at` operator.**

`shared.lua`'s `declare_signature` (read in full) validates every operator's
`result`/`args[i].sort`/`binds[j]` strings against `sorts[s]`, a table
built **only from this one spec's own `sorts` list** (`shared.lua:59-64`,
checked at `:76` and `:101`/`:114`). There is no `imports`/`extends`/`uses`
field in `SignatureSpec` (confirmed against the type comment in both
`term_algebra/init.lua:49` and `shared.lua:27` — identical, both list
exactly `{ name, version, sorts, ops }`). So **an operator in one
signature cannot declare an argument of a sort that only another,
separately-declared signature owns** — there is no cross-signature sort
reference mechanism in the read API.

Separately, `reference.lua`'s `equal` (read in full) shows an asymmetry
between how the kernel protects *operators* versus *sorts*:

- **Operator identity is protected**: `equal` on two `op` nodes checks
  `a.decl ~= b.decl` (Lua object identity) — "same-named ops in different
  signatures are different operators" is enforced by the kernel itself, not
  by convention (`reference.lua:140`).
- **Sort identity is not protected at all**: a term's `.sort` field is a
  bare Lua string, set at construction (`build_var(index, sort)` takes a
  raw string, not a signature-scoped object). `build`'s sort check
  (`reference.lua:94`, `term.sort ~= argdecl.sort`) and `equal`'s var/meta
  comparison (`reference.lua:134`, `137`, `a.sort == b.sort`) are both bare
  string equality, with **no notion of which signature declared that sort
  name**. If two independently-declared signatures each declare a sort
  literally named `"point"`, the kernel cannot distinguish them — a
  `point`-sorted term from either would mechanically pass every `build`/
  `equal` check that asks for sort `"point"`, whether or not the two
  signatures' authors intended any relationship at all.

This is structurally the same failure shape as Hole H1 — "vocabulary
coincidence never actually checked, only assumed by naming convention" —
just inverted: H1 was corroboration failing to fire because vocabularies
*didn't* coincide when they should have; this is the risk of corroboration
*silently firing* because two unrelated sorts *happen* to share a name,
with nothing in the kernel able to tell the difference. Given that the
whole point of declaring `addr-v1` once was "comparable across theories by
construction," and given `narrow-pilot-v1`'s only judgment needs to cite
`addr-v1`'s `point` **and** `path` sorts (§2.3), this pilot cannot be
built as two genuinely independent, safely-composable signatures without
either forfeiting the independence requirement or accepting an unenforced
convention. Options, not chosen among here:

- **(A) Merge**: declare one signature containing both `addr-v1`'s ops and
  `narrow-pilot-v1`'s ops. Works today, zero kernel changes. Forfeits
  "declared once, shared by every future theory" as an independent,
  separately-reusable object — a second future theory wanting addressing
  (say, a purity/effects pass) would have to either re-declare its own copy
  of `path_child` etc. (a *different* operator object per the identity
  rule above, so its path terms would never `equal`-compare with the
  narrowing theory's, even for the literal same AST location — silently
  reintroducing H1 at the operator level between the two theories) or
  physically depend on `narrow-pilot-v1` itself (coupling an unrelated
  theory to the narrowing pilot).
- **(B) Two signatures, shared sort name by convention**: keep `addr-v1`
  and `narrow-pilot-v1` separate, have the latter declare `point`/`path` in
  its own `sorts` list under the same string names. Mechanically accepted
  by `build`/`equal` today (verified above). The interoperability is real
  *in practice* as long as every theory that needs addressing consistently
  spells the sort names `"point"`/`"path"` the same way — but this is
  discipline, not a kernel-checked invariant, and is the exact class of
  reliance-on-accidental-coincidence the operator-identity design was
  explicitly built to rule out on the operator side. Silent failure mode:
  a typo, a version bump, or an unrelated theory's unrelated `"point"` sort
  would not be caught structurally.
- **(C) Kernel extension**: give sorts the same identity protection
  operators already have — e.g. a sort is `(sig_name, sig_version, name)`,
  and `SignatureSpec` grows an explicit, declared cross-signature sort
  import so consuming a `point` from `addr-v1` inside `narrow-pilot-v1` is
  a checked citation, not a string match. This is the principled fix and
  the one that actually delivers "declared once, shared by every future
  theory, comparable by construction" as stated — but it is new v10 core
  substrate (a change to the ratified `declare_signature` contract), not a
  pilot-signature design choice, and is out of this proposal's authority
  to decide or build.

No option is picked here. This is presented as a genuine, code-verified
open question for the orchestrator: whether to accept (A)'s scope
reduction, (B)'s unenforced convention (explicitly against the spirit of
the H1 counter-move this pilot exists to test), or schedule (C) as
substrate work before the pilot's `holds_at` operator can be committed as
designed in §2.3. Per "substrate before consumers": if (C) is the intended
answer, it should be scheduled and ratified before, not discovered inside,
narrowing-rule implementation.

---

## 5. Summary table

| Signature | Sorts | Operators | Status |
|---|---|---|---|
| `addr-v1` | `nat, bit, bitstring, file_id, path, point` | `zero, succ, b0, b1, bs_nil, bs_cons, file_id_of, path_root, path_child, entry_of, exit_of` (11) | Committable as written — no cross-signature dependency |
| `narrow-pilot-v1` | `prim_tag, ty, judgment` (+ `point, path` pending §4) | `tag_nil, tag_boolean, tag_true, tag_false, tag_number, tag_string, tag_table, tag_function, ty_of, ty_union` (10) + `holds_at` blocked | **Not committable** — `holds_at` needs §4 resolved first |

## 6. Fable-delegation-tier choices (re-openable on challenge)

1. Peano `nat` for child indices and (via reused `path`) declaration-site
   addressing depth; bit-list, not peano, for file-content-hash identity.
2. Content-hash-as-structural-term for file identity (over per-run indexed
   constants).
3. Implicit `entry_of`/`exit_of` over an explicit CFG `point` sort, scoped
   to the pilot's actual target (branch-local, non-loop-carried narrowing).
4. `tag_true`/`tag_false` added alongside `tag_boolean` as flat siblings
   (not a refinement) to make falsy/truthy narrowing expressible.
5. Variable identity = structural path to binding site (reusing `addr-v1`'s
   `path` sort), rejecting v3's interned-name_id convention as lineage-only,
   not design authority.

## 7. What genuinely could not be decided without new substrate

§4 in full: whether `narrow-pilot-v1` may safely cite `addr-v1`'s `point`
and `path` sorts, given the read core provides object-identity protection
for operators but only bare-string equality for sorts. This blocks
committing a working `holds_at` operator and therefore blocks step 3 (rules
over this vocabulary) until the orchestrator picks among (A)/(B)/(C) above
or directs a different resolution.
