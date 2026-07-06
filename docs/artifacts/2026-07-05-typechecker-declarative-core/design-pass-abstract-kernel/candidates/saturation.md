# Fifth candidate — saturation kernel (owner proposal, evaluated)

Status: candidate under evaluation, not certified. Method matches the other
four: develop concretely, then attack with the same corpus the four
`candidates/*.md` faced (`judgments/*-attack.md`), then compare against
`synthesis.md`'s trusted-surface inventory mechanism-by-mechanism. Nothing
below is presented as settled that isn't cited to a re-derivation performed
in this document or to one of the four prior attack reports.

Owner's proposal, verbatim intent: normalization/rewrite rules (+ maybe
"propagation" rules, possibly the same thing) + conflict-checking is
sufficient as the entire algorithm — no separate edge-graph/acyclicity
machinery, no strength-matching pass, no certificate DAG, unless those fall
out of the rewrite discipline naturally.

## 0. The load-bearing ambiguity, surfaced first

The owner's own phrasing contains a real fork, not a manufactured one:
"rewrite rules... although technically they might be rewrite rules too"
names two readings that have **opposite soundness properties**, and every
answer below bifurcates on which one is meant. Both are legitimate
instantiations of "saturation," both appear in the requested prior-art
shelf, and the owner's proposal doesn't pick between them — so this can't be
resolved by picking one and writing confidently; it has to be named as the
fork it is.

**Reading A — monotone fact accumulation (Datalog/CHR-propagation shape).**
Claims are ground atoms over a term algebra. Rules only ever *add* new
ground atoms derived from atoms already present (CHR's `==>`, or a Datalog
rule body); nothing is ever deleted or merged. "Canonical form" means: a
claim's address is a ground term, and two claims meet iff their ground terms
are syntactically identical (or become identical after some rules fire).
The store only grows.

**Reading B — genuine term rewriting with replacement (Knuth-Bendix/egraph
shape).** "Normalize toward canonical form" is read literally: a
representation is *replaced* by a smaller/canonical one (CHR's `<=>`,
Knuth-Bendix reduction, egraph congruence-closure merging of equivalence
classes). Two claims meet iff they reduce to — or get merged into — the
same class, and that merging is a real, potentially irreversible operation
on the term store's identity structure, not just an added fact.

These are not cosmetic variants of the same idea. Reading A gets two of the
incumbent's hand-built mechanisms for free, as theorems, not checks (§2).
Reading B does not get them for free and additionally reopens two hard,
classically unsolved problems (confluence via critical pairs, termination
via reduction orderings) that the incumbent never had to solve at all. The
owner's one-line formulation is compatible with both; I develop and attack
both below rather than silently picking the more favorable one.

## 1. Concrete development

### 1.1 Terms in Lua-implementable shape

A claim is a ground term over a small functor algebra — exactly the shape
`evidence.md`'s `Address` used, and exactly the shape found decorative there
(`judgments/evidence-attack.md` Attack 1) when nothing assigns ownership of
the shared functor vocabulary. That finding is not re-litigated here (§3
addresses it directly) — it is inherited unless something about rewriting
changes it, which §3 checks rather than assumes.

```lua
--:: Term = { functor: string, args: { [integer]: Term, ... } }
        | { atom: string }                     -- 0-ary leaf
--:: Claim = { term: Term, polarity: "supports" | "refutes" }
```

### 1.2 Rewrite/propagation rules

Reading A (propagation, non-destructive):

```lua
--:: PropRule = {
--::   id: string,
--::   heads: { [integer]: Pattern, ... },   -- patterns matched against
--::                                          -- the current fact store
--::   guard: (bindings: { [string]: Term }) -> boolean | nil,  -- arbitrary
--::                                          -- producer code, same trust
--::                                          -- status as subtract's
--::                                          -- Rule.check
--::   body: (bindings) -> Term,             -- new ground fact to ADD
--:: }
```

`M.saturate(store, rules)` repeatedly finds `(rule, bindings)` pairs where
every `head` pattern unifies against some already-present fact, runs
`guard`, and if it passes, adds `body(bindings)` to the store — until no
rule fires (a genuine fixpoint over a monotone operator on the powerset
lattice of ground terms, terminating because the Herbrand universe reachable
from a finite initial pool under a finite rule set with no fresh-symbol
generation is itself finite; see §4.1 for what happens if that constraint is
dropped).

Reading B (rewriting, destructive):

```lua
--:: RewriteRule = {
--::   id: string,
--::   lhs: Pattern,
--::   rhs: (bindings) -> Term,   -- REPLACES lhs's match, does not add
--:: }                            -- alongside it
```

`M.normalize(store, rules)` repeatedly rewrites any subterm matching some
`lhs` to `rhs(bindings)`, merging the rewritten term's equivalence class with
whatever it reduces to (egraph-style), until no rule applies. Two claims
"meet in canonical form" iff their terms end up union-find-equivalent after
normalization.

### 1.3 Conflict

Structural, not domain-specific, under either reading: a fixed sentinel term
`⊥` (or, equivalently, "the store now contains both `supports(A)` and
`refutes(A)` for the same canonical `A`"). Reaching `⊥` — by any rule,
producer-authored, the kernel never interprets which — is Refuted. A claim
whose canonical address is present with `supports` polarity and never
reaches `⊥` through saturation is corroboration/Proved-relevant. Neither
happening (the claim's address never appears at all, or appears only
`supports` with no independent second derivation) is Open — same
three-valued shape as `declarative-design.md`'s certified law, expressed as:
does the store, at fixpoint, contain a conflict touching this claim's
canonical address.

### 1.4 Where the three sources and the one law land

- **Three generation sources** (stated/axiom/mined): unchanged — still an
  `admit`-time tag on how a ground fact entered the store, orthogonal to
  whether facts are related by rewriting or by graph edges. Nothing about
  saturation changes this; synthesis.md's delta 4 (kernel-assigned,
  never-branched-on provenance) carries over verbatim.
- **The one law** ("a claim used as hypothesis must independently survive as
  obligation"): under Reading A, this is *not* a separate check — it is a
  theorem about the least fixpoint of a monotone operator (Knaster–Tarski):
  every fact in the least fixpoint has a *finite, well-founded derivation
  tree* bottoming out in rule instantiations whose bodies were already
  satisfied at a strictly earlier point in the accumulation. A fact cannot
  be its own sole support, structurally, the same way a Datalog `p(X) :-
  p(X)` rule with no other rule deriving `p` never derives anything — this
  is developed fully in §2.2, because it's the single most important
  subsumption claim in this document and needs to be shown, not asserted.

### 1.5 The 5 corpus instances, re-derived honestly (not overclaimed)

Encoding each instance's flagship rule as a Reading-A propagation rule and
re-deriving, rather than narrating success:

1. **`lru/init.lua:155 deref:self`.** Rule: `nonnil(F, Line, "self") :-
   def_form(F, "colon"), receiver_param(F, "self"), deref_site(F, Line,
   "self")`. Re-derive: this pattern-matches the exact same premise as
   `subtract`'s `colon-self-nonnil-v1`, and is **wrong for the identical
   reason** `judgments/subtract-attack.md` Attack 1 found — colon
   *definition* syntax places no obligation on callers; the rule inspects a
   definition-site fact and asserts a call-site-universal conclusion.
   Rewriting this into Datalog notation changes nothing about its logical
   content. **Breaks, identically.** I am not claiming this instance closes
   under saturation; presenting it as closing would repeat exactly the
   mistake all four prior candidates' judges caught.
2. **`json/init.lua:125 deref:HEX`.** Rule: `nonnil(F, Line, X) :-
   single_assignment(F, X), assigned_kind(F, X, "table"), deref_site(F,
   Line, X)`. Same partial weakness as `subtract`'s version: no ordering/
   dominance check between the assignment and the dereference — the pattern
   match on variable name alone doesn't verify the deref is control-flow-
   after the assignment. **Mostly survives, same disclosed gap as before,
   not fixed by rewrite framing.**
3. **`queue/init.lua:157 deref:FIFO`.** Identical shape to #2, same caveat.
4. **`deque/init.lua:62-65 deref:self` ×4.** Same rule as #1, same break,
   ×4 — saturation's "one rule fires against every matching set of facts in
   the store" is a genuine, structural amplification property (a true
   virtue when the rule is sound), but it amplifies Attack 1's error
   identically to how `subtract`'s reused edge-rule did.
5. **`bigint/init.lua:115 branch:then reachable`.** No rule's head matches
   `reachable(F, "then")` in this minimal rule set. Honestly Open, and the
   saturation framing gives a marginally sharper receipt than the graph
   framing did: "no rule head unifies with this canonical address" is a
   structural, checkable fact about the rule set (can be computed by
   pattern-indexing the rule heads against the address, without running
   saturation at all), whereas the incumbent's receipt ("no registered rule
   connects...") required inspecting the accepted-edge set. Small, real,
   not load-bearing.

**Net**: identical outcome to the incumbent on all 5 — 3 of 5 broken by the
same underlying rule defect, 1 honestly Open, 1 partially weak. This is
expected and important: the corpus instances test rule *content* (is the
inference actually sound), and no kernel-shape change — graph, rewrite, or
otherwise — touches rule content. Any candidate claiming a shape change
alone fixes these 5 instances would be repeating the four-for-four failure
`synthesis.md` §4.1 documents. Saturation does not repeat it here because
I'm not claiming a fix; I'm showing the re-derivation lands exactly where
the rule-honesty limit (shared by every candidate, `synthesis.md` §8) says
it must.

## 2. Subsumption check against `synthesis.md`'s trusted surface

For each mechanism, under Reading A first (the reading where subsumption
claims are strongest), then Reading B where it differs materially.

### 2.1 Acyclicity law (delta: the base mechanism itself)

**Reading A: genuinely subsumed, as a theorem rather than a check.** This is
the strongest claim in this document and deserves the derivation, not an
assertion. `close`'s job in the incumbent is: accept edges one at a time,
reject any edge whose addition would create a path from `target` back to
itself, and finally compute a fixpoint over the accepted edges. Under
monotone fact accumulation, there is no edge-admission step at all — there
is one global operation, `saturate`, defined as: start from the initial
fact set F₀ (the admitted claims), and repeatedly apply
`F_{i+1} = F_i ∪ {body(bindings) : rule ∈ rules, bindings satisfies every
head pattern against F_i and guard(bindings)}` until `F_{i+1} = F_i`. This
is the standard Datalog/CHR-propagation fixpoint, and it is a textbook fact
(Knaster–Tarski, specialized to this setting) that the least fixpoint of a
monotone set operator contains no element whose *only* derivation depends on
itself: every fact in `F_∞` has a finite derivation history bottoming out at
`F_0` (facts with no rule-derivation, i.e. admitted directly) or at rule
instantiations whose every head was satisfied at some strictly earlier
`F_i`. A fact cannot support itself because it cannot appear in `F_i` before
it appears in `F_{i+1}`, and `F_{i+1}`'s new members are computed *from*
`F_i`, never from themselves. This is exactly, word for word, what
`declarative-design.md`'s certified law demands ("a claim used as a
hypothesis must independently survive as an obligation") — and it requires
no DFS, no union-find, no per-submission graph-reachability query at all.
It is a property of the evaluation strategy (accumulate from empty,
monotonically), not a separately-argued and separately-buggy check —
directly closing the exact defect `judgments/subtract-attack.md` Attack 6
found (union-find doesn't detect directed cycles) by making the whole class
of "did we implement cycle detection correctly" question moot: there is no
cycle-detection algorithm to get right or wrong, because self-support is
unrepresentable in the fixpoint's construction, not merely forbidden by a
check bolted alongside it.

**Caveat, load-bearing, not cosmetic: this only holds for the positive
fragment.** The moment a rule needs a *negative* premise ("Y holds only if X
is NOT independently derivable" — needed for `refutes`/conflict detection
and for stratified defaults), the operator is no longer monotone, and the
clean Knaster–Tarski argument stops applying without more structure. Datalog
handles this via **stratification**: partition rules into layers such that
a rule's negative premises only ever reference predicates fully computed in
a strictly earlier layer, then compute the fixpoint layer-by-layer. That
stratification requirement is itself a DAG (over predicates/rules, not over
individual facts) with an acyclicity condition on it — so the graph does not
vanish, it **shrinks**: from "one node per pool entry, one edge per
citation, acyclicity checked at every submission" (incumbent, O(claims)-
scale) to "one node per predicate/rule, acyclicity checked once when the
rule set changes" (saturation, O(rules)-scale, far smaller in practice since
the corpus has 2401 claims but a handful of rule families). This is a real,
reportable simplification — smaller trusted surface, checked far less often
— but it is **not** the claimed elimination of "separate edge-graph/
acyclicity machinery." It is the same machinery, moved to a coarser grain
and a lower frequency. Framing it as "gone" would be exactly the
result-deficit-dressed-as-substrate-gap error CLAUDE.md's planning
discipline forbids; framing it honestly, it's a genuine win in scale, not a
win in kind.

**Reading B: not subsumed, and actively reintroduces the check in a harder
form.** Genuine rewriting-with-replacement has no Knaster–Tarski guarantee
against circularity in the same clean sense, because replacement can
introduce apparent "support" for a term through a chain of merges that
doesn't correspond to any well-founded derivation order — an egraph merging
class `A` and class `B` via one rule, then a second rule using the merged
representative to justify re-deriving something that feeds back into `A`,
is exactly the shape a congruence-closure engine can produce without
tracking *why* each merge happened (this is precisely why real
proof-producing egraphs carry an explicit **explanation/justification DAG**
alongside the congruence structure — e.g. egg's proof production, or
Simplify's/Z3's congruence-closure explanation graphs — specifically because
the merged-representative structure alone does not preserve derivation
provenance). That justification DAG is, again, the edge-graph — reappearing
as a documented, standard requirement of building a *sound, explainable*
egraph, not an incumbent-specific quirk this proposal happens to avoid.

### 2.2 Strength admissibility (existential vs. universal)

**Partially subsumed, by a different mechanism than "rewriting" per se.**
Both readings can exploit the Horn-clause structure: a *rule* with a free
variable (`nonnil(F, Line, X) :- single_assignment(F, X), ...`) is
universally quantified over every `F`/`X`/`Line` binding that satisfies its
body, while a *ground fact* (admitted directly, no free variables) is
existential by construction — this distinction is intrinsic to the rule/
fact split, not something bolted on as an edge-metadata enum. That's a
genuine, structural simplification over `synthesis.md`'s graft 2 (a
producer-declared `strength` tag on every edge, separately checked for
admissibility) — the tag becomes implicit in whether a derivation step used
a variable-ranging rule or consumed a single ground instance.

**But this does not close the actual attack that forced graft 2.**
`judgments/invert-attack.md` Attack 2's hole was: a universal claim's own
*hypothesis role* gets discharged by a merely-existential fact riding
underneath it. Nothing about the rule/fact split prevents a rule from being
*written* as if it ranges universally while its body only ever matches a
degenerate, effectively-singleton pattern (`primitive-attack.md` Attack 1's
"exhaust a producer-fabricated one-element domain" reappears verbatim: a
rule whose body pattern happens to match exactly one fact in the corpus is,
syntactically, a "universal" rule, and nothing in the saturation kernel can
tell a genuinely-general pattern from a degenerately-narrow one dressed as
general). The kernel still cannot verify that a rule's variable actually
ranges over the intended domain rather than a rigged one — same
rule-honesty limit, restated. Net: the strength *bookkeeping* is free;
the strength *honesty* problem is identical to before.

### 2.3 Fuel-bounded re-execution

**Not subsumed — needed in both readings, arguably needed twice over in
Reading B.** Every guard/body evaluation is still arbitrary producer Lua
(a pattern match alone can't express "colon vs dot syntax" or numeric
comparisons — real rules need real code, as `subtract`'s own flagship rule
demonstrates), so each firing still needs the same per-call fuel bound the
incumbent already has. Reading B adds a second, distinct termination
concern on top: not just "does one guard call terminate" but "does the
overall rewrite-normalization process terminate at all" — see §4.1. Fuel on
individual calls does not answer that question; it answers a strictly
narrower one, same as it did for the incumbent.

### 2.4 Unknown-gating (non-guessing three-valued check)

**Fully carries over, unchanged.** A guard/body function that returns
"no verdict" (declines to fire) simply means the rule doesn't match — this
is already the natural behavior of pattern matching (a rule with an
unsatisfiable guard doesn't fire, doesn't add anything, doesn't force a
`true`/`false` choice). `synthesis.md`'s delta 1 (mandatory `"unknown"`,
never guess) is if anything more natural here than in the edge model,
because "the rule didn't fire" is already a legitimate third outcome
distinct from "fired and asserted true" / "fired and asserted false" without
any additional kernel machinery — no separate enum value needed.

### 2.5 Proved-for-witness vs. proved-for-claim

**Partially carries over via the rule/fact split (§2.2), same residual
gap.** A ground fact contributing to a derivation without passing through
any variable-ranging rule is structurally a witness-only chain
(`proved_witness`); a chain where every step used a genuinely-general rule
is `proved_claim`. Same caveat as §2.2: the kernel can distinguish "used a
rule with free variables" from "used only ground facts," but cannot verify
the rule's variables range over the domain the receipt implies. Same as
before — visible in the receipt, not verified.

### 2.6 Typed narrowing

**Orthogonal, untouched by the shape change either way.** Whether
`Payload`/`Term` fields are `unknown` and force-cast inside guard bodies, or
declared/narrowed at a pattern-match boundary, is the same open substrate
gap `judgments/subtract-attack.md` Attack 7 named and `synthesis.md` delta 7
flagged as unbuilt. Pattern matching over a `Term` tree arguably makes this
*marginally* easier to narrow correctly (a pattern like `{functor = "colon",
args = {F}}` is a natural shape for the typechecker to narrow against,
closer to a discriminated union than an arbitrary opaque `Payload` table)
but this is a plausible ergonomic note, not a demonstrated closure — no
narrowing mechanism is designed here either, same honest caveat as before.

## 3. The meeting problem

**Relocated, not solved — but relocated to a place with less new
machinery than `evidence`'s address algebra, which is a real, smaller
win.** Two independently-written harvesters' claims meet in canonical form
if and only if their *terms* — functor name, arity, argument order, nesting
— already agree, or some rule bridges them. That is the identical
requirement `judgments/evidence-attack.md` Attack 1 found underneath
`evidence`'s `unify`: "unification only does work when two terms are
already built from the same functor vocabulary... at which point the real
fix is 'someone rewrote both harvesters to agree.'" Saturation does not
escape this — a rewrite/propagation rule that pattern-matches
`harvest_stated`'s `entry_param(File, DefLine, FuncName, "byte1")` against
`harvest_mined`'s `deref(File, Line, "byte1")` still needs someone to notice
the two shapes denote the same runtime fact and write the bridging rule; no
amount of saturating a rule set that never contains that bridging rule
produces a meeting.

**What genuinely differs, and is worth naming precisely rather than
folded into "same failure":** `evidence`'s design needed a *second*,
separate kernel primitive (`unify`, a term-unification algorithm as trusted
core) to consume the address algebra, and that primitive was found
decorative specifically because nothing assigns ownership of the algebra
convention it presupposes (`judgments/evidence-attack.md` Attack 1). Under
saturation, a bridging fact is not a new kind of thing requiring a new
kernel primitive — it is an ordinary propagation rule, written in exactly
the same rule-authoring slot every other producer inference already uses.
This does not make the coordination problem go away (§4.2 of `synthesis.md`
is still exactly right that this is a registry/ownership problem, not a
kernel-design problem), but it removes one incremental piece of undesigned
machinery (`unify` itself) that `evidence` needed and this design doesn't.
**Precise statement of the delta**: saturation relocates the meeting
problem to "did anyone write the translating rule" (same place `subtract`
and `invert` already relocated it to, per `synthesis.md` §4.2's own
finding), not to "did anyone build and agree on a term algebra with a
unification primitive" (`evidence`'s harder relocation). It is the
`subtract`/`invert` relocation, not the `evidence` relocation — a real,
citable distinction, not a new solution.

## 4. Attack corpus, run against the saturation kernel

Every fake-Proved path named across the four judgment files, reassessed.

**Plausible-but-wrong rule earning false Proved — rewriting is MORE
dangerous than checking, under Reading B specifically.** Under Reading A
(monotone accumulation, facts never merged or removed), a wrong rule adds
one wrong fact to the store, exactly as a wrong incumbent rule adds one
wrong edge — the blast radius is the same: every future rule that
pattern-matches on that wrong fact inherits the error, same as every future
edge that cites a poisoned id does in the incumbent (`judgments/subtract-
attack.md` Attack 2's "one wrong mined fact poisons every claim reachable
from it" applies verbatim, unchanged). Under Reading B, the danger is
strictly worse: a wrong rewrite doesn't add a fact alongside the truth, it
can **merge two previously-distinct equivalence classes into one**,
silently identifying facts that are not actually the same runtime thing.
Every subsequent rule that matches against the merged class's canonical
representative now applies indiscriminately to both original facts, with no
record left in the term store that they were ever distinct — this is a
strictly larger, harder-to-audit blast radius than adding one wrong edge
between two nodes that remain individually addressable and inspectable.
"A wrong rewrite rewrites the world" (the task's framing) is literally
correct for Reading B and is the single sharpest argument against reading
the owner's proposal as genuine term rewriting rather than propagation.

**Self-corroboration laundering.** Under Reading A: **closed, for free,
more robustly than the incumbent** — §2.1 already shows circular mutual
support is unrepresentable in a least fixpoint built by monotone
accumulation from `F_0`, without needing a separately-implemented and
separately-buggy cycle check (closing exactly the class of error
`judgments/subtract-attack.md` Attack 6 found: a wrong graph-algorithm
implementation). A single dishonest producer manufacturing a chain of facts
and rules that all cite only each other still cannot self-support in the
fixpoint sense — but note this closes only *structural* self-reference
(the fixpoint literally cannot contain an unsupported cycle); it does not
close a producer admitting the *same conclusion* as two superficially
distinct ground facts and having a corroboration-style rule treat them as
independent (see next item) — that is a different, still-open failure.

**Quantifier-strength mismatch.** Partially closed via the rule/fact split
(§2.2) — genuinely better bookkeeping than the incumbent's bolted-on enum,
because it's structural rather than declared — but the residual honesty gap
(does a "universal" rule's variable actually range over a general domain,
or a rigged singleton) is identical to `judgments/primitive-attack.md`
Attack 1 and unclosed by either reading.

**Correlated wrong beliefs.** **Open, identically, under both readings.**
Nothing about pattern-matching over ground terms versus reachability over
edge ids gives the kernel any signal that two producers' rules share a
blind spot rather than genuinely corroborating. Same as `synthesis.md` row
4 — unsolved by kernel structure in any candidate so far, saturation
included.

**Citation omission.** Contingent on rule-body purity, in both readings,
exactly as it was for the incumbent. If a guard/body function is genuine
producer-authored Lua (needed for real inference, e.g. `def.form ==
"colon"`), it can close over ambient state through ordinary Lua lexical
scoping unless sandboxed — the identical requirement `synthesis.md` delta 5
already names as unbuilt. The pattern-matching *frame* around the guard call
(which facts feed which bindings) is transparent and auditable — a genuine
improvement in what's *declared* — but the guard body itself is exactly as
opaque as the incumbent's `Rule.check` unless the same sandboxing work gets
built. Not a free win; same residual construction requirement.

**Non-termination of rewriting.** This is where the two readings diverge
hardest and where the owner's proposal, as stated, doesn't pick a side.
Reading A: termination is free, given a finite Herbrand universe (no rule
mints a fresh compound term nested arbitrarily deep from existing facts —
true for the corpus's shape, where rule bodies only ever recombine already-
admitted atoms into flat new atoms, false in general if rule bodies were
allowed to construct arbitrarily nested new terms, which would need an
explicit depth bound or a Knuth-Bendix-style well-founded ordering to
re-establish termination). Reading B: **not guaranteed at all** —
termination of an arbitrary term-rewriting system is undecidable in general
(a classical result); Knuth-Bendix completion only terminates given a
well-founded reduction ordering chosen in advance, and choosing (or
verifying) such an ordering for an open-ended, producer-extensible rule set
is real, unbuilt, and historically hard machinery this proposal doesn't
mention building. Per-guard fuel bounds one call; they say nothing about
whether the overall normalize-to-fixpoint process halts across many calls.
**This is the proposal's single largest unaddressed risk if Reading B is
intended**, and it is not disclosed anywhere in the owner's one-line
formulation — naming it here rather than eliding it, per the mandate to run
the full attack corpus honestly.

**Non-confluence (verdict depends on rule order).** Reading A: confluent
for free — Knaster–Tarski again; the least fixpoint of a monotone operator
is unique regardless of application order, so "which rule fired first"
never changes the final Proved/Refuted/Open assignment. This is a genuine,
provable soundness property the incumbent's design never explicitly argued
(the incumbent's `close` is also a monotone fixpoint, so it likely has the
same property, but `synthesis.md` never states it as a theorem — crediting
saturation-as-Reading-A with making this property visible and named, not
with inventing it). Reading B: **a live, real soundness hole**, exactly as
the task anticipated — two rewrite rules that both match overlapping
subterms can produce different final canonical forms under different
firing orders unless the rule set is confluent, and confluence for a
rewriting system is only established via critical-pair analysis (checking
every pair of overlapping rule left-hand-sides converges to the same
result) — genuine Knuth-Bendix completion machinery, unbuilt, and not
guaranteed to succeed or terminate even when attempted. Under Reading B, a
verdict silently depending on rule submission/execution order **is** a
soundness hole, not a cosmetic risk, because it means whether a given claim
comes out Proved or Refuted could depend on incidental scheduling rather
than the rules' logical content.

**Rule-set conflicts (two producers disagree).** Reading A: this is exactly
what "conflict" (§1.3) is built to represent — both rules fire, both facts
land in the store, the store now contains `supports(A)` and `refutes(A)`
for the same canonical `A`, and that **is** the Refuted verdict, working
exactly as designed, directly analogous to the incumbent's refute-edge-
dominates rule. Not chaos — this is the cleanest part of the whole
proposal, and it is a real, direct realization of "checking for conflicts"
doing genuine work. Reading B: two rules that rewrite the *same subterm* to
different canonical forms is a Knuth-Bendix critical pair, which is not
automatically a semantic verdict at all — it is a signal that the rewrite
system itself is broken (non-confluent) and needs either a completion step
(add a new rule reconciling the two outcomes — a repair operation the
proposal never describes anyone performing) or manual resolution. Under
Reading B, "two producers' rules disagree" can produce silent
order-dependent chaos rather than a clean Refuted, unless critical-pair
machinery is built to catch it — which brings back exactly the "surprise,
not a signal to just proceed" character CLAUDE.md's disposition section
warns against, now happening inside the trusted core rather than in
application code.

## 5. Verdict

**Mixed, and the mix is precise, not hand-wavy: (a) for Reading A, (c) for
Reading B, and the owner's proposal as phrased doesn't disambiguate them.**

**Reading A (monotone fact accumulation, Datalog/CHR-propagation shape) is
strictly simpler and at-least-as-sound as the incumbent, on exactly two
mechanisms, both real and both worth rebasing onto:**

1. The acyclicity law becomes a theorem of the evaluation strategy
   (Knaster–Tarski over a monotone operator) rather than a separately
   implemented, separately buggy graph check — directly retiring the
   union-find/DFS confusion `judgments/subtract-attack.md` Attack 6 found,
   not by fixing the DFS implementation but by removing the need for a
   per-submission graph check at all, for the positive fragment. The
   caveat is real and load-bearing: refutation/negation reintroduces a
   *coarser*, predicate-level stratification DAG, so "no separate
   edge-graph/acyclicity machinery, full stop" is not achievable — a
   smaller, less-frequently-checked version of it survives, and should be
   named as that, not as elimination.
2. Confluence (order-independence of the final verdict set) is free for the
   same reason, and is a property the incumbent's design never explicitly
   claimed or proved, only implicitly enjoyed by also being a monotone
   fixpoint.

Everything else synthesis.md grafted onto the incumbent (strength
admissibility, fuel bounds, unknown-gating, provenance, typed narrowing,
sandboxing) is either unaffected by the shape change (orthogonal, §2.3,
§2.4, §2.6) or only partially re-derived from a different mechanism (the
rule/fact split gives strength-bookkeeping and witness/claim-bookkeeping
"for free" structurally, but not the underlying honesty problem those
mechanisms were built to make *visible*, which remains exactly as open as
before, §2.2/2.5).

**If Reading A is what's meant, the delta to `synthesis.md` is:** replace
the Pool/Edge/`submit`-time-acyclicity-check/`close` skeleton (§2.1-2.2 of
`synthesis.md`) with a term-store/pattern-matching-rule/monotone-saturate
skeleton; drop the explicit acyclicity check and the explicit strength-tag
enum as separate mechanisms (both now structural); keep fuel bounds,
unknown-gating, provenance, typed narrowing, and sandboxing as unchanged,
independently-required work; add a stratification requirement (a DAG over
rule/predicate dependencies, not over facts) as the residual, smaller-scale
version of the acyclicity law for the refutation fragment specifically.

**Reading B (genuine rewriting-with-replacement, egraph/Knuth-Bendix shape)
is weaker than the incumbent, precisely here:** it does not get acyclicity
or confluence for free (§2.1, §4) — it must build critical-pair analysis
and a termination-ordering discipline to recover properties the incumbent
never needed to establish in the first place, and in exchange for that
added, currently-undesigned machinery, it introduces a strictly worse
failure mode (irreversible equivalence-class merging silently amplifying a
false rule's error across every future match on the merged class, §4's
first item) that has no analogue in the incumbent's edge model at all,
where wrong conclusions stay locally addressable.

**The corpus re-derivation (§1.5) supports neither reading specifically —
it shows, honestly, that the shape change (either direction) doesn't touch
rule content, so it doesn't move any of the 5 instances from where the
incumbent left them.** That is expected and is not evidence against
saturation; it is evidence that this whole design-level question (kernel
shape) and the rule-honesty question (is a specific inference sound) are
orthogonal, exactly as `synthesis.md` §8 already states for the incumbent.

**Net recommendation for the owner's decision, not a guess dressed as one:**
the two theorems in Reading A (free acyclicity, free confluence) are real
and worth taking — they are not "equivalent machinery under a different
name," they are strictly less machinery producing the same or a stronger
guarantee, provable rather than checked. Taking them requires committing to
Reading A explicitly (monotone accumulation, no destructive term merging)
and accepting the residual stratification requirement for refutation as the
honest, smaller-scale replacement for "acyclicity," not as its elimination.
Reading B should not be adopted as stated — it is not a simplification, it
is a strictly harder design that reintroduces two classically difficult
open problems (confluence, termination) the incumbent was already free of,
in exchange for a name ("canonical form") that sounds simpler than the
machinery it actually requires.
