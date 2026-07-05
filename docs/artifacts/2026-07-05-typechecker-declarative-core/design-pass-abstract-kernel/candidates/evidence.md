# Candidate: the kernel is a unifier + a mechanized stepper + one grounding rule

Frame: optimize the common case, designed backward from the first-slice-run evidence.
2401 harvested claims, 2174 Open, 0 Proved, 0 Refuted — and the run's own diagnosis
(first-slice-run.md lines 369-403) is that the check law never got a chance to
corroborate anything, because `stated` sites are keyed `"<file>:<line>:<funcname>"`
with slots `entry:`/`exit:`, `mined` sites are keyed `"<file>:<line>"` with slots
`deref:`/`branch:`, and these vocabularies **never syntactically coincide** even when
a human can see they're the same fact. The existing `check.lua` decides Proved/Refuted
by grouping claims under `topic_key = stratum⧺modal⧺site⧺slot` and testing **string
equality** of that key across provenances. That is the 2174-shrug: the kernel already
built is a string-comparison engine wearing a mutual-consistency costume.

So the first design constraint isn't "what claim forms exist" — it's **the kernel must
stop comparing keys and start comparing meanings**, without knowing what any given
claim means. That reframing drives everything below.

## 1. The design

Three things are fixed (closed, trusted). Everything else is open (producer-supplied,
untrusted).

### Fixed thing 1 — the mechanized stepper (ground truth)

One small interpreter of Lua 5.1's operational semantics, `oracle`, already implicit
in the draft's J1 (`P, σ ⇓ T`) and convergent 5/5 across the ceiling survey ("a single
mechanized operational semantics as sole ground truth"). It is not new claim
vocabulary — it's the thing claims are claims *about*. It exposes exactly four
capabilities, none of which know about types, nil, branches, or self:

```lua
--:: Oracle = {
--::   entries: (fn_site: unknown) -> { [integer]: State, ... },  -- statically
--::                enumerable entry states for a definition site
--::   step:    (State) -> (Event, State | nil),                 -- one operational
--::                step; nil next-state means the trace ended
--::   replay:  (concrete_input: unknown) -> { [integer]: Event, ... }, -- run the
--::                program (or a harvested test) and return its recorded event trace
--::   cfg_at:  (site: unknown) -> CfgNode,                        -- static AST/CFG
--::                shape at a site (structure only, no semantic claim)
--:: }
```

`Event` is J1's grammar (`eval`/`bind`/`call`/`ret`/`effect`/`err`) — fixed because
it's a property of Lua's semantics, not of any claim producer.

### Fixed thing 2 — an open term algebra + generic unification

An `Address` is a first-order term: `atom(name)` or `app(functor, args)`. The kernel
never interprets a functor — `var("self", scope=42)`, `binding("HEX", def_site=28)`,
`site(247, "then-branch")` are all just terms to it. The kernel supplies exactly one
operation on them: Robinson unification.

```lua
--: (Address, Address) -> (Substitution | nil)
function kernel.unify(a, b) ... end
```

This is the direct fix for the site/slot mismatch: instead of demanding two claims'
address *strings* be identical, two claims are "about the same fact" iff their
addresses **unify**. A stated claim's address can be
`app("param_binding", {atom("byte1"), atom("s")})` and a mined claim's address can be
`app("param_binding", {atom("byte1"), atom("s")})` too — same functor, same structure,
built independently by two different harvesters that both know the shared *address
algebra convention* (an open, versioned interop contract between producers — not
kernel code) but never had to agree on a raw string format. Where the current
`harvest_stated`/`harvest_mined` disagree only in surface formatting
(`"file:line:fn"` vs `"file:line"`), the fix is producer-side: emit into the same
address algebra. The kernel's job is only to unify whatever it's handed.

### Fixed thing 3 — one proof rule (inductive certificate checking) + one grounding rule

A `Predicate` is an opaque value satisfying one protocol method:

```lua
--:: Predicate = { decide: (Oracle, State) -> ("true"|"false"|"unknown") }
```

The kernel does not know what a predicate computes. It knows exactly one way to
certify a `□`-claim (universal, "true of every trace in the execution set") and,
by duality, exactly one way to refute a `◇`-claim (existential) — **the same rule**,
run on the negation:

- **Proved(□φ)**: producer supplies `cert = {invariant: Predicate, entry_ok, step_ok}`.
  Kernel mechanically checks, using only `oracle`: (a) `invariant.decide` is `"true"`
  at every state in `oracle.entries(site)`; (b) for every `(event, state')` reachable
  by `oracle.step` from an invariant-true state, `invariant.decide(state')` is still
  `"true"`; (c) `invariant ⟹ φ` — checked by asking the SAME decide protocol on a
  producer-supplied `implies(invariant, φ)` predicate, itself checked the same way if
  it's not a primitive identity. This is literal Hoare/abstract-interpretation
  invariant checking, generic over any `invariant`/`φ` — the kernel just calls
  closures and walks a (finite, since Lua CFGs are finite even though execution sets
  are not) step relation.
- **Refuted(□φ)**: producer supplies a concrete trace (or an input to `oracle.replay`).
  Kernel replays it and finds a state where `φ.decide` returns `"false"`. Cheap,
  concrete, no invariant machinery — this is literally running the code.
- **Refuted(◇φ)** (draft.md's Hole H3 — no witness trace exists for this quadrant):
  resolved as **Proved(□¬φ)** using the *same* invariant rule above. No new
  machinery — H3 was only a hole because the draft treated `◇`-refutation as needing
  a different witness kind; it doesn't, it needs the universal-certificate rule
  applied to the negation.
- **Open**: neither cert type checks out within budget, or the producer submits none.

**The one law**, made structural: a cert may itself *cite* other claims by id (an
`invariant` predicate is allowed to internally call `phi_of(other_claim_id).decide`
as a sub-step — this is how a proof composes evidence from multiple pool entries).
The kernel builds the citation graph over all certs submitted in a check run and
**rejects** (refuses to mint a verdict for) any claim whose citation closure is not
acyclic and fully grounded — every claim it depends on must itself carry an
independent Proved or Refuted verdict, never an Open or a cycle. This is exactly
"a claim used as a hypothesis must independently survive as an obligation," restated
as DFS-cycle-detection + closure-groundedness over an open citation graph, instead of
`check.lua`'s current flat "≥2 provenances share a topic-key string" test. Provenance
(`stated`/`axiom`/`mined`) is not read anywhere in this rule — it's still attribution
metadata for reporting, per the certified "grade axis: operationally inert" finding.

### What's abstract / open

Address algebra design, predicate implementations, invariant search strategy, which
facts get mined at all, schema/type entailment tables, dead-code axiom catalogs,
test-trace harvesting — all producer-land. None of it is named in the kernel. A new
claim shape (say, aliasing, or a hyperproperty pair-trace claim per Hole H4) needs
no kernel change: it's a new `Predicate` implementation plus new `Address` functors,
checked by the same three rules.

## 2. Concrete realization

Kernel interface (the entire trust boundary — compare to today's `kernel.lua`, which
already gets the sentinel-tag trick right; this extends it, doesn't replace it):

```lua
-- lib/declc/kernel.lua (redesigned)
local M = {}

--:: Address = { functor: string, args: { [integer]: Address, ... } } | { atom: string }
--:: Predicate = { decide: (Oracle, State) -> ("true"|"false"|"unknown") }
--:: Modal = "box" | "diamond"
--:: Claim = { id: string, address: Address, phi: Predicate, modal: Modal,
--::           source: string }   -- source is metadata only, never branched on

-- generic structural unification, zero domain knowledge
--: (Address, Address) -> (Substitution | nil)
function M.unify(a, b) ... end

-- the one proof rule
--: (Claim, InvariantCert, Oracle, ClaimStore) -> (VerdictOrNil, string | nil)
function M.check_box(claim, cert, oracle, store)
  if not entries_satisfy(cert.invariant, oracle, claim) then
    return nil, "invariant fails at some entry state"
  end
  if not preserved_by_every_step(cert.invariant, oracle) then
    return nil, "invariant not step-closed"
  end
  if not implies(cert.invariant, claim.phi, oracle) then
    return nil, "invariant does not imply the claim"
  end
  -- ground every cited claim id before minting -- the one law, structurally
  local ok, why = grounded_and_acyclic(cert.cites, store)
  if not ok then return nil, why end
  return mint("proved", cert)
end

--: (Claim, ConcreteTraceCert, Oracle) -> (VerdictOrNil, string | nil)
function M.check_witness(claim, cert, oracle)
  local trace = oracle.replay(cert.input)
  for _, ev in ipairs(trace) do
    local state = state_at(ev)
    if claim.phi.decide(oracle, state) == "false" then
      return mint("refuted", { trace = trace, at = ev })
    end
  end
  return nil, "no violating state found in this trace"
end

return M
```

A producer for corpus instance #3 (`FIFO` non-reassignment, `lib/queue/init.lua:157`)
— the "obviously decidable dataflow" shape:

```lua
-- producers/no_reassign.lua (untrusted, lives outside lib/declc's trust boundary)
local M = {}

--: (name: string, def_site: unknown, use_site: unknown, oracle: Oracle) -> InvariantCert | nil
function M.try(name, def_site, use_site, oracle)
  local cfg = oracle.cfg_at(def_site)  -- static shape only, no claim yet
  if not lexically_between(def_site, use_site, cfg) then return nil end

  -- the invariant: "no bind event to `name` has occurred since def_site"
  local invariant = {
    decide = function(_oracle, state)
      for _, ev in ipairs(state.trace_so_far) do
        if ev.kind == "bind" and ev.name == name and ev.site > def_site then
          return "false"
        end
      end
      return "true"
    end,
  }
  return {
    invariant = invariant,
    -- phi this cert is meant to support: "value at use_site is the one bound at
    -- def_site" -- schema-level non-nil-ness is a SEPARATE cited claim (schema
    -- entailment producer, below), not baked into this invariant.
    cites = {},  -- this producer needs nothing else -- terminates immediately
  }
end

return M
```

A second producer closes the loop from "no reassignment" to "non-nil": it looks up
the schema at `def_site` (e.g. `local FIFO = {}` — a table constructor, never nil by
construction) and mints its own claim `non_nil_at_construction(FIFO, def_site)` with
`cites = {}` (grounded trivially — table constructors are part of the fixed
operational semantics: `eval` of `{}` always produces a table value, never nil,
checkable directly against `oracle.step`). The original `deref:FIFO` mined claim's
cert then `cites = { no_reassign_claim_id, non_nil_at_construction_claim_id }` —
citing two independently-grounded claims, satisfying the one law without the kernel
ever knowing "FIFO," "table," or "reassignment" mean anything.

## 3. Kill-test walkthroughs

### 3.1 The 5 corpus instances

1. **`self` non-nil in colon-methods** (`lib/lru/init.lua:155`,
   `lib/deque/init.lua:62-65`). A "calling-convention" producer mints
   `non_nil(self, entry(method))` with an invariant grounded directly in the fixed
   stepper: colon-call syntax `obj:m(args)` is desugared by Lua's own operational
   semantics to `obj.m(obj, args)` — `oracle.cfg_at` exposes that desugaring as a
   static fact, and the invariant "the first bound parameter at a colon-defined
   method's entry state equals the call's receiver expression's value" is checked by
   walking `oracle.entries(method)` (finitely many static call sites) and confirming
   none passes a nil receiver — which is itself a claim the same producer must either
   ground trivially (receiver is a `local` table never reassigned to nil — same
   no-reassign shape as #2/#3) or cite recursively. One producer, one rule, closes
   all 5 occurrences across every file's methods at once (first-slice-run.md's own
   observation: "H1's payoff is not per-claim but per-rule").

2 & 3. **`HEX`/`FIFO` module-level non-reassignment**
   (`lib/json/init.lua:125`, `lib/queue/init.lua:157`). Exactly the producer sketch
   in §2: an invariant over the event trace ("no `bind` event to this name in this
   span") plus a trivially-grounded construction-site non-nil fact. Both check via
   `check_box` in one CFG walk each — no search, no SMT, because the invariant is
   syntactically local and step-closed by inspection.

4. **`self` in `Deque:pop_front`** — same shape as #1, same producer, different
   instantiation. No new kernel behavior.

5. **Branch reachability, `lib/bigint/init.lua:115`**. The cheapest possible producer
   for the common case: `bin/cr test` already exercises this file's functions.
   A test-trace-harvesting producer feeds each test run's recorded event trace
   through `oracle.replay`, and any claim `◇reachable(s)` whose site appears in *any*
   harvested trace is **Proved by witness directly** — not via `check_box` at all,
   via the trivial existential rule (a recorded concrete trace containing an event at
   `s` **is** the witness `T ∈ 𝕋_Γ(P)` J5's F-fine clause asks for). This costs
   nothing beyond instrumenting the test runner to log events — it turns the
   test suite already in the repo into a claim-discharging engine for the single
   most common mined-belief shape (`branch:then`/`branch:elseif` claims dominate the
   Open samples in every one of the 8 files). Where no test trace covers a branch,
   the claim stays Open honestly — that's a real coverage gap report, not a bug.

### 3.2 Self-carried semantics (not string comparison)

The kernel never compares `site+slot` strings. Two claims connect in two ways, both
mechanical and neither stringly: (a) their `Address` terms **unify** (structural
term unification, not `==` on strings — the same "same fact" judgment can hold
between `app("param_binding",{...})` built by the stated harvester and an identical
term built by the mined harvester, or between differently-shaped terms if a producer
supplies an explicit unifying substitution as part of a cert); (b) their `Predicate`
closures are **executed** against the same `Oracle` — a claim is only ever validated
by asking whether it actually holds of program states/traces the fixed semantics
produces, never by trusting a producer's say-so. A malicious or buggy producer that
submits `cert.invariant = function() return "true" end` unconditionally still fails
`check_box`'s `entries_satisfy`/`preserved_by_every_step` checks the moment the
kernel actually calls it against real entry states and real steps — because the
kernel independently re-executes the predicate against the oracle rather than
recording that the producer "asserted" the invariant holds. This is the direct fix
for the 2174-shrug: that failure was a kernel that only ever compared producer-chosen
*labels*; this kernel never sees a label, only a term to unify and a closure to run.

### 3.3 Ceiling

The ceiling is exactly: **whatever the fixed stepper can settle by finite
invariant-checking or finite trace-replay, within budget.** Concretely:
- `check_witness` (Refuted(□) / Proved(◇)) is always decidable per trace — bounded by
  budget on how many traces get replayed, never by anything structural.
- `check_box` (Proved(□) / Refuted(◇) via ¬φ) is decidable exactly when the
  `preserved_by_every_step` check over the (finite) CFG's step relation terminates —
  which is the same wall every abstract-interpretation-genus tool hits (widening,
  non-termination of fixpoint search on a badly-chosen invariant) — Rice is not
  evaded, it's pushed to "does a producer supply an invariant whose preservation
  check terminates," same as V/AI in the ceiling survey.
- Nothing is hardcoded as "always Proved" to make numbers look better; the common
  case is fast only because its invariants are syntactically tiny (single-scope,
  single-name), not because the kernel special-cased self/HEX/FIFO.

This matches the ceiling-survey's accepted answer for the winning composite: an
unbounded, open strategy library (here: invariant/cert producers) reaching toward the
r.e. frontier through a small trusted certificate checker, never claiming totality.
The "unlimited short of uncomputable" mandate is satisfied in the same asymptotic,
never-completed sense the composite already accepted — this design doesn't resolve
that tension, it inherits it honestly, at the claim layer instead of the program
layer.

## 4. What this hides / assumes

- **The stepper's fidelity is assumed, not proven.** FFI/eval/OS boundary fidelity is
  the "semantics-reality gap" every one of the 5 ceiling entries names as the likeliest
  death; this design is exactly as exposed to it as all five, because `oracle` is the
  fixed thing everything else is checked against.
- **Heap/aliasing is unaddressed.** `Address` terms as sketched (`var`, `binding`)
  presume simple lexical/name addressing; nothing here proposes a points-to/aliasing
  algebra. A producer wanting to claim things about heap-shared tables needs a richer
  `Address` functor vocabulary — open by design, but nobody has designed it yet.
- **`implies(invariant, phi)`** is quietly doing real work in `check_box` — checking
  an entailment between two predicates is exactly as hard as checking either one
  alone, in general. For the common-case producers sketched above it's trivial
  (identity or a one-step schema lookup), but for a hard invariant it's another
  undecidable-in-general call, recursively subject to the same ceiling. This is not
  hidden complexity so much as complexity honestly relocated to where the ceiling
  survey already expects it (AI's completeness-repair territory).
- **Grounding/acyclicity checking is O(claims + citations)** per run, cheap — but
  assumes producers report their citation edges honestly; a producer that internally
  calls another claim's `phi.decide` without listing it in `cites` breaks the one law
  invisibly. The kernel cannot detect an unreported citation from the outside — this
  is the same "untrusted producer, trusted kernel" boundary every LCF-style design
  accepts, but it's worth stating plainly: `cites` is a producer-supplied manifest,
  not something the kernel derives by inspecting the closure.
- **Test-trace-harvesting for reachability assumes representative test coverage.**
  It's a real, cheap, sound witness source for the common case, but its Open-rate is
  a direct function of `bin/cr test`'s coverage of the corpus, not of the kernel's
  power — a library with thin tests gets thin reachability answers for free reasons
  that have nothing to do with this design's ceiling.

## 5. Trade-offs — where it's strong, where it's thin

**Strong:**
- Directly answers the corpus's own diagnosis: the 2174-shrug was a string-matching
  bug at the kernel boundary, not a missing derivation theory; this design removes
  string matching from the kernel entirely, replacing it with unification + real
  execution, which is strictly more general (unification subsumes string equality as
  the degenerate ground-term case) and never regresses anything the current
  `check.lua` could already do.
- The dominant corpus shape (mined non-nil / reachability claims, ~1839/2401 claims)
  gets a real fast path — invariant certs that are syntactically tiny (single-name,
  single-scope) terminate their step-closure check immediately, and reachability
  gets a near-zero-cost path via existing test-trace replay — without a single
  kernel-level name for "self," "colon-call," "non-nil," or "branch." Both fast paths
  are producers registering through the same two rules everything else uses.
- H3 (◇-refutation witness) falls out for free as Proved(□¬φ) via the one rule
  instead of needing separate machinery — a real simplification versus the draft's
  4+1 claim/finding rule count.
- The one law becomes literally checkable (DFS over a citation graph) rather than a
  reporting-layer heuristic ("do ≥2 provenances share a string key") — closing the
  gap the adversarial review flagged in the draft's site heterogeneity.

**Thin:**
- `implies()` and "step-closed" checking for non-trivial invariants are where all the
  real difficulty of program analysis still lives — this design is honest that it
  relocated, not solved, the hard part. It gives producers a clean, generic protocol
  to attack that difficulty in, but doesn't make the difficulty go away (nor should
  it, per Rice).
- No aliasing/heap story, same gap every ceiling entrant and the current draft admit.
  `Address` unification over a lexical/name term algebra is a real, useful floor, not
  a full solution — a future heap-aware producer needs a richer term algebra, which
  this design permits but doesn't design.
- The design leans hard on "producers report citations honestly" and "predicates are
  actually re-executed, not just trusted" as the entire soundness argument — that's
  the correct LCF-style discipline, but it means a buggy `check_box`/`check_witness`
  implementation (the ~150 lines that actually call `oracle`) is exactly as
  security-critical as the rest of the kernel; keeping that surface small (as sketched
  in §2) is a design commitment this proposal makes but the eventual implementation
  has to keep honoring.
- Test-trace-driven reachability is powerful for *this* corpus (small, well-tested
  libraries) and much weaker for code with thin test coverage — the "optimize the
  common case" framing is calibrated to crescent's actual `lib/` corpus, which may
  not generalize to less-tested real-world Lua.
