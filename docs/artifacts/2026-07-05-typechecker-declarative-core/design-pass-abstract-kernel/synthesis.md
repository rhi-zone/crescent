# Abstract kernel — synthesis (2026-07-06)

Status: **PROPOSAL for owner review.** Nothing here is certified. This
document synthesizes four decorrelated candidates
(`candidates/{subtract,primitive,invert,evidence}.md`) and their independent
adversarial attacks (`judgments/{subtract,primitive,invert,evidence}-attack.md`)
into one composite kernel design, per the design-it-twice discipline. Verdicts
going in: subtract SURVIVES-WOUNDED, invert SURVIVES-WOUNDED, evidence
SURVIVES-WOUNDED, primitive KILLED (with named salvage). Every claim below
that asserts something as settled cites the attack report it rests on;
anything not settled by the evidence is marked as an explicit owner call in
§5, not silently picked.

## 1. Chosen base, and why

**Base: `subtract`'s four-primitive skeleton** — Pool (opaque ids + opaque
payload), Edge/`Rule` `(rule, premises: {id}, target: id, polarity)` with
kernel re-execution, an acyclicity check at edge-admission time, and `close`
as a monotone least-fixpoint over the accepted edge set.

Grounds for choosing it over the other three, from the attack evidence rather
than from eloquence:

- **All four judges independently converge that this skeleton — or an edge/
  citation-graph structure recognizable as the same shape — is the one piece
  worth keeping "regardless of what happens to the rest."** subtract's own
  judge names it explicitly ("collapsing 'same topic' from a kernel-fixed
  field-hash into producer-named ids inside an edge... any surviving
  composite design should keep it even if everything else here gets
  rebuilt" — `judgments/subtract-attack.md`, closing line). invert's judge
  independently converges on the *same* shape from a different candidate
  ("the one law recast as a content-blind graph-acyclicity check over
  certificate dependency edges... could be the cleanest formalization of the
  certified law across all candidates in this pass" —
  `judgments/invert-attack.md`).
- **It has the smallest trusted surface of the three survivors.** `invert`
  and `evidence` both bake a mechanized Lua evaluator and a growing rule
  calculus into the trusted core; their own judges found this collides with
  two repo hard constraints — the 30-second pre-commit typecheck timeout
  (`judgments/invert-attack.md` Attack 7: "meta-circular interpretation
  overhead... plausibly 2-3 orders of magnitude slower than native
  execution... the design offers no argument that Witness replay at real
  corpus scale fits inside the repo's own hard timeout contract") and the
  project's actual LuaJIT+FFI target vs. a Lua-5.1-only stepper
  (`judgments/invert-attack.md` Attack 6: "a large fraction of the corpus is
  out of scope for Proved/Refuted from day one"). `subtract` avoids this by
  never requiring an evaluator inside the trusted core at all — `rule.check`
  is arbitrary producer code, replayed, not owned.
- **It directly and correctly fixes the diagnosed 100%-Open failure.**
  `first-slice-run.md` traces the 2174-shrug to a fixed `topic_key`
  string-equality gate inside the kernel; all four attack reports agree this
  diagnosis is correct, and three of four agree `subtract`'s fix (delete the
  gate, let producers name ids directly in an edge) is the right shape of
  fix, even where they attack its *execution* (see §3).
- `evidence`'s kernel-level `unify` primitive was checked and found
  decorative rather than load-bearing: "unification only does work when two
  terms are already built from the same functor vocabulary... at which
  point the real fix is 'someone rewrote both harvesters to agree,' and
  unification is decoration on top of a coordination act the candidate
  doesn't specify anyone doing" (`judgments/evidence-attack.md` Attack 1).
  Carrying a kernel-level comparison primitive that the evidence shows
  doesn't solve the problem it's justified by is worse than carrying none.

This is not a claim that `subtract` "won" outright — it was itself found
SURVIVES-WOUNDED, with a flagship rule shown unsound (§2/§6 below) and real
gaps in provenance handling and complexity claims. The choice is: smallest
correctly-diagnosed skeleton, patched with the specific grafts the other
three candidates' judges certified as sound and necessary. §3 is the graft
ledger; §6 shows each fake-Proved path found across all four attacks and
whether the patched design closes it.

## 2. The synthesized kernel

### 2.1 Interface sketch (Lua-annotation style)

```lua
-- lib/declc/kernel.lua (synthesis) -- the entire trusted core

--:: Id = unknown                     -- opaque handle, kernel-minted
--:: Strength = "existential" | "universal"
--:: CheckVerdict = "supports" | "refutes" | "unknown"   -- delta 1
--:: Polarity = "supports" | "refutes"
--:: Provenance = "stated" | "axiom" | "mined"           -- delta 4, kernel-assigned only

-- Rule.check receives, per premise, BOTH the payload and that premise id's
-- currently-established verdict (delta 8) -- never a raw pool-lookup
-- capability (delta 5: no ambient access to anything not explicitly passed).
--:: PremiseView = { payload: unknown, verdict: Verdict | nil }
--:: Rule = {
--::   id: string,             -- name/version, audit trail only, never branched on
--::   fuel: integer,
--::   premise_types: { [integer]: TypeDecl, ... },  -- delta 7: narrows payload
--::   target_type: TypeDecl,                        --   at the call boundary
--::   strength: Strength,     -- delta 2: what this edge, if accepted, establishes
--::   check: (premises: { [integer]: PremiseView, ... }, target: PremiseView)
--::           -> CheckVerdict,
--:: }

--:: Verdict = { tag: "proved_witness" | "proved_claim" | "refuted" | "open",  -- delta 3
--::             cert: Id | nil, receipt: string | nil }

--: () -> Pool
function M.new_pool() ... end

--: (Pool, Payload, Provenance) -> Id
-- ONLY entrypoint that mints an id; Provenance is fixed by which of exactly
-- three wrapper functions the producer called (admit_stated/admit_axiom/
-- admit_mined), never a self-declared payload field (delta 4).
function M.admit(pool, payload, provenance) ... end

--: (Pool, Rule, premises: { [integer]: Id, ... }, target: Id, Polarity)
--    -> (boolean, string | nil)
-- 1. shape-checks premises/target against rule.premise_types/target_type
--    (delta 7) -- rejects, does not force-cast, on mismatch
-- 2. checks acyclicity: bounded DFS from target through premises, NOT
--    union-find (delta 6) -- rejects on any path back to target
-- 3. checks strength admissibility (delta 2): if this rule declares
--    strength = "universal" and cites a premise at universal use, that
--    premise's own currently-accepted edge must itself carry
--    strength = "universal" (an existential-only premise cannot discharge
--    a universal use) -- purely an enum comparison over edge metadata,
--    never an interpretation of payload content
-- 4. re-executes rule.check(premises_view, target_view) under rule.fuel,
--    sandboxed: no ambient pool/global access from inside check (delta 5)
-- 5. only adds the edge if check() returns "supports" or "refutes"
--    (never on "unknown" -- delta 1, no guessing)
function M.submit(pool, rule, premises, target, polarity) ... end

--: (Pool) -> { [Id]: Verdict, ... }
-- monotone fixpoint; a target reaches "proved_claim" only via an edge
-- (or edge-chain) whose every strength tag is "universal"; an edge chain
-- containing any "existential" strength tops out at "proved_witness"
-- (delta 3) -- the receipt distinguishes these explicitly, never collapses
-- them to one "Proved" tag.
function M.close(pool) ... end
```

### 2.2 Trusted-surface inventory

Trusted (in the kernel, changes are version-bumped trusted-core changes):

- `admit`/`payload` (opaque pool, kernel-minted ids, kernel-assigned
  provenance tag)
- `submit`'s five checks: type-shape narrowing, acyclicity (bounded DFS, not
  union-find), strength admissibility, sandboxed re-execution under fuel,
  three-valued gating on the `check` result
- `close`'s monotone fixpoint with existential/universal-aware verdict
  levels

Explicitly NOT trusted (producer-side, arbitrary, none of it named in the
kernel): claim forms, site/slot/address vocabulary, what a rule's `check`
actually computes (string comparison, a real interpreter, an SMT call — the
kernel cannot tell and does not try), whether a mechanized Lua evaluator
exists at all (fork (b), §5), address-unification/schema-registry
conventions between producers (§4 meta-finding 2), axiom catalogs,
presupposition mining, reachability analysis.

## 3. Graft ledger

Each graft: accepted or rejected, with the attack-report evidence.

**1. Producer-named ids in edges + acyclicity-as-the-one-law (from
`subtract`).** ACCEPTED — this is the base itself (§1).

**2. Quantifier-strength matching between a hypothesis's use and its
discharge (from `invert`'s judge).** ACCEPTED. `judgments/invert-attack.md`
Attack 2 constructs the exact failure: "nothing in the acyclicity check
compares the *strength* at which H was consumed against the *strength* at
which H is discharged... A false universal claim can ride to Proved on the
back of a true-but-weak existential discharge of its own hypothesis role.
That is a structural path to a fake Proved." `subtract`'s original design had
no modal/strength concept at all (deliberately dropped, §1.1 point 1 of
`candidates/subtract.md`) — this graft reintroduces the minimum structural
metadata (an enum tag on edges, never interpreted content) needed to close
that specific hole, which is otherwise present in *any* acyclicity-only law,
`subtract`'s included.

**3. Mandatory non-guessing `"unknown"` + kernel-enforced Proved-for-witness
vs. Proved-for-claim distinction (from `primitive`'s salvage).** ACCEPTED.
`judgments/primitive-attack.md`'s verdict names this as the one thing "worth
carrying into whatever design replaces this one," specifically paired with
"an explicit distinction between Proved-for-a-witness and Proved-for-a-claim
enforced in the kernel API rather than left to prose discipline." Both
halves are grafted: `check` returns three values (never a boolean a producer
must force to one of two), and `Verdict` itself, not just internal
bookkeeping, carries the witness/claim distinction (delta 3, §4 of this
document). Also directly closes `judgments/primitive-attack.md` Attack 1
(degenerate singleton-witness-domain masquerading as universal proof) — see
§6 row 3.

**4. ◇-refutation folded into `Proved(□¬φ)` (from `evidence`).** ACCEPTED,
with one disclosed extension. `judgments/evidence-attack.md`'s verdict names
this as worth keeping "even if this candidate is later demoted... a genuine
simplification independent of everything else here." Realizing it inside
`subtract`'s edge model requires `Rule.check` to be able to read a premise's
*currently-established verdict*, not only its payload (delta 8, §4) — a
premise submitted as `¬φ`'s claim id, once independently `proved_claim`,
lets a plain rule mint `refutes` on `◇φ`'s id with no separate certificate
kind. This is a small, disclosed widening of the `Rule.check` signature
(`PremiseView` includes `verdict`), not new trusted vocabulary about modality
— the kernel still never knows what `□` or `◇` mean.

**5. Kernel-level `unify`/address-term-algebra (from `evidence`).**
REJECTED. `judgments/evidence-attack.md` Attack 1: "unification only does
work when two terms are already built from the same functor vocabulary with
matching arity/field structure — it reconciles unbound variables, not
incompatible shapes... at which point the real fix is 'someone rewrote both
harvesters to agree'... Nothing in the design assigns ownership of the
address-algebra convention to anyone." A kernel primitive justified by a
mechanism the same attack report shows doesn't do the job is a worse trade
than no primitive; the coordination problem it was meant to solve is instead
named directly as unsolved substrate (§4, meta-finding 2).

**6. Mechanized Lua evaluator as trusted-core surface (from `invert` and
`evidence`).** REJECTED as *mandatory* trusted-core surface; kept available
as an *optional* producer-side `Rule.check` implementation. Both judges
found this trusted surface itself under-designed and expensive:
`judgments/invert-attack.md` Attack 7 ("no argument that Witness replay at
real corpus scale fits inside the repo's own hard timeout contract"), Attack
6 (LuaJIT/FFI vs. vanilla-5.1 fidelity gap sizes a large fraction of the
corpus as permanently out-of-scope), Attack 5 ("who proves a rule sound, in
what formal system... unmechanized meta-proof is exactly the kind of
unverified assertion the whole architecture was built to eliminate").
`judgments/evidence-attack.md` Attack 4 finds the same evaluator's own
flagship walkthrough non-terminating on looping code as literally described.
This is presented as an explicit owner call, not a silent rejection — see
§5 fork (b).

**7. Witness-shape-as-convention / corroboration-as-second-primitive (from
`primitive`).** REJECTED as a distinct mechanism, subsumed instead by the
strength/witness-vs-claim machinery already grafted (items 2-3). `primitive`
itself was KILLED — its flagship demo produced a false Refuted on its own
pasted code (`judgments/primitive-attack.md` Attack 0), its corroboration
primitive was never actually exercised by its own worked example, and its
witness-shape convention was found to be a *less* diagnosable version of the
original 2174-shrug (Attack 2: "the tooling surface that made the original
failure discoverable at all... is gone"). Only the noun (executable
three-valued checker) and the non-negotiable-unknown discipline were judged
worth keeping (graft 3); the surrounding architecture is not adopted.

**8. Structural repairs to `subtract` itself, required regardless of what
else is grafted:**
- Acyclicity via bounded DFS, not union-find (`judgments/subtract-attack.md`
  Attack 6: "union-find does not detect cycles in a directed graph...
  [this] doesn't sink the design... but it means the design's own stated
  complexity argument... is not currently correct as written"). ACCEPTED as
  a correction, not a design choice.
- Kernel-assigned provenance tag restored, not deleted (delta 4).
  `judgments/subtract-attack.md` Attack 3: deleting the enum "makes 'no
  source special-cased' trivially/vacuously true... which is a different
  and weaker thing than what was certified," and removes the old design's
  only structural defense against "a single dishonest producer
  manufacturing a chain of distinct ids and distinct-looking rules that all
  originate from itself." ACCEPTED — restored as kernel-minted metadata,
  still never branched on by `submit`/`close` (preserving the certified "no
  source special-cased" property), available only to an optional reporting
  layer.
- Typed, narrowed `premise_types`/`target_type` instead of raw `unknown`
  payload (`judgments/subtract-attack.md` Attack 7: "every rule author must
  either write a force cast... or the design needs an as-yet-undesigned
  narrowing mechanism... The design doesn't flag this tension anywhere").
  ACCEPTED as a certification delta (§7 item 7) — this is real, currently
  unbuilt typechecker substrate, not a free change; flagged honestly as
  such, not silently assumed solved.
- Sandboxed `rule.check` with no ambient pool access (`candidates/subtract.md`
  §4 already names this as unbuilt; retained as a build requirement because
  it is also what closes the invert/evidence citation-omission attack, §6
  row 6).

**Not grafted, and not rejected — left as-is because no attack touched it:**
`subtract`'s restricted (positive-premises-only) well-founded semantics for
`close` (no negation-as-failure). Flagged in `candidates/subtract.md` §4 as
a named, deliberate simplification; no judge attacked it; carried forward
unchanged as an open extension point.

## 4. The two meta-findings

### 4.1 Four for four: every flagship walkthrough failed adversarial re-derivation

Every candidate's judge, independently, found the document's own worked
demonstration did not survive being re-derived from the pasted code/prose:

- `subtract`: `colon-self-nonnil-v1` checks the method's *definition* site
  (`def.form == "colon"`) but the fact it claims to establish is about every
  *call* site — "colon *definition* syntax... only sugars an implicit
  `self` parameter — it places zero obligation on *callers*. Nothing stops
  `Cache.peek(nil, key)`" (`judgments/subtract-attack.md` Attack 1).
- `primitive`: the pasted `mined_deref_nonnil.check` collapses "field absent"
  and "field explicitly nil" onto the same Lua value, so re-running the
  pasted code on the pasted example produces a false Refuted, not the
  claimed empty `findings` (`judgments/primitive-attack.md` Attack 0).
- `invert`: the `self`-non-nil certificate cites a static "defined with
  colon syntax" fact that, by the design's own account of the evaluator, is
  already erased by the time any `Trace` event exists — the certificate as
  narrated isn't constructible by the trusted code sketched two sections
  earlier (`judgments/invert-attack.md` Attack 1).
- `evidence`: the same `self`-non-nil invariant is certified via
  `oracle.entries(method)`, described as a static enumeration of colon-call
  sites, with no argument that this enumeration soundly over-approximates
  every actual invocation — "extracting the function value directly... a
  first-class escape of the method value is silently invisible to the
  invariant check" (`judgments/evidence-attack.md` Attack 4).

**All four failures cluster on the same corpus instance** (colon-method
`self` non-nil, corpus instances #1/#4 — 5 of 8 "obviously decidable"
Open-instance occurrences named in `first-slice-run.md`), and all four make
structurally the same category error: mistaking a fact established *at one
site, in one witnessed run, or by one syntactic sugar rule* for a fact that
holds *universally, at every call, everywhere in the program, including
through paths a static definition-site scan can't see*. This is a
textbook invariant/quantifier-scope error, not four unrelated bugs.

**Why this instance seduces four independent designs into the same
shortcut:** it is genuinely true almost always in idiomatic OO Lua; a human
reading the code confirms it in one second (`first-slice-run.md` calls it
"obviously decidable... in seconds by a human," verbatim, in its own
framing of the 5 instances); and the 8-file corpus that produced it is
small, well-tested, closed-world library code where the escape hatches that
break the shortcut (`local f = obj.m; f(nil, x)`, metatable-mediated
dispatch, dispatch-table indirection) never actually occur
(`judgments/evidence-attack.md` Attack 5 names this directly: "the corpus
that produced these 5 instances is exactly the corpus these 5 producers
were built to fit"). A demo corpus chosen because it's "obviously decidable"
selects, by construction, for exactly the claims where the seductive
shortcut and the correct answer happen to coincide — this is the same shape
as the v9 precision failure CLAUDE.md's hard constraints cite as the reason
v5 exists (ad-hoc, demo-fit correctness that reads as generality).

**What discipline/kernel property prevents it, going forward:** not a fix to
any specific rule (no rule can be certified correct by kernel structure
alone — that limit is named honestly in §6 and is shared by every
candidate) but a structural requirement that a rule *declare* which
strength it's establishing (delta 2) and that the kernel *refuse to promote*
an edge chain to `proved_claim` unless every edge in it is tagged
`"universal"` (delta 3). Applied to the flagship rule itself: as originally
written, `colon-self-nonnil-v1` would have to declare `strength =
"universal"` while its `check` body only ever inspects a definition-site
fact — nothing in the kernel can catch that mismatch automatically (the
strength tag is producer-declared, not derived), but the *receipt* for such
a claim becomes visibly "universal claim, only definition-site evidence
cited, no call-site-completeness certificate" instead of a silent
`Proved`. That turns an invisible false positive into a visible, reviewable
gap — closing the silence, not the underlying open problem (whole-program
call-site census / escape analysis remains genuinely unbuilt work, same as
every candidate left it).

### 4.2 The producer-coordination/meeting problem was relocated, never solved

Every candidate, independently, pushed the actual question the 2174-shrug
raises — how do two independently-written harvesters discover they're
talking about the same runtime fact — to the producer layer, under a
different name each time, and none of them assigns an owner to solving it:

- `subtract`: producers must independently choose to name the *same*
  pool-entry ids in an edge's `premises`/`target` — the "sameness" judgment
  moves from a kernel-side string-equality gate to an out-of-band
  handshake between whoever wrote each producer.
- `primitive`: producers must independently agree on witness *shape*
  (`witness.kind == "binding"`, field names) — worse, per its judge, because
  the pre-collapse design at least had a visible, diffable `claim.key` field;
  the new failure mode "is demoted into a strictly less observable place...
  the tooling surface that made the original failure discoverable at all...
  is gone" (`judgments/primitive-attack.md` Attack 2).
- `invert`: certificates cite claim ids by convention (`phi_of(other_id)`);
  same handshake, same lack of an owner.
- `evidence`: producers must agree on `Address` functor/arity/argument-order
  conventions — found *harder* to spontaneously converge on than the
  original string mismatch, because it has strictly more degrees of freedom
  ("functor names, arity, argument order, nesting depth")
  (`judgments/evidence-attack.md` Attack 1).

**Naming it plainly:** this is the true substrate underneath Hole H1, and it
is a coordination/registry problem, not a kernel-design problem. No
candidate in this pass builds it, owns it, or even proposes a review
process for it. This synthesis does not solve it either — doing so honestly
means naming it as its own scheduled substrate deliverable (a canonical
addressing/interop contract between harvesters, with a named owner and a
review gate, built and versioned the way `RULES` tables or type
declarations are, not left as unwritten convention), to be built *before or
alongside* the first real producer library, not assumed away by any of the
four kernel mechanisms proposed (id-naming, witness-shape, certificate
citation, or address unification — none of these are that registry; all
four are places a registry's *output* would be consumed). This is delta 9
(§7) and is listed under "not claimed" in §8.

## 5. Fork resolutions and explicit owner calls

**Fork (a): does the kernel compare/unify claims at all, or is all contact
producer-mediated?**

**Resolved by the evidence: producer-mediated, no kernel-level comparison
primitive.** `evidence`'s kernel-level `unify` was the only candidate to
propose otherwise, and its own attack report found the primitive decorative
— it "reconciles unbound variables, not incompatible shapes," and the real
coordination act it was meant to replace is never actually specified as
happening (`judgments/evidence-attack.md` Attack 1, §1 above). `subtract` and
`invert` both keep all "aboutness" producer-side (ids named in edges;
certificates citing ids), and neither attack report found a hole in that
choice *specifically* — the holes found were in strength-matching (§3 graft
2) and citation-manifest honesty (§6 row 6), not in the absence of a kernel
comparison operator. This fork is settled, not an owner call.

**Fork (b): is a trusted Lua evaluator inside the kernel, or is grounding
external (parity discipline)?**

**Not settled by the evidence — genuine owner call.** Neither `invert` nor
`evidence` was shown *wrong* to want a mechanized evaluator as ground truth;
their judges found the *specific* evaluators sketched under-designed and
expensive against this repo's actual constraints (§3 graft 6), not that the
idea is unsound in principle. The tradeoff, stated plainly:

- **External (subtract's approach, adopted as this synthesis's default):**
  smallest trusted core, buildable now, no collision with the 30-second
  pre-commit timeout or the LuaJIT-vs-vanilla-Lua-5.1 fidelity question. Cost:
  rule-honesty (does a `check` closure actually compute what it claims to)
  is kernel-unverifiable *in principle*, forever — named as a shared limit
  by `subtract`'s own §4 and echoed by every judge, not a defect unique to
  this choice.
- **Internal (invert/evidence's approach):** the kernel itself could
  independently confirm a rule's grounding against a real semantics, closing
  part of the rule-honesty gap. Cost: real, currently unsolved termination
  and fidelity problems (`judgments/invert-attack.md` Attacks 6-7,
  `judgments/evidence-attack.md` Attack 4) that would need to be solved
  *before* this trusted surface could be built at all, and no candidate in
  this pass solved them.

This synthesis defaults to external for the reasons in §1 (matches the
repo's zero-dependency/pure-Lua-baseline and hard-timeout constraints as
they exist today), but this is a recommendation, not a resolution — the
owner may certify the internal-evaluator path instead, accepting that its
termination/fidelity problems become the next scheduled substrate work
rather than a rejected idea. Certification delta 10 (§7) records this
explicitly so it isn't silently decided by default.

## 6. Fake-Proved path closure table

Every attack report found at least one path to a fake or mislabeled Proved
verdict. Each is listed with its closure status under this synthesis.

| # | Path found (report) | Mechanism | Closure status |
|---|---|---|---|
| 1 | `colon-self-nonnil-v1` checks definition site, claims a call-site-universal fact (subtract Attack 1) | Rule content is logically wrong | **OPEN, by design** — rule-honesty is kernel-unverifiable in principle (shared limit, named in `subtract` §4 and every judge). Delta 2/3 make the gap *visible* in the receipt (a "universal" claim citing only definition-site evidence) instead of silent, but cannot verify the rule's logic itself. External parity-testing discipline (existing CLAUDE.md convention) is the only closure mechanism, same as before. |
| 2 | nil/absent conflation produces false Refuted (primitive Attack 0) | Payload-level Lua value ambiguity, invisible to `unknown`-typed fields | **CLOSED BY DISCIPLINE, contingent on delta 7.** Typed, narrowed `premise_types`/`target_type` at the `Rule.check` boundary (rather than raw `unknown`) is exactly the kind of declared shape that would let `bin/cr check` flag a field read that conflates "absent" and "nil" as a narrowing error. Contingent on the narrowing mechanism (delta 7) actually being built — not yet designed in Lua detail here, same honest caveat `subtract` itself carried. |
| 3 | Proved-for-a-singleton-witness-domain mislabeled as universal (primitive Attack 1) | `exhaust()` "observes termination" on a producer-fabricated one-element domain that already encodes the generalization | **CLOSED**, structurally, by grafts 2+3: an edge can only contribute to `proved_claim` if it declares (and the kernel records) `strength = "universal"`; a single-witness edge is `"existential"` by construction and the fixpoint never promotes it past `proved_witness`. The producer can still *lie* about strength (declare "universal" for a one-witness check) — that residual is the same rule-honesty limit as row 1, not a new hole. |
| 4 | Correlated-error corroboration: two independently-wrong producers agree on a shared misread (primitive Attack 3) | No safety condition constrains whether "independently admitted" claims are about the same fact beyond both functions returning non-error values | **OPEN.** Not solvable by kernel structure alone (the kernel has no way to know two producers share a blind spot). Kernel-assigned provenance restoration (delta 4) gives an optional reporting-layer signal ("this claim's whole proof DAG traces to a single provenance-admission call, or lacks cross-provenance diversity") — visibility, not a soundness proof. Named plainly as unsolved. |
| 5 | Existential discharge of a claim satisfies a universal use of that same claim as hypothesis (invert Attack 2) | Acyclicity alone is quantifier-blind — it checks "no cycle," not "matching strength" | **CLOSED** — this is graft 2, the central structural addition of this synthesis. The kernel refuses to accept a `submit` where a rule declares a universal use of a premise whose own accepted edge is existential-strength. |
| 6 | Undeclared internal citation: two claims' `decide`/`check` closures consult each other via an ambient side-channel, invisible to the declared citation manifest (invert Attack 3-analog / evidence Attack 3) | `cites`/citation-graph is a producer-supplied manifest, separate from and unverified against what the closure actually reads | **CLOSED BY ARCHITECTURE, contingent on delta 5 (sandboxing).** Unlike `invert`/`evidence`, this synthesis's `Rule.check` never receives ambient pool-lookup capability — the *only* claim content a rule can ever read is what's explicitly listed in its own `premises` argument, which is exactly what the acyclicity/strength checks already walk. There is no side channel left for an undeclared reference to hide in, *provided* the sandbox (no ambient globals/pool access inside `check`) is actually built — currently a named, unbuilt requirement (same status `subtract` §4 gave it), not yet implemented. |
| 7 | Certificate kind cited in a walkthrough isn't constructible by the trusted code two sections earlier (invert Attack 1) | Documentation/formalization mismatch, not a kernel design flaw per se | **N/A to this synthesis** — this attack is specific to `invert`'s certificate-type sketch, which is not adopted. Recorded here only to confirm it doesn't recur: this synthesis's `Rule.check` signature is used consistently across §2 and §3; no walkthrough in this document cites a certificate/argument shape the sketch doesn't support. |

## 7. Certification deltas

Each item below is an independent change to `declarative-design.md`'s
certified wording that this proposal implies. `declarative-design.md` itself
is **not modified** — these are proposed deltas for the owner to certify or
reject one at a time. Each names what breaks if rejected.

1. **`Rule.check` returns three-valued `"supports"|"refutes"|"unknown"`,
   never a boolean; the kernel never adds an edge on `"unknown"`.**
   If rejected: producers are forced to collapse "I don't recognize this
   shape" into an actual answer, reopening the nil/absent-conflation bug
   class found in `judgments/primitive-attack.md` Attack 0.
2. **Every accepted edge carries a kernel-recorded `strength ∈
   {"existential", "universal"}` tag, declared by its rule; a rule that
   declares a universal use of a premise may only cite that premise if the
   premise's own accepted edge is itself universal-strength.**
   If rejected: reopens the single most serious structural fake-Proved path
   found across all four attacks — existential discharge silently
   satisfying a universal hypothesis use (`judgments/invert-attack.md`
   Attack 2).
3. **`Verdict` distinguishes `proved_witness` from `proved_claim`
   (not one undifferentiated "Proved") in the reporting/receipt layer, not
   only internally.**
   If rejected: reopens the degenerate-singleton-domain masquerade
   (`judgments/primitive-attack.md` Attack 1) — a reader can no longer tell
   whether "Proved" means "true once, for a producer-chosen instance" or
   "true universally."
4. **Provenance (`stated`/`axiom`/`mined`) is restored as a kernel-assigned
   tag, fixed at the moment `admit` is called through one of exactly three
   entrypoints, immutable thereafter — not a self-declared payload field.**
   Never branched on by `submit`/`close` (preserving the certified "no
   source special-cased" property). If rejected: reopens
   `judgments/subtract-attack.md` Attack 3 — the design's only remaining
   defense against a single dishonest producer manufacturing a
   self-corroborating chain of distinct-looking ids is deleted along with
   the enum.
5. **`Rule.check` runs sandboxed: no ambient pool/global access; the only
   claim content readable inside `check` is what's explicitly passed as
   `premises`/`target`.**
   If rejected: reopens the citation-omission-laundering attack found
   against `invert`/`evidence` (§6 row 6) — an undeclared internal reference
   between two claims becomes possible and invisible to the acyclicity
   check.
6. **The acyclicity check is specified as bounded DFS from `target` through
   `premises` per submission (or an incremental topological-order
   algorithm), explicitly not "union-find," with its real worst-case cost
   disclosed.**
   If rejected: keeps a technically incorrect complexity claim
   (`judgments/subtract-attack.md` Attack 6 — union-find does not solve
   directed-cycle detection) load-bearing in the certified record.
7. **`Payload` is not raw `unknown`; each `Rule` declares typed
   `premise_types`/`target_type`, narrowed by the calling convention before
   `check` is invoked.**
   If rejected: every rule author is forced into `--[[:! T]]` force casts
   inside every `check` body — which CLAUDE.md calls "almost never
   correct" — and the exact narrowing failure that produced the
   nil/absent-conflation bug class (row 2 of §6) becomes invisible to
   `bin/cr check` by construction (`judgments/primitive-attack.md` Attack 5:
   "shipping the typechecker's own kernel substrate in a form its own tool
   is blind to").
8. **◇-claim refutation is realized as an ordinary `Proved(□¬φ)`-shaped
   edge, requiring `Rule.check` to receive each premise's currently-
   established `verdict` alongside its `payload` (not payload alone).**
   If rejected: Hole H3 (◇-refutation) returns to being a separate,
   undesigned hole rather than falling out for free, as it does in
   `evidence`'s certified-worth-keeping idea.
9. **The producer-coordination/addressing-registry problem (§4.2) is named
   as its own scheduled substrate deliverable — an interop contract with a
   named owner and review gate — required before or alongside the first
   producer library, not assumed solved by any mechanism in this document.**
   If rejected (i.e., if left implicit): whoever builds the first producer
   library reintroduces the 2174-shrug under new vocabulary, exactly as
   demonstrated against `evidence`'s address algebra
   (`judgments/evidence-attack.md` Attack 1).
10. **Fork (b) — whether a mechanized Lua evaluator is trusted-core surface
    or an ordinary producer-side `Rule.check` implementation — is left an
    explicit open owner call (§5), defaulting to producer-side unless the
    owner certifies otherwise.**
    If rejected in favor of baking the evaluator into the trusted core: the
    trusted surface grows to include a mechanized stepper whose
    termination-vs-30s-timeout and LuaJIT-vs-vanilla-5.1-fidelity problems
    (`judgments/invert-attack.md` Attacks 6-7, `judgments/evidence-attack.md`
    Attack 4) are, per this pass's evidence, unresolved by any candidate —
    that cost should be accepted knowingly, not by default.

## 8. What this proposal does NOT claim

Honestly listed, not implied solved by any mechanism above:

- **Rule-honesty/correctness is kernel-unverifiable in principle.** No
  structural change closes this; it is the shared limit every candidate and
  every judge names. The strength/witness-claim machinery (grafts 2-3) makes
  violations *visible in the receipt*, not impossible.
- **The producer-coordination/addressing-registry problem (§4.2) is
  unsolved**, named as substrate, not closed.
- **Correlated-error corroboration** between independently-wrong producers
  has no kernel-level defense (§6 row 4).
- **Heap/aliasing, metatable-mediated dispatch, closures/upvalues over
  shared mutable state, coroutines, and non-local control transfer
  (`pcall`/`error`)** are untouched by every candidate in this pass and
  remain open exactly as `research/ceiling-survey/judgment.md` §5 names them
  ("heap/aliasing under unrestricted dynamic mutation — only E even names
  it, none has a mechanism").
- **The semantics-reality gap** (fidelity of any evaluator, if built, to
  real FFI/eval/OS behavior) is open regardless of fork (b)'s resolution —
  named by every ceiling-survey entrant as its likeliest death
  (`research/ceiling-survey/judgment.md` §5, "the semantics–reality gap...
  every entry names it as its likeliest death").
- **The budget-vs-limit gap** — whether the realized frontier of
  Proved/Refuted verdicts provably approaches the computability frontier at
  feasible cost — is not resolved; this design, like every candidate,
  reaches its ceiling only asymptotically (`research/ceiling-survey/judgment.md`
  §5 item 3).
- **Cost at repo scale is unestimated.** No candidate sized DFS/fixpoint
  cost against a realistic pool size beyond the 8-file, 2401-claim
  first-slice corpus; the 30-second pre-commit timeout constraint is named
  as a risk (§5, §7 item 10) but not measured against.
- **Whether this kernel discipline fits inside the project's stated
  interactive-tooling bar** ("bun general, tsgo typechecker") is not
  measured — flagged, not resolved.
