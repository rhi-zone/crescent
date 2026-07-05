# Candidate: invert — the kernel understands nothing, not even comparability

Frame: flip who owns the vocabulary. The dead draft's kernel knew claim forms
(arrives/reachable/paired/...) and producers filled blanks inside them. Here
the kernel owns *zero* claim vocabulary — not the claim forms, not even the
notion that two claims are "about the same thing." Producers own all
semantic work and must hand the kernel something it can check without
understanding: a **certificate**. The kernel's only competence is replaying
certificates against two things it does trust — a small operational model of
real Lua evaluation, and a small, fixed, versioned calculus of
content-blind structural inference rules — plus one graph check that
enforces the certified law.

## 1. The design

### 1.1 What a claim *is*, to the kernel

A claim is not a syntactic form. It is an opaque handle bundled with an
**executable predicate over trusted traces**:

    Claim = { id : ClaimId,  holds : Trace* -> boolean }

`Trace*` (not `Trace`) on purpose — nothing in the kernel fixes the arity.
A claim closing over one trace is an ordinary safety/liveness claim; a claim
closing over two is a hyperproperty (H4's uniformity class falls out for
free — see §4). The kernel never inspects `holds`'s body, never asks what
"site," "slot," "non-nil," or "reachable" mean. It only ever *calls* `holds`
on a `Trace` the trusted evaluator produced, or checks a proof term whose
leaves bottom out in such calls.

Claim forms, site/slot addressing, strata, S-param/S-return splitting,
axiom/stated/mined generation rules — all of J1-J5's vocabulary from the
pre-collapse draft — live entirely on the producer side now, as library code
that *builds* `holds` closures. None of it is in the trusted core. This is
the literal inversion: the draft's J4 (provenance rules) generated typed
claim objects the kernel's J2/J3 knew how to evaluate; here J4-shaped code
still exists, but purely as an untrusted producer library, and what it
outputs is graded down to the single opaque interface above.

### 1.2 What the kernel trusts

Two small trusted surfaces, each independently justified the way HM takes
λ-evaluation as given:

**(a) The evaluator.** A mechanized stepper for Lua 5.1's real operational
semantics — one rule per language form (assignment, call/return incl.
method-call desugaring `o:m(a) ⟿ o.m(o,a)`, branch-taken, metamethod
dispatch, error propagation) — that, given a concrete input, produces a real
`Trace` (a finite prefix of evaluation events). This is J1 from the draft,
unchanged in kind: taken as given, not derived. It is the kernel's only
source of *ground truth about execution*.

**(b) The structural proof calculus.** A small, fixed, versioned set of
inference rules for combining `holds`-shaped predicates into proofs of
*universally* quantified facts (`□` claims, and — see §4 — refutations of
`◇` claims), where every rule's soundness is stated and proved once, at the
meta level, in terms of the evaluator's own stepping relation — never in
terms of any claim's content. Candidate rule shapes (illustrative, not
exhaustive — the exact rule set is itself a substrate deliverable, see §5):

- **replay**: a claim is proved/refuted for a *specific* input by running
  the evaluator on that input and calling `holds` on the resulting trace.
  (Existential engine. Also used, dualized, to refute `□` claims: one
  witness trace where `holds` returns false.)
- **seq/branch/call structural composition**: if a proof term establishes a
  fact about the pre-state of a statement and another about how that
  statement's rule (from the evaluator) transforms state, the calculus
  combines them into a fact about the post-state — Hoare-shaped, but the
  "facts" plugged in are opaque predicates, not a fixed assertion language.
- **induction over trace position**: given a base-case replay proof and an
  inductive step expressed as "the evaluator's rule for event class X
  preserves predicate P," conclude P holds at every trace position of that
  class.
- **constant-fold**: literal expressions (e.g. a condition that is
  syntactically `false`) are evaluated directly by the evaluator on the
  subterm alone, with no state dependency — grounds "this branch is
  unreachable" proofs.

None of these rules mention "non-nil," "self," "reachable," or any claim
vocabulary. They mention only: evaluator rule names, trace positions, and
opaque predicates treated as black boxes satisfying propositional
combinators (and, not, implies-under-a-derivation). That is the entire
trusted-inference surface.

### 1.3 Certificates

A **Certificate** is what a producer submits per claim, per role:

    Certificate =
      | Witness { input : ConcreteInput }
          -- kernel: run evaluator(input) -> trace; check claim.holds(trace)
          -- against the polarity being claimed. O(evaluator cost). Always
          -- checkable in finite time given a finite input+bounded trace.
      | Proof { rule : RuleName, premises : Certificate[], claim : ClaimId }
          -- kernel: recursively verify each premise, then verify this
          -- rule's structural precondition holds of (premises, claim) per
          -- the fixed calculus in 1.2(b). Finite DAG, checked bottom-up;
          -- rejected if it doesn't terminate in a bounded number of nodes
          -- (no infinite/self-referential proof terms admitted).

A **Verdict** is Proved(cert) / Refuted(cert) / Open(receipt), where
`receipt` is nothing but "which certificate was attempted and where
replay/rule-matching failed or was never supplied" — mechanically produced,
never a kernel judgment about the claim.

### 1.4 The pool and the one law, made content-blind

Pool entries are `(claim, role, provenance-tag)`. `role ∈
{hypothesis, obligation}`; `provenance-tag` is pure metadata (stated / axiom
/ mined / whatever a fourth producer invents tomorrow — the kernel never
switches on it, satisfying "no source special-cased anywhere," literally:
the tag isn't even read by the checking code, only by the reporting layer).

The certified one law — *a claim admitted as hypothesis must independently
survive as obligation* — is enforced as a **graph acyclicity check**, and
this is the one piece of "comparability" the kernel is allowed: not
comparability of claim *content*, but comparability of *certificate
dependency edges*, which are structural, not semantic.

Every `Proof` certificate that used claim H (in hypothesis role) as a
premise creates a dependency edge `obligation-proof(O) --uses--> H`. The
kernel additionally requires: for every claim admitted with role
`hypothesis`, there exists *some* certificate that independently discharges
it as an `obligation` (Proved or Refuted on its own), and that certificate's
dependency graph does not route back through any proof that itself depended
on H-as-hypothesis. This is a topological/DAG check over certificate
provenance edges — pure graph theory, zero claim semantics, and it is the
*only* cross-claim operation the kernel performs. It replaces "the kernel
understands consistency between two claims" with "the kernel understands
whether a dependency graph has a cycle," which is exactly the promised
inversion: consistency-checking is pushed entirely to whatever proof/witness
a producer submits; the kernel's own comparison operation touches edges, not
meanings.

### 1.5 Build order (substrate before consumers)

1. Evaluator (trusted Lua 5.1 stepper) — nothing else typechecks without it.
2. Certificate replay engine for `Witness` (needs only 1).
3. Fixed structural proof calculus + `Proof` replay/verification (needs 1;
   design of the rule set is itself the H1 deliverable, scoped and versioned
   — see §5).
4. Pool + dependency-graph acyclicity check (needs 2+3 to produce edges).
5. Producer libraries (harvesters emitting `Claim`+`Certificate` pairs) —
   explicitly last, explicitly untrusted, explicitly where all of
   stated/axiom/mined vocabulary, site/slot addressing, and derivation
   heuristics live.

## 2. Concrete realization sketch (Lua-shaped)

```lua
--:: kernel/types.lua  (TRUSTED)
--:: Trace = { events: Event[] }
--:: ClaimId = string  -- opaque handle, kernel never parses it
--:: Claim = { id: ClaimId, holds: (...: Trace) -> boolean, arity: integer }
--:: Certificate =
--::     { tag: "witness", input: ConcreteInput, polarity: boolean }
--::   | { tag: "proof", rule: string, premises: Certificate[] }
--:: Verdict = { tag: "proved", cert: Certificate }
--::         | { tag: "refuted", cert: Certificate }
--::         | { tag: "open", receipt: string }

--:: kernel/evaluator.lua  (TRUSTED — real Lua 5.1 operational semantics)
-- M.run(chunk, input) -> Trace | (nil, errmsg)
-- One function per evaluation rule internally; not exposed to producers
-- except via M.run and M.step (single-event stepping, for proof replay).

--:: kernel/calculus.lua  (TRUSTED — fixed, versioned rule table)
local RULES = {
  seq_compose  = function(premises, claim) --[[ structural check ]] end,
  induct_trace = function(premises, claim) --[[ structural check ]] end,
  const_fold   = function(premises, claim) --[[ structural check ]] end,
  -- exactly this table is the "no fixed claim vocabulary" boundary:
  -- adding a rule here is a trusted-core version bump, never a per-claim
  -- special case (see honest limits, §4/§5)
}

--:: kernel/check.lua  (TRUSTED)
--: (Claim, Certificate) -> boolean, string?
local function check(claim, cert)
  if cert.tag == "witness" then
    local trace, err = evaluator.run(program, cert.input)
    if not trace then return false, "evaluator: " .. err end
    return claim.holds(trace) == cert.polarity, nil
  elseif cert.tag == "proof" then
    local rule = RULES[cert.rule]
    if not rule then return false, "unknown rule: " .. cert.rule end
    for _, p in ipairs(cert.premises) do
      local ok, e = check(p.claim, p.cert)  -- recursive, DAG, depth-bounded
      if not ok then return false, e end
    end
    return rule(cert.premises, claim), nil
  end
end

--:: kernel/pool.lua  (TRUSTED)
-- admit(claim, role, tag) -> entry
-- submit(entry, cert) -> Verdict, and records a dependency edge if cert.tag
--   == "proof" and any premise's claim has role == "hypothesis"
-- law_check(pool) -> ok, cycle?   -- the one law, as acyclicity

--:: producer/harvest_selfnonnil.lua  (UNTRUSTED — one of many producer libs)
-- Builds a Claim whose `holds` closes over "the binding named `self` at
-- this trace's entry event is ~= nil", and a Proof certificate using
-- rule "seq_compose" chained from the evaluator's own R-METHODCALL rule
-- (receiver must be non-nil to perform table-index dispatch, else an err
-- event fires first — cites the err-absence axiom, itself just another
-- pool entry, as a premise). This file knows what "self" and "colon-call"
-- mean; kernel/*.lua never does.
```

## 3. Kill-test walkthroughs

### 3.1 The five corpus instances

1. **`lib/lru/init.lua:155 deref:self non-nil`.** Producer's `holds` closure:
   `function(tr) return tr:binding_at_entry("self") ~= nil end`. Certificate:
   a `proof` using `seq_compose`, premises = [the evaluator's own
   `R-METHODCALL` stepping rule instantiated at this call site (a
   `Witness`-checkable fact about *this program's* AST: is `Cache:peek`
   defined with `:` syntax? — decided by literal parse, not opinion), the
   pool's `err`-absence axiom as a hypothesis]. Kernel replays: confirms the
   method-call rule's precondition (non-nil receiver required to avoid an
   `err` event) via the evaluator, confirms the axiom entry exists and its
   own obligation-side discharge exists elsewhere in the pool (satisfying
   the one law), emits **Proved**. No kernel code ever branches on "self."

2. **`lib/json/init.lua:125 deref:HEX non-nil`.** Producer's certificate:
   `induct_trace` proof — base case a `Witness` replay of the module chunk's
   top showing `bind(HEX, {})` produces a non-nil table (table-constructor
   evaluation is a trusted evaluator rule: constructors never produce nil);
   inductive step a syntactic scan (producer-side, untrusted) asserting no
   further `bind(_, HEX, _)` event exists between that point and line 125,
   submitted as a `Witness`-checkable claim over the *trace itself*
   (`holds(tr) = no bind event named HEX after position p0 and before
   p_125`) — the kernel checks this by literally scanning the trusted trace
   it already has, not by trusting the producer's static-scan claim.
   **Proved.**

3. **`lib/queue/init.lua:157 deref:FIFO non-nil`.** Identical certificate
   shape to (2), shorter range. **Proved.** — same reused proof schema, not
   a second rule.

4. **`lib/deque/init.lua:62-65 deref:self ×4`.** Same certificate schema as
   (1), instantiated four times (or amortized: one `Proof` whose conclusion
   is `□(every deref of self in this function's body is non-nil)`, and the
   four site-specific claims are each proved by a trivial witness
   projection of that one universal). This is the corpus report's own
   observation ("H1's payoff is per-rule, not per-claim") realized exactly:
   the *rule* (`seq_compose` over `R-METHODCALL`) is reused; the kernel adds
   no new machinery per occurrence.

5. **`lib/bigint/init.lua:115 branch:then reachable`.** Producer's cheapest
   move: a `Witness` certificate — a concrete input for which the evaluator
   actually reaches that site (produced by e.g. a fuzzer, or by hand). If no
   witness is found, the *dual* is available: refuting `reachable` requires
   proving `□¬happens(s)` — a universal claim, same shape as (2)/(3)/(4),
   handled by the same calculus (see §4 unification of H3). If neither a
   witness nor a full unreachability proof is available, the claim stays
   **Open**, and the receipt says exactly which certificate kind was
   missing — not "the kernel doesn't understand reachability," but "no
   certificate of either shape was submitted or replayed successfully."

### 3.2 Self-carried-semantics (not string comparison)

The first slice's 2174-shrug failure was a *coincidence of naming*: stated
claims keyed `entry(f):x` never lexically match mined claims keyed
`deref:x`, so a topic-matching check (string/tuple equality on site+slot)
never fires, even when a human sees they're "about the same fact." Under
this design there is no topic key at all — claims are never compared by
name, ever. The only comparison the kernel performs is: does a submitted
`Proof`'s premises, when replayed against the *trusted evaluator's actual
trace*, satisfy the cited rule's structural precondition? That is a semantic
check (it runs real evaluation and calls real predicates), not a syntactic
one. Two claims that "are about the same thing" only become related when a
producer builds a certificate that *uses* one predicate's truth to help
establish another's — and that use is checked by executing both predicates
against the same trusted trace, not by comparing how they're spelled. There
is no path in this kernel that degrades to string comparison, because there
is no string comparison anywhere in `kernel/check.lua` — every check bottoms
out in either running the evaluator or applying a fixed structural rule.

### 3.3 Ceiling

The kernel imposes **no ceiling on claim content** — any predicate over any
number of traces is admissible; arity, vocabulary, and addressing scheme are
entirely producer-chosen (this is also why H4's hyperproperty gap dissolves:
`holds` was never restricted to one `Trace` argument, so a 2-safety claim is
just an ordinary claim with a two-trace closure — no extension needed, no
kernel change needed).

The kernel **does** impose a ceiling on what can be *certified*: exactly the
set of claims for which some producer can build a *finite, well-founded*
certificate out of (a) concrete witness replay — semi-decidable, cheap,
terminating, and (b) finite compositions of the fixed structural calculus's
rules — also semi-decidable (search may not terminate, but a *found* proof
term is checked in finite bounded time). This is precisely the "r.e., not
recursive" ceiling the ceiling-survey's FP entry named as forced by Rice's
theorem for any fixed system over a Turing-complete language (judgment.md
§1 item 9, §2 FP). Nothing here escapes that; the design doesn't claim to.
What it does claim: the *claim layer* of that ceiling is now maximally
open — the calculus's rule table can grow (a versioned, meta-proved,
trusted-core change, never a per-claim special case) to admit new proof
shapes over time, which is the honest, non-silent way to push the realized
frontier toward the r.e. limit without ever faking a Proved. This
instantiates the ceiling-survey's convergent element #4 ("small trusted
certificate-checking kernel; provers are untrusted heuristic engines") and
#5 (dovetailed prover/refuter — here, Witness and Proof are simply the two
certificate shapes, checked by the same replay engine) at the claim level,
which is exactly what the owner's framing asked this pass to produce.

## 4. What it hides / assumes

- **The evaluator's fidelity to real Lua 5.1 semantics (FFI, `eval`,
  metatables, OS interaction)** is assumed given, exactly as the draft's J1
  assumed it. This is the semantics-reality gap every ceiling-survey entrant
  named as its likeliest death (judgment.md §1 item 11); this design does
  not solve it, only relies on it as an external, versioned, separately
  audited artifact.
- **The structural proof calculus is not optional connective tissue — it is
  unavoidable trusted surface.** Pure witness-replay alone only ever
  produces existential facts (a claim held *here*) and refutations of
  universal claims (a claim failed *here*). Every *proved-fine* universal
  claim needs some fixed rule set to combine facts, or there is no kernel at
  all — only producers vouching for themselves. So "no fixed vocabulary in
  the kernel" is true of *claims*, but not fully true of *inference*: some
  small, fixed, meta-proven set of structural rules is irreducibly part of
  the trusted core. This is the one place the inversion cannot go all the
  way — and it's honest to say so rather than claim a vocabulary-free
  kernel that also somehow proves universal facts for free.
- **The calculus's rule set is not designed here.** §1.2(b) sketches rule
  *shapes* (seq/branch composition, trace induction, constant-fold);
  designing the actual minimal-and-sufficient rule table, and proving each
  rule sound against the evaluator once, is real, scheduled, substrate work
  — this candidate proposes its *place* in the architecture (step 3 of the
  build order, §1.5) and its *closure property* (content-blind, evaluator-
  grounded), not its final contents.
- **Certificate-authoring cost is pushed entirely onto producers.** The
  kernel does no search; it only replays. This mirrors the ceiling-survey's
  forced convergence #8 (human/producer as untrusted hint supplier, always
  machine-checked) but means a producer ecosystem (harvesters + proof
  synthesizers) has to exist and be nontrivially capable before *any*
  Proved/Refuted verdicts appear — the corpus's 100%-Open result is not
  fixed by this kernel alone; it's fixed by producers this design makes
  *possible* to write (§3.1), not producers this design *ships*.
- **Termination/well-foundedness of `Proof` DAGs is assumed enforceable** by
  a depth/node bound at replay time; a producer submitting a certificate
  that fails to terminate checking is simply rejected (Open, receipt
  "certificate too large / did not terminate"), never trusted partially.

## 5. Honest trade-offs

**Strong:**
- Maximal fidelity to the owner's inversion frame: the kernel's claim-level
  vocabulary is genuinely, provably empty — not "small," empty. Everything
  J1-J5 tried to fix (site heterogeneity, S-param/S-return splitting, axiom
  catalogs, belief-presupposition catalogs) is *entirely* producer-side, so
  none of it can regress the kernel; producers can iterate on addressing
  schemes freely without touching trusted code.
- Directly dissolves the first-slice's actual failure mode (topic-key
  mismatch) rather than patching it — there is no topic key to mismatch.
- H3 and H4 stop being separate holes: H3 (◇-refutation witness) becomes an
  ordinary use of the same universal-proof calculus as any □ claim; H4
  (hyperproperties) was never excluded because arity was never fixed. Two
  of the draft's five holes close as a side effect of the inversion, not
  because they were specifically targeted.
- The one law becomes a single, generic graph-acyclicity check — genuinely
  content-blind, and genuinely the *only* cross-claim operation in the
  kernel, which is a clean, auditable trusted-core boundary.

**Thin:**
- The proof calculus is real, load-bearing, undesigned trusted surface —
  this candidate locates it and bounds its shape but does not deliver it.
  Anyone reading this as "the kernel is now trivial" is wrong; the kernel is
  *small and closed*, not *simple to build*. Designing a calculus expressive
  enough to be useful, yet small enough to keep proving sound as it grows,
  is real ongoing work (versioned trusted-core changes), and a sloppy
  calculus (rules shaped like "colon-call self is non-nil" baked in as a
  named rule, instead of derived from `R-METHODCALL` + `err`-absence) would
  silently reintroduce exactly the special-casing this frame forbids — the
  design is only as abstract as its rule table is kept general, and nothing
  in the kernel *mechanically* prevents someone from writing a
  domain-shaped rule later. That discipline has to be maintained by review,
  not enforced structurally.
- No portfolio/search story: this candidate is purely the *checking* half.
  It says nothing about how producers efficiently find witnesses or proof
  terms at corpus scale (V's volume tier, AI's repair loop, FP's fair
  enumerator) — by design (that's explicitly OPEN, producer-side), but a
  reader looking for "how do we get more Proved verdicts in practice" won't
  find it here.
- Certificate bookkeeping (dependency graph over potentially thousands of
  claims × proof premises) has unaudited cost/complexity; the acyclicity
  check is conceptually simple but its practical graph size at corpus scale
  (2401 claims in 8 files, per first-slice-run.md) is unestimated here.
- Grade/credence is, as already certified, purely a reporting-layer sort
  key in this design too — nothing above changes that, but it's worth
  restating: grade never enters `check()` or `law_check()`, only the pool's
  reporting view.
