# Abstract kernel — SUBTRACT candidate (2026-07-05/06)

Frame: fewest moving parts. Find the one primitive that makes the special
cases stop being special, then stop subtracting the instant soundness or
computability would break.

## 0. What gets thrown out, and why

The existing `lib/declc/{claim,kernel,check}.lua` fixes, inside the trusted
core: five named claim fields (`site`, `slot`, `stratum`, `modal`,
`schema_key`), a three-member enum of `provenance`, and a grouping function
(`topic_key = stratum⊕modal⊕site⊕slot`) that decides which claims are
"about the same thing." `first-slice-run.md` shows the consequence: the
grouping function is itself a claim-form commitment (a fixed addressing
scheme), and it is *wrong* — `stated`'s site format
(`file:def_line:funcname`) and `mined`'s (`file:line`) never collide, so
100% of 2401 claims came back Open not because nothing could be corroborated
but because the kernel's own hardcoded notion of "same topic" could never
fire. That is a special case (a fixed claim vocabulary) masquerading as
kernel machinery. It has to go, entirely — not be patched with a better
string format.

The question this frame asks: once you remove that, what is the smallest
thing left that the one law (`declarative-design.md`, owner-certified) can
still be checked against?

## 1. The design

### 1.1 Reduction chain

Start from the one law: *a claim used as a hypothesis must independently
survive as an obligation.* Ask at each step whether the kernel needs to
understand the concept to make the law checkable, or whether it can be
pushed to an untrusted producer.

1. **Does the kernel need "claim" as a typed, field-ful thing (site, slot,
   stratum, modal, schema)?** No. The kernel never needs to know *what* a
   claim asserts. It only ever needs to know **which pool entries some
   producer says bear on which other pool entries, and how**. Claim content
   becomes fully opaque payload.
2. **Does the kernel need a fixed notion of "same topic" (equality/grouping
   over claims)?** No — and this is the exact bug above. Sameness-of-topic
   is not a kernel concept at all; it is replaced by producers *naming*
   pool-entry ids directly in a derivation edge. Nothing is grouped by a
   hash of hardcoded fields; a rule says "entry 41 and entry 88, taken
   together, bear on entry 12" by id, not by a topic-key collision.
3. **Does the kernel need a fixed set of "generation sources" (stated /
   axiom / mined)?** No. Source becomes an opaque reporting tag on the
   payload, exactly like credence — the certified "grade axis: operationally
   inert" finding already established this for credence; the same argument
   applies to provenance once corroboration is rule-mediated rather than
   population-counted (§1.3 below explains why the anti-gaming role
   provenance used to play is no longer needed).
4. **Does the kernel need to interpret whether a derivation step is
   correct?** No — and it must not, or it re-acquires a fixed semantics.
   It needs only to **re-execute**, under a fuel bound, a pure function the
   producer supplies, and believe the boolean that function returns *when
   the kernel itself computed it* — not when the producer merely reports it.
   This is the one place "self-carried semantics" lives (kill-test 2).
5. **Does the kernel need "hypothesis" and "obligation" as two different
   kinds of thing?** No — they collapse into a single graph fact: *X is used
   as a premise of Y's derivation*, and the law becomes a property of the
   graph (no id may be proved via a path that runs back through itself) —
   pure acyclicity, a standard, cheap, fully general, content-free check.
6. **Does the kernel need three-valued verdicts as a separate concept from
   the graph?** No — Proved/Refuted/Open fall out as the (restricted)
   well-founded model of the edge set: refute-edges dominate, everything
   unreached is Open. This is the one place the certified formulation is
   *not* subtracted — three-valued verdicts and mutual-consistency are
   owner-certified, not a claim-form choice, so they stay fixed.

What's left, irreducibly:

- **Pool**: an append-only set of opaque handles (ids) with opaque payload.
  Nothing else. (Removing this breaks reference: there would be nothing for
  a derivation edge to point *at*.)
- **Edge** (a "certificate"): `(rule, premises: {id}, target: id, polarity)`
  where `polarity ∈ {supports, refutes}` — the *only* fixed vocabulary
  surviving in the kernel, because it *is* the certified law/verdict shape,
  not a claim form. `rule` carries a pure, deterministic `check(premise
  payloads, target payload) -> boolean` the kernel itself executes under a
  step budget. (Removing polarity breaks the law: without a fixed notion of
  "this discharges vs. this contradicts," Refuted cannot be distinguished
  from Proved and mutual-consistency checking is not expressible.
  Removing re-execution breaks kill-test 2: the kernel degrades to trusting
  a producer's say-so, i.e. string comparison with extra steps.)
- **Acyclicity check** at edge-admission time (graph-structural, O(edges)
  amortized with a union-find / DFS check). (Removing it breaks the one
  law: a rule with `premises = {target}` — or any premises path back to
  target — would let a claim prove itself, which is exactly "assume what
  you never check.")
- **Closure**: monotone least fixpoint over `supports`/`refutes` edges,
  refute-dominant, terminating because the edge set submitted in one run is
  finite. (Removing it means verdicts are just "whatever the last edge
  said" — not a fixpoint, so a claim proved via a long chain of premises
  never gets to be Proved; the closure is what makes "independently survive
  as obligation" transitive rather than one-hop.)

Everything else — what a claim *is*, what a rule *means*, how sites/slots/
scopes/functions are addressed, what counts as an axiom, how mined beliefs
are catalogued (H5), how the operational semantics gets consulted (H1), how
◇-claims get refuted (H3), whether a claim is single-trace or a
hyperproperty over trace pairs (H4) — is producer-side. None of it is named
in the kernel. A rule's `check` function can be as rich as "run a real
interpreter over a real trace" or as thin as "string equal" — the kernel
cannot tell and does not try to; that grading is an *engineering* discipline
(parity-test each rule against the real semantics, per CLAUDE.md's
multi-tier-implementation rule), not a kernel property.

### 1.2 Why provenance/source drops out of the kernel

The old design used "≥2 distinct provenances agree" as its corroboration
rule, which does two jobs at once: (a) it is *itself* a specific,
one-among-many derivation strategy (cross-source agreement, a cheap proxy
for "really derived"), and (b) it defends against a producer trivially
"self-corroborating" by emitting the same claim twice.

In the graph model, (a) is now just one possible *rule* a producer can
register (see §2.2 realization example) — not baked into the kernel. And
(b) stops being a distinct concern: duplicate submission of the same edge
is idempotent (a graph has at most one edge per (rule, premises, target,
polarity) tuple; resubmitting it doesn't add "more" corroboration, because
Proved is a reachability fact, not a vote count). The only real
attack surface left is a dishonest *rule* (`check` that returns `true`
unconditionally with zero premises) — which is unfixable by the kernel in
principle (see §4), but is exactly as unfixable in the old design (a
dishonest harvester could always emit two colluding claims from two
"different" provenance tags too). Subtracting provenance from the kernel
loses nothing the old design actually defended against; it only removes a
field the kernel never needed to branch on.

### 1.3 The one surviving fixed vocabulary, named explicitly

`{Proved, Refuted, Open}` and `{supports, refutes}` (which collapses to the
same two-valued distinction restated at edge-level vs. pool-level). That's
it. This is deliberate: the owner certified three-valued verdicts and
mutual-consistency as the *law*, not as a claim form — subtracting it would
mean re-litigating something already settled, not tightening the kernel.

## 2. Concrete realization

### 2.1 Kernel interface (Lua-shaped sketch)

```lua
-- lib/declc/kernel.lua (redesigned)

--:: Id = unknown          -- opaque handle, kernel-minted, never introspected
--:: Payload = unknown     -- fully opaque to the kernel
--:: Polarity = "supports" | "refutes"   -- the one surviving fixed vocabulary

--:: Rule = {
--::   id: string,          -- name/version, for external audit -- NOT interpreted by kernel
--::   fuel: integer,       -- step budget for this rule's check
--::   check: (premises: { [integer]: Payload, ... }, target: Payload) -> boolean,
--:: }

--:: Pool = unknown   -- opaque handle to kernel-internal state

--: () -> Pool
function M.new_pool() ... end

-- Admits one opaque fact. No shape requirement on payload -- a producer may
-- put a type annotation, an AST fragment, a trace, a string, anything.
--: (Pool, Payload) -> Id
function M.admit(pool, payload) ... end

--: (Pool, Id) -> (Payload | nil, string | nil)
function M.payload(pool, id) ... end

-- Submits one derivation step. The kernel:
--   1. checks target and every premise id are real pool members
--   2. checks target is not reachable FROM target through the premises
--      (adding this edge, would this create a cycle in the standing edge
--      graph?) -- this is the hypothesis/obligation law, made structural
--   3. re-executes rule.check itself, under rule.fuel, in a stripped
--      environment (no ambient globals, no caps -- pure-function
--      discipline enforced the same way the rest of this codebase enforces
--      caps-first: nothing is reachable from inside check() that was not
--      explicitly passed in)
--   4. only if check() returns true AND the acyclicity test passes does the
--      edge get added to the standing graph
--: (Pool, Rule, premises: { [integer]: Id, ... }, target: Id, Polarity) -> (boolean, string | nil)
function M.submit(pool, rule, premises, target, polarity) ... end

--:: Verdict = "proved" | "refuted" | "open"

-- Computes the restricted well-founded model: monotone least fixpoint over
-- supports-edges (a target is Proved iff some accepted supports-edge
-- targets it whose every premise is itself Proved), refutes-edges dominate
-- (a target with any accepted refutes-edge whose premises are all Proved is
-- Refuted, regardless of any competing supports-edge), everything else is
-- Open. O(edges + ids) via standard fixpoint iteration -- always
-- terminates because the edge set submitted in one run is finite.
--: (Pool) -> { [Id]: Verdict, ... }
function M.close(pool) ... end
```

Note what's absent relative to the current `kernel.lua`: no `Claim` type, no
`stratum`/`modal`/`site`/`slot`, no provenance enum. `Rule.check` is the only
place domain content is touched, and it is producer-authored, not kernel
code.

### 2.2 One producer, realizing corpus instance 1

`lib/lru/init.lua:155`, `deref:self` inside `function Cache:peek(key)` — the
first "obviously decidable" instance from `first-slice-run.md`. Two
independent producers, neither aware of the other's addressing scheme
(directly answering the H1-wall finding: no shared site/slot vocabulary is
required, because nothing groups by topic-key anymore):

```lua
-- producer A: the existing mined-belief harvester, unchanged in spirit,
-- admits an opaque payload -- no forced field shape.
local self_deref_id = kernel.admit(pool, {
  kind = "presupposition", claim = "non-nil",
  file = "lib/lru/init.lua", line = 155, expr = "self",
})

-- producer B: a small new fact-miner over function definitions (this is
-- new *library* code, not kernel code) admits a structural fact about how
-- the enclosing function was defined.
local colon_def_id = kernel.admit(pool, {
  kind = "def-form", file = "lib/lru/init.lua", def_line = 154,
  form = "colon", receiver_param = "self",
})

-- producer C (could be the same author as B, or a third party -- the
-- kernel doesn't care) registers a RULE and submits the edge:
local colon_self_nonnil = {
  id = "colon-self-nonnil-v1",
  fuel = 200,
  check = function(premises, target)
    local def = premises[1]
    -- real inference: Lua's `:` calling convention guarantees the first
    -- implicit parameter is bound to a non-nil value whenever invoked via
    -- `:`. This function LOOKS at both payloads; it is not a string
    -- comparison of topic keys.
    return def.form == "colon"
      and def.receiver_param == target.expr
      and target.claim == "non-nil"
  end,
}

local ok, err = kernel.submit(pool, colon_self_nonnil,
  { colon_def_id }, self_deref_id, "supports")
```

`colon_def_id` itself needs a base case to resolve Proved rather than Open:
a producer submits a zero-premise edge for it, backed by a rule whose
`check` asserts "this payload's `form`/`def_line` were read directly off
the parse tree" (a fact about the parser, not about program behavior) —
that rule is exactly what an "axiom" is in this design: not a kernel
concept, just a rule with no premises whose honesty is established once,
externally (a unit test asserting the miner's AST reading is correct), and
reused everywhere. `kernel.close(pool)` then propagates: `colon_def_id` →
Proved (zero-premise, rule returned true) → `self_deref_id` → Proved
(supports-edge, sole premise already Proved).

## 3. Kill-test walkthroughs

### 3.1 The 5 corpus instances

1. **`lru/init.lua:155 deref:self`** — walked through in §2.2. Colon-def
   fact (axiom-style, zero-premise rule) + colon-self-nonnil rule ⇒ Proved.
2. **`json/init.lua:125 deref:HEX`** — producer admits a def-use fact
   ("`HEX` assigned once at line 28 inside a `for` loop populating it,
   never reassigned in this file's scope") via a single-assignment miner (a
   new small library, not kernel code); a rule `never-reassigned-nonnil`
   checks `def.assignment_count == 1 and def.initial_value_kind == "table"`
   against the deref payload's variable name, and supports it. Same shape
   as instance 1 with a different fact-miner and a different rule; the
   kernel does not distinguish the two rule families at all.
3. **`queue/init.lua:157 deref:FIFO`** — identical shape to #2, shorter
   range; same rule (`never-reassigned-nonnil`) applies unchanged because
   the rule reads the *payload* the miner produced, not a proximity-based
   site string.
4. **`deque/init.lua:62-65 deref:self` × 4** — same rule as #1
   (`colon-self-nonnil-v1`), applied four times against four different
   `target` ids inside the same method body — the *first-slice-run* note
   that "H1's payoff is per-rule, not per-claim" falls directly out of this
   design: one rule registration, reused by the kernel's `submit` against
   as many targets as a producer names, no kernel change needed to close
   all four at once.
5. **`bigint/init.lua:115 branch:then reachable`** — no rule closes this
   under the design as sketched, honestly: nobody registered a
   reachability-analysis rule in §2.2's minimal producer set. This is
   correctly reported Open, with a receipt that (for the first time) can
   name *which rule would need to exist* — "no registered rule connects a
   `branch:then` presupposition payload to any reachability-evidence
   payload" — rather than the old receipt's generic "Hole H1" citation.
   Building a real reachability rule (a small CFG-reachability check
   against the parsed function body) is exactly Phase 3 substrate work
   (§5), entirely above the kernel; nothing about the kernel changes to add
   it.

### 3.2 Self-carried-semantics / the 2174-shrug

The old check law's failure mode was structural: it grouped by a hardcoded
topic-key and only ever asked "do the schema_key strings match" — i.e. it
never executed anything, it string-compared producer-asserted labels. That
degrades exactly to "trust what the producer wrote in a comment," which is
indistinguishable from doing nothing.

This design differs at the one place that matters: `kernel.submit`
re-executes `rule.check(premises, target)` itself, against the real
payloads, under its own fuel budget, and only records the edge if *the
kernel's own execution* returns `true`. A producer cannot submit "trust me,
these agree" — it must submit a function the kernel runs. The verification
is real to exactly the extent the rule's `check` body is real (§4 states
this limit honestly) — but that is a claim about *rule quality*, an
externally-auditable, testable, single-rule concern (parity-test the rule
against the real semantics, per CLAUDE.md's multi-tier-implementation
discipline), not a claim about the kernel degrading to string comparison.
The kernel's own contribution — re-execution rather than trust, plus
acyclicity, plus the fixpoint — is what a topic-key string match never had
at all.

### 3.3 Ceiling

The kernel imposes exactly one ceiling, and it is per-call, not
per-system: `rule.fuel` bounds a single `check` invocation, guaranteeing
`kernel.submit` and `kernel.close` always terminate (matching this
project's existing hard-timeout discipline for the typechecker itself —
CLAUDE.md's "a typecheck exceeding these is hanging, not slow"). `close`
over a submitted edge set is a standard monotone fixpoint, polynomial in
the number of edges — no risk of non-termination regardless of how many
edges are submitted in one run.

The "unlimited short of uncomputable" mandate is answered *above* the
kernel, not inside it: nothing stops a producer from submitting more rules,
richer rules (a full reachability analyzer, or eventually a real
operational-semantics evaluator answering H1 directly, submitted as one
more rule with real premises = trace objects), or re-running `close` as the
pool/edge-set grows across sessions (an incremental, anytime architecture —
this is the FP/ceiling-survey spine's "anytime fair enumerator," with this
kernel filling exactly the "small trusted certificate-checking kernel" role
the survey named as forced across 3/5 entrants, applied one level down at
the claim level per the owner's framing). The kernel does not know or care
how many rules exist, how sophisticated they are, or whether they
approach the ceiling — it only ever promises that whatever finite
certificate set it is handed in one run, it checks correctly and
terminates on.

## 4. What this hides / assumes

- **Rule honesty is not kernel-checkable, in principle.** A `check`
  function that returns `true` unconditionally with zero premises is
  structurally indistinguishable, to the kernel, from a genuine axiom rule.
  Soundness of the overall Proved/Refuted verdicts is therefore
  *conditional* on every installed rule being locally sound — exactly the
  same honest limit the ceiling-survey found in the V entry ("soundness =
  kernel-only holds only if every portfolio member emits checkable
  certificates... under pressure the project trusts provers directly").
  This is not a gap specific to this design; it is named because pretending
  otherwise would be the special-casing this whole exercise is trying to
  kill. The mitigation is external and already prescribed by this repo's
  own conventions: rules are named, versioned artifacts subject to parity
  testing against the real semantics (CLAUDE.md's multi-tier-
  implementation discipline), not re-derived live by the kernel.
- **Purity of `rule.check` is assumed, not proven.** The sketch says the
  kernel runs `check` "in a stripped environment" — this needs an actual
  sandbox (e.g. a fresh `setfenv`/restricted-`_ENV` table with no ambient
  globals, matching this repo's caps-first discipline) to be real; a rule
  that reaches for ambient I/O or mutates shared state breaks the
  "kernel independently re-executes and confirms" property kill-test 2
  relies on. This is buildable (LuaJIT `setfenv`/`_ENV` swap, no FFI
  needed) but is a piece of Phase 1 work, not yet designed in detail here.
- **Restricted (not full) well-founded semantics.** `close` as sketched
  only handles positive premises (a supports-edge's premises must resolve
  Proved; there is no rule form for "premise must be Open" or other
  negation-as-failure). This is a deliberate simplification — full
  alternating-fixpoint well-founded semantics is well-understood and could
  replace `close`'s algorithm later without touching the trust boundary
  (`admit`/`submit`'s structural checks are unaffected) if a rule family
  ever needs negative premises. Flagged as an open extension point, not
  claimed as already handled.
- **Origin/provenance is genuinely gone from the kernel**, per §1.2 — this
  is a real subtraction relative to the pre-collapse draft and the current
  `lib/declc` code, not a renaming. If a future concern needs source-aware
  policy (e.g. "never let annotation-sourced rules refute mined-sourced
  claims"), that is a *reporting/policy* layer reading the opaque payload's
  self-declared tag, not a kernel change.
- **Address-unification (the actual H1-wall fix) is left entirely open**,
  by design — this design does not claim to solve H1, H3, H4, or H5. It
  claims only that the kernel no longer *blocks* solving them (they no
  longer require a kernel change), which is the substrate-before-consumers
  ordering the task asked for.

## 5. Trade-offs

**Strong:**
- Genuinely closed and small: `admit`/`payload`/`submit`/`close`, ~4
  functions, no claim vocabulary, no enums, testable in isolation with
  synthetic rules exactly the way the current `kernel_test.lua` tests
  `is_verdict` with synthetic verdicts.
- Directly fixes the demonstrated failure (100% Open from topic-key
  mismatch) without adding a compatibility layer or a smarter string
  format — the mechanism that caused the failure (kernel-side grouping by a
  fixed field concatenation) is deleted, not patched.
- Extends cleanly to H3/H4 (◇-claims, hyperproperties) for free, because
  premises/targets are arbitrary opaque payloads and rules are arbitrary
  n-ary functions over them — nothing in the kernel assumes single-trace or
  box/diamond shape.
- The per-rule fuel bound gives the same hard-termination guarantee this
  project already requires of its typechecker, applied to the new
  machinery for free.

**Thin:**
- Says nothing new about *how* to build good rules (H1's real content,
  H5's presupposition catalog, address unification across harvesters) —
  it only clears the kernel out of the way. A reviewer expecting the
  kernel design to also sketch the rule library will find this
  incomplete; that incompleteness is intentional (substrate vs.
  consumers) but worth flagging as a felt gap.
- The sandboxing of `rule.check` (purity/no-ambient-globals enforcement)
  is asserted, not designed in Lua detail — this is real, buildable work
  (LuaJIT `_ENV`/`setfenv`), just not done here.
- Restricted well-founded semantics (positive premises only) is a real,
  named restriction; if the eventual rule library needs negation-as-
  failure, `close`'s algorithm (not its interface) needs to grow.
- Rule-honesty-is-unverifiable is an honest, load-bearing weakness shared
  with every ceiling-survey entrant, not a novel risk of this design — but
  it means the kernel alone cannot be pointed to as "the soundness proof";
  the proof is kernel-plus-audited-rules, and the audit discipline lives
  outside this file.
