# static-analysis substrate — first-principles derivation

status: living derivation doc, started 2026-08-13. method: requirements-first — enumerate what a full static-analysis system must be able to judge, map each family to the known minimal logical machinery (grounded in literature, memory-claims marked until checked), and derive the substrate from the closure instead of discovering walls by building into them. owner frame, verbatim: "a typesystem is a subset of static analysis." the requirements list is EVERYTHING — this doc deliberately does not scope down.

## 0. the two-piece frame

- a VERIFIER: given a program + witnesses, re-establishes every claimed fact itself (never existence-checks a proof object, never trusts a witness — witnesses only make checking cheap and search-free). must stay small.
- a PROVER: finds the witnesses. untrusted, arbitrary, replaceable, per-analysis.
- everything else in the design must be derived from what the verifier needs to be able to SAY (judgment expressiveness) and CHECK (decidable re-establishment).

## 1. requirement families (initial enumeration — to be extended with the owner)

gathered from the owner's stated ambition (types incl. hkts, flow typing, temporal facts like `final`, effects, structural typing, arbitrary semantic lints — "kills manual linter passes once and for all"):

- R1 typing judgments with binding structure (scopes, quantifiers, generics/hkts)
- R2 temporal/path-indexed facts (flow narrowing, final/write-once, facts that hold at/between program points, branch-sensitive)
- R3 recursive structures (equi-recursive types, cyclic reasoning)
- R4 existential witnesses (fresh instantiation, "there is a type such that...")
- R5 negative/absence facts (unused-write class lints, "no path does X", purity)
- R6 effects (what a call may do — read/write/throw/yield families)
- R7 open-world composition (new judgment families addable as content, not checker code — the once-and-for-all requirement)

## 2. known-machinery map (UNGROUNDED — every row is a memory-claim pending a literature pass)

- R1 → binding-aware logic: nominal logic / LF-family / HOAS; freshness as first-class
- R2 → path/world-indexed judgments: hoare logic, temporal logic families
- R3 → coinduction / cyclic proof systems
- R4 → existential quantification in the certificate/witness language
- R5 → closed-world negation: stratified negation / well-founded semantics
- R6 → effect systems literature (row-effects etc)
- R7 → the logic itself fixed; vocabularies+rules as declared data (LF-style "logics as signatures" is the closest known shape?)

## 3. history constraint (why requirements-first)

four substrate walls were previously discovered by building into them (freshness, branch-structured facts, cycle-rejection vs recursion, fresh-metavariable citation — see docs/decisions/typechecker-v10-core-design.md and the wall census). each corresponds to a row above. the method error was example-driven substrate design; this doc exists to not repeat it.

## open questions

- (owner) does the R-list cover everything intended? missing families?
- literature grounding pass for section 2 — not yet run
- what the assembled minimal substrate is — the whole point, not yet derived
- (superseded in part: the plan section below carries the structured version of
  these — the owner-question list in §p8 is now the accumulating list)

---

## plan — initial derivation plan (drafted 2026-08-13, submitted for owner review)

status: NOTHING below is ratified. this is a plan proposal: tradeoffs laid out,
no verdicts — every fork with more than one workable answer is put to the owner
in §p8. evidence marking used throughout:

- `[memory]` — from the drafting session's memory, unverified.
- `[web-checked]` — confirmed to exist and say approximately this via web search
  2026-08-13; papers not read in full. one grade above memory, not grounding.
- `[repo]` — read directly from this repository this session, cited by section.

### p0. correction to §3 before anything else: where the walls actually live

`[repo]` no standalone "wall census" artifact exists — grep over `docs/` and
`TODO.md` finds only §3's own mention. the four walls are sections of
`docs/decisions/typechecker-v10-core-design.md`:

| §3 wall | where it lives in the v10 record | status there |
|---|---|---|
| freshness | F10/F12 (hypotheses and axiom bindings must be ground AND closed) + Miller-patterns-named-as-future in the term-algebra section | structural consequence of ratified groundness rules |
| branch-structured facts | phase-2 HALT: `narrow-select-match`/`-rest` both fire forward; branch role lives nowhere in the judgment | HALTed, undecided; the record itself calls closing it "a THEORY-level decision" |
| cycle-rejection vs recursion | fixpoint walker survival note: discharge-bearing loop-invariant rule; engine rejects `#discharges > 0`; replay is strictly well-founded bottom-up | recorded as substrate need ("hypothetical reasoning / discharge in the forward engine is not built") |
| fresh-metavariable citation | F12 (bindings ground+closed) + no ∃-form in any concluded judgment (`is_ground` per node, F9) | structural consequence of ratified groundness rules |

two adjudications this table forces, surfaced not resolved (both in §p8):

- (a) the v10 record adjudicated the branch-role wall as THEORY-level, but §3
  lists it as a substrate wall. both readings are defensible — a branch-role
  argument on the guard judgment is theory content; the inability of ANY
  forward-run theory to express "which branch am I on" without one might be a
  substrate smell. this is an adjudication the derivation needs settled,
  because it decides whether R2's machinery row must cover branch roles at all.
- (b) "freshness" and "fresh-metavariable citation" may be ONE wall seen from
  two sides — both are the eigenvariable condition of ∃-intro/∀-elim rules
  (`[memory]`: the standard sequent-calculus side condition "x not free in the
  conclusion"). if they collapse, R4 costs the kernel one mechanism, not two.

### p1. is R1–R7 the right decomposition of "everything"?

#### p1.1 candidate additional families (rows vs collapses — owner chooses)

| candidate | own-row case | collapse case | what collapsing costs |
|---|---|---|---|
| R8 aliasing / heap shape | its machinery (separation logic / regions / ownership `[memory]`) is disjoint from every existing row; the pilot dodged it structurally (`[repo]` effects spine: "locals only — the shared addressing signature has no field-projection operator at all") — the dodge is load-bearing and silent | fold into R6 as read/write footprints | footprints give may-alias only; must-alias (needed for strong update, typestate, `final` on fields) is unrecoverable. Lua-specific pressure: tables are the ONLY heap, and metatables alias behavior, not just storage |
| R9 termination / totality | needs well-founded orderings; size-change termination `[memory: Lee–Jones–Ben-Amram]` | if R3's machinery choice is cyclic proofs, induction/termination and coinduction ride the SAME mechanism (trace condition) — R9 collapses into R3 for free | collapse is machinery-conditional: choosing guardedness-style coinduction instead leaves termination with no home. the R3 choice and the R9 question are one decision, not two |
| R10 refinements / arithmetic facts | array bounds, `x > 0`, length relations need arithmetic decision procedures — disjoint machinery from all rows; verifier-side story is the hard part (re-establishing an SMT verdict ≠ trusting it; proof-producing SMT with checkable certificates exists `[memory: LFSC, Alethe/veriT]`) | scope R10 to decidable fragments the verifier re-decides directly (difference logic, Presburger subsets `[memory]`) | full SMT-class refinements priced out; but the collapse keeps the verifier small — this is a genuine scope fork, not a deferrable detail |
| R11 protocol / typestate | "file must be opened before read" is per-OBJECT temporal — R2 is per-path/per-variable | R11 = R2 + R8: typestate over objects needs must-alias to know WHICH object | collapsing makes the R8 dependency invisible; a row makes it visible. either way R11 is underivable before the R8 decision |
| R12 concurrency / interleaving | rely-guarantee machinery `[memory]` is its own literature | crescent's target is LuaJIT: single OS thread, coroutines — interleaving happens only at yield points, which R6 already names (`yield` in the effect families) | if full preemptive concurrency is ever in scope the collapse is wrong; for coroutine-only Lua it may be exactly right. scope question, owner-tier |
| R13 quantitative / lattice-valued facts (ranges, sizes, counts) | widening/fixpoint facts are how abstract interpretation gets boundedness `[memory: Cousot–Cousot]`; the engine deliberately built no lattice cells (`[repo]` phase 1: "substrate not yet needed") | not a judgment family at all: prover-side evaluation detail; the RESULT of a widened fixpoint is an inductive invariant, which is an ordinary (R2/R3-shaped) judgment | collapse is probably right (`[memory]`-grade analysis) BUT it silently commits the verifier to checking invariant-preservation certificates, which needs the R3 machinery to exist |
| R14 gradual boundary / `unknown` interop | crescent's own conventions make `unknown`-narrowing a first-class idiom (`[repo]` CLAUDE.md); facts about unannotated/foreign code are epistemically different — "not known" vs "known not" | treat as vocabulary: `unknown` is just a type; boundary facts are ordinary judgments with weaker premises | gradual-typing literature `[memory: Siek–Taha, blame — Wadler–Findler]` says boundaries need their own metatheory (blame tracking) if soundness claims cross them. whether crescent WANTS cross-boundary soundness claims is an owner scope call |

one further item that is not a family but a missing PARAMETER: R5's
closed-world negation is relative to a declared world (which files, which
globals, which entry points). nothing in the R-list says who declares the world
boundary or how it is cited in a certificate. absence facts are unsound without
it. added to §p8.

#### p1.2 framing observation: the R-rows mix three different axes

stated as a disagreement with the seed's §1–§2 shape (invited, so stated
plainly; analysis-grade, not settled):

- axis A — what judgments can SAY: vocabulary. R2's point-indexing, R6's
  effect families are here. in the v10 architecture this axis is registry
  CONTENT, not kernel.
- axis B — what proofs may USE: quantifiers/freshness (R4), cyclic/coinductive
  structure (R3), closed-world negation (R5), binding in judgments (R1's
  quantifier half). this axis is the actual substrate-closure question — each
  item here is a kernel-visible proof-structural capability.
- axis C — how families COMPOSE: R7 alone.

the seed's §2 maps each R-row to machinery as if the rows were homogeneous;
they aren't. consequence if unaddressed: the derivation would size the kernel
by counting rows (seven mechanisms) instead of by closing axis B (plausibly
three or four mechanisms serving all rows). the plan below derives the closure
over axis B and treats axis A as content throughout. this re-cut is itself an
owner decision (§p8) since it changes what §2's rows mean.

### p2. candidate substrate shapes

each with the requirement families it serves BADLY, per the brief. "serves
badly" is relative to the closure, not to the pilot's current scope.

**S1 — existing v10 kernel + four wall-fixes.**
sorted ABTs, first-order match/instantiate, schematic rules/axioms, labeled
discharge, taint (`[repo]`, all ratified).
- serves well: R2 (demonstrated on real corpus), R6-as-vocabulary, R7
  (registries-as-data demonstrated; the narrow-persist composition is real
  evidence), perf (canonical de Bruijn → hashing/interning by construction),
  can't-lie (conclusions computed, never carried).
- serves badly: R3 (replay is strictly well-founded; no cyclic structure at
  all), R4 (F9/F10/F12 groundness structurally forbids eigenvariables/open
  witnesses), R5 (no re-establishment story for absence — see §p3), R1's
  quantifier half (Miller patterns explicitly excluded-for-now).
- honest structural risk: four independently-designed patches onto a ratified
  core is shape-wise the v1→v4 accretion pattern the charter exists to
  prevent — even if each patch is individually principled. the fixes would
  need to be derived as ONE closure, then checked against the existing core,
  not added one wall at a time.

**S2 — LF-family (judgments-as-types; logics-as-signatures).**
`[memory: Harper–Honsell–Plotkin; Twelf; Beluga's contextual modal types]`.
- serves well: R1 fully (binding + quantifiers native via HOAS), R4 (fresh
  variables are just λ-binders; eigenvariable condition is α-conversion),
  R7 (this IS the logics-as-signatures thesis, which §2's R7 row already
  suspects).
- serves badly: R5 (negation-as-failure has no LF home; Twelf's coverage
  checking is meta-level machinery `[memory]`), R3 (coinduction weak in
  classic LF `[memory]`), perf model (dependent typechecking + β-conversion
  in the trusted core — the flat first-order cost model that made v10's perf
  ceiling arguable is gone), kid-bar (a small LF checker is a few hundred
  lines `[memory]` but the CONCEPT count — dependent types, spine forms,
  hereditary substitution — is far above match/instantiate).

**S3 — elaboration into a fixed tiny core (Metamath/MM0 pole ↔ Isabelle pole).**
- MM0 pole `[web-checked: Carneiro, "Metamath Zero: The Cartesian Theorem
  Prover"]`: verifier explicitly designed to "fit in one person's head",
  multi-sorted FIRST-ORDER logic, binary certificate format, essentially
  linear-time checking, set.mm in <200ms, prover/verifier split identical to
  the seed's §0 frame. this is the strongest existing evidence that the
  kid-buildable bar and the everything-bar can coexist.
  serves badly: R1 ergonomics — binding via disjoint-variable side conditions
  rather than native binders `[memory]`; NOTE the v10 term algebra already
  fixes exactly this weakness (ABTs = native binding, still first-order), so
  an "MM0-shaped verifier over ABTs" is a live hybrid, see S6.
- Isabelle pole `[memory: small HOL metalogic + definitional extension]`:
  maximal power, but HOL terms in the trusted core — v10's rationale
  explicitly excluded this for perf-model reasons; reopened, the exclusion
  argument still reads sound and would need positive new evidence to
  overturn.
- both poles serve badly: R3/R5 are content problems again (elaboration
  doesn't give coinduction or closed-world negation; they must be encoded,
  and the encodings are the hard part).

**S4 — cyclic-proof systems as the recursion/induction module.**
`[web-checked: Brotherston–Simpson line; GTC checking reduces to Büchi
inclusion and is PSPACE-complete in general; cheap syntactic approximations
exist [memory]]`. not a full substrate — a candidate MECHANISM for R3 (+R9 if
collapsed, see p1.1).
- serves well: R3 and R9 with one mechanism; witness = finite proof graph
  with back-edges, verifier re-establishes local steps + a global condition —
  fits the §0 frame exactly.
- serves badly: locality — the global trace condition is the one check that
  is NOT per-node bottom-up replay; it breaks the "one memoized pass" shape
  and its general form is PSPACE-complete. the honest engineering position:
  adopt a syntactically-checkable sufficient condition (every cycle crosses a
  declared progress point `[memory]`-grade) and let full GTC be a later,
  optional, more permissive checker — strictness-as-acceptance-policy applied
  to proof structure. whether that stratification is acceptable is owner-tier.

**S5 — "logic outside, calculus inside" pushed to closure.**
reading of the brief's phrase (flagged as MY reading, not a settled gloss —
§p8): the trusted core is only a term calculus + replay; every logical
connective, quantifier, and induction principle is registry content; the
kernel grows ONLY those checks that no declared content can express. this is
v10's philosophy stated as a derivation rule rather than a shape. under it the
whole derivation question becomes: which of {freshness/eigenvariable, cyclic
back-edge + progress, stratification/world-closure, arithmetic re-decision}
are content-expressible and which are irreducibly kernel? preliminary
analysis-grade answer (`[memory]`, to be grounded in D1): none of the four is
content-expressible in pure first-order match-and-instantiate — each is a side
condition or global condition by nature. so S5's honest cost is: the kernel
gains a small number of NEW primitive check families, and the design question
is whether they are four bespoke checks or instances of one declared,
checkable side-condition language — which is EXACTLY the deferred
side-condition fork (`[repo]` v10 record, "explicitly open"). S5 converts the
four walls into the strongest possible argument for designing that fork
properly instead of never.

**S6 — hybrids (the live ones, named so they're comparable).**
- S6a: v10 ABT term algebra + MM0-style certificate/verifier discipline +
  declared side-condition language covering eigenvariable-freshness and
  cycle-progress + stratified-world declarations. (S1's algebra, S3's
  verifier shape, S4's mechanism, S5's admission rule.)
- S6b: LF-core with a first-order fast path (check the first-order fragment
  with v10-style matching, escalate to LF checking only where quantifiers
  appear). two checkers = two trust stories; parity burden per repo doctrine
  would apply inside the trusted core itself. costly; named for completeness.
- S6c: Dedukti-shaped `[web-checked: λΠ-calculus modulo rewriting as
  universal proof language; logics encoded as rewrite signatures]` — the
  logics-as-content thesis with rewriting as the engine. serves R7 maximally;
  serves the perf bar and kid-bar unclearly (conversion-checking with custom
  rewrite systems in the trusted core; termination/confluence of the rewrite
  system becomes a per-theory trust obligation).

**cross-cutting, applies to every shape:** the forward engine
(datalog-with-stratification, `[repo]` engine.lua) is PROVER-side in all of
them — untrusted, swappable. no shape choice makes the engine trusted; §p3 is
about the one place that boundary is genuinely under pressure.

### p3. finding: R5 changes the SHAPE of trust, not just the vocabulary

analysis-grade (`[memory]`+`[repo]`), stated because it affects every shape:

- positive facts: extractor/prover soundness is per-fact — each seeded base
  fact cites a schematic reality-boundary axiom; taint names it; wrong facts
  make wrong derivations attributable. this is the pilot's working pattern.
- absence facts ("no path writes x", purity, unused-write): two witness
  shapes exist. (i) inductive-invariant form — "invariant I holds at entry,
  is preserved by every edge, and I implies ¬bad": checkable per-node,
  fits every shape above, prover must find I (fine — prover is arbitrary).
  (ii) closed-world form — "no write fact exists": the witness is the CLAIM
  OF COMPLETENESS of the extracted fact set. no per-fact axiom covers that;
  the trust obligation becomes "the extractor found everything", a
  completeness axiom over a declared world.
- consequence: form (i) needs R3's machinery (invariants over cycles); form
  (ii) needs the world-boundary parameter (p1.1) and a NEW KIND of axiom
  (completeness, not soundness) that per-fact taint doesn't model — closest
  existing analog is the run-level trust label carveout (`[repo]` v10 kernel
  tiers section), which already handles exactly one non-per-node trust
  source.
- the seed's §0 says witnesses "only make checking cheap and search-free" —
  for form-(ii) facts there is no witness that discharges completeness; the
  frame as written doesn't cover them. disagreement with the seed, flagged.

### p4. literature grounding — what must be grounded BEFORE any shape is chosen

grounding = reading the actual source and recording verbatim-quotable support,
per repo evidence discipline; `[web-checked]` above is NOT grounding.

shape-discriminating questions (blocking — D1 scope):

1. does a satisfying logics-as-content verifier already exist to learn from or
   conform to? — FPC `[web-checked: Chihani–Miller–Renaud, "checking
   foundational proof certificates for first-order logic"; kernel = focused
   sequent calculus, certificate FORMATS defined as content]`; Dedukti
   `[web-checked]`; MM0 `[web-checked]`. buy-vs-derive is a real fork: the
   seed says "derive something properly, once" — deriving may CONVERGE on one
   of these, and recognizing that early is cheaper than converging late.
2. minimal kernel support for eigenvariable freshness in a first-order
   matching kernel — nominal logic `[memory: Pitts; Gabbay–Pitts]`, ∇/generic
   judgments `[memory: Miller–Tiu]`. discriminates S1-fix vs S2 vs S6a.
3. checkability cost of cyclic-proof soundness conditions — the GTC complexity
   line `[web-checked: PSPACE-completeness for abstract cyclic proofs]` plus
   the cheap-sufficient-condition literature `[memory]`. discriminates whether
   R3 fits a kid-buildable verifier at all, or only under a stratified
   strict/permissive checker split.
4. verified/certificate-carrying Datalog and stratified-negation semantics —
   `[memory: Van Gelder–Ross–Schlipf well-founded semantics; provenance
   semirings — Green et al.]` — grounds §p3's form-(ii) question.

per-row grounding for §2 (non-blocking for the shape choice; blocking for each
row's theory design): R1 — HHP LF paper, second-order abstract syntax
`[memory: Fiore]`; R2 — occurrence/flow typing `[memory: Tobin-Hochstadt–
Felleisen]` (directly on the branch-role wall), Hoare logic, abstract
interpretation `[memory: Cousot–Cousot]`; R3 — equi-recursive subtyping
`[memory: Amadio–Cardelli; Gapeyev–Levin–Pierce]`; R4 — FPC + sequent-calculus
eigenvariable treatment; R5 — incorrectness logic `[memory: O'Hearn]` for the
may/must polarity map; R6 — effect rows `[memory: Lucassen–Gifford;
Leijen/Koka]`; R7 — the item-1 artifacts; R8-if-adopted — separation logic
`[memory: Reynolds; O'Hearn]`; proof-carrying code as the frame's origin
`[memory: Necula–Lee]` — worth grounding because PCC's certificate-size
history is directly relevant to emit+replay overhead at scale (risk 2).

### p5. proposed derivation order — owner decision points marked ◆

each step produces a section of this doc; halt discipline throughout; no step
builds kernel code until D5 clears.

- **D0 ◆ owner: settle the requirement rows.** answers to p1.1's table
  (which candidates get rows), the world-boundary parameter, and the p1.2
  re-cut (axes vs rows). everything downstream is shaped by this.
- **D1: blocking literature grounding.** the four discriminating questions of
  §p4, graded evidence recorded here, every §2 row re-marked
  grounded/refuted/revised. no building. output includes a buy-vs-derive
  memo on FPC/Dedukti/MM0.
- **D2: per-family verifier-obligation derivation (paper only).** for each
  settled row: the smallest statement of (what the verifier must re-establish,
  what the witness contains, which checks are per-node vs global). the
  substrate closure = the factored union of the global/side checks. output:
  a priced list — each row's kernel cost named in primitives, so
  requirements-=-everything and mental-model-small are reconciled on paper or
  the tension is surfaced with numbers.
- **D3 ◆ owner: shape choice.** S1–S6 (or a new hybrid the closure suggests)
  against D2's priced closure. the four-walls-as-one-side-condition-language
  question (S5) is decided here at the latest, because it IS the deferred
  side-condition fork.
- **D4: paper falsification round** (§p6) against the chosen shape. failures
  loop back to D3 with evidence; this is where build-then-discover is
  replaced by write-certificates-then-discover.
- **D5 ◆ owner: kernel spec ratification** — including the portable-core-spec
  open item (`[repo]` v10 named open item 1), written here as the same
  document: the kid-toy spec IS the portable spec IS the ratified kernel
  boundary.
- **D6: build.** cleanroom against the D5 spec, adjudication against the
  existing v10 core where semantics overlap (the F1–F13 pattern, which
  `[repo]` demonstrably out-performed same-author testing), parity + fuzz +
  benchmarks per repo doctrine, conformance of the existing pilot content
  ported or retired explicitly.

### p6. early falsification — what, and how, before building

the owner is burned on build-then-discover; every item below is executable
BEFORE kernel code exists, and each has a required negative twin (a wrong
certificate that must be rejected — the can't-lie property is part of what's
being falsified).

paper-certificate drills (D4), chosen so each targets a wall or a new row:

1. ∃-witness with eigenvariable escape attempt (R4; freshness wall) — the
   negative twin is a certificate that leaks the fresh name into its
   conclusion and must be structurally rejectable.
2. rest-branch narrowing run FORWARD without deriving a false fact (the
   branch-role wall, whatever level D0 adjudicates it to).
3. equi-recursive subtyping of μ-types (R3) — the classic
   coinductive-assumption certificate.
4. unused-write lint (R5) in BOTH forms of §p3, so the trust-shape difference
   is exhibited, not argued.
5. a while-loop invariant via the shape's native mechanism — success criterion
   is specifically that it does NOT reproduce the `h1_live` hand-tracking the
   fixpoint walker needed (`[repo]`).
6. an HKT instantiation judgment (R1's upper end).
7. the narrow-persist two-theory composition re-expressed (R7 regression — the
   new substrate must not lose the already-demonstrated composition).

executable falsifiers:

- **toy-verifier build as the mental-model-small test**: implement the D5-draft
  spec small and clean (the kid-toy), and require it to check real exported
  certificates from the drills. if the toy can't be small, the spec failed the
  bar — found before the real kernel exists. (MM0's fits-in-one-head verifier
  is the existence proof this bar is reachable `[web-checked]`.)
- **perf microbench of the checking primitive** on synthetic certificates at
  corpus scale before D5 ratifies: baselines already in hand — 177.5s / 569
  files for the pilot scan (`[repo]` phase 5) as the internal number, MM0's
  set.mm <200ms as the external reference point. a shape whose primitive
  can't plausibly close that gap fails here, not after the build.
- **scale-to-zero drill**: leg-(c) of the three-leg proof (`[repo]`) rerun as
  a spec obligation — for each new kernel mechanism, the removal story is
  written down (what breaks, what merely disappears) before D5.

### p7. disagreements with the seed's framing — summary register

collected from above so they're reviewable in one place; all analysis-grade:

1. §3's "each corresponds to a row above" over-claims: the branch-role wall
   was adjudicated theory-level in the v10 record; freshness and
   fresh-metavariable citation are plausibly one wall (§p0).
2. §1's rows mix vocabulary, proof-power, and architecture axes; the closure
   should be derived over the proof-power axis (§p1.2).
3. §0's "witnesses only make checking cheap" does not cover closed-world
   absence facts, where the missing piece is a completeness obligation no
   witness discharges (§p3).
4. §2's R7 row asks "LF-style is the closest known shape?" — after checking:
   FPC and MM0 are at least as close, and MM0 is closer to the stated
   kid-buildable + perf bars than LF `[web-checked]` (§p2, §p4).

### p8. owner-tier questions (accumulating; not to be resolved downstream)

decomposition (D0):
1. which of p1.1's candidates get rows: aliasing/heap? termination?
   refinements/arithmetic (and if so, decidable-fragment scope or
   proof-producing-SMT scope)? protocol/typestate? concurrency (coroutine-only
   reading acceptable?)? quantitative/lattice? gradual/`unknown` boundary?
2. who declares the closed world for R5 (files/globals/entry points), and is
   the world boundary a registry object like everything else?
3. accept the p1.2 re-cut (derive the closure over proof-power, treat
   vocabulary as content), or keep the flat R-rows as the derivation frame?

adjudications (p0):
4. branch-structured facts: substrate wall or theory gap? (v10 record says
   theory; seed says substrate.)
5. freshness + fresh-metavariable citation: one eigenvariable wall or two?

frame (p3):
6. for absence facts: is a verifier-side completeness obligation (extractor
   completeness as a run-level-style axiom) acceptable, or is R5 scoped to
   inductive-invariant-form witnesses only?

shape (D3, but the priors matter now):
7. is "logic outside, calculus inside" as glossed in S5 the intended reading
   of the phrase? if not, what is?
8. is the deferred side-condition fork now IN scope for this derivation (S5
   makes the four walls its strongest use case), or still deferred?
9. buy-vs-derive stance: if D1 grounding shows FPC/MM0/Dedukti already embody
   the target, is conforming to (or porting) one acceptable, or is an
   independent derivation the point regardless?
10. for R3: is a strict/permissive checker split acceptable (cheap syntactic
    progress condition in the kid-buildable verifier; full trace condition as
    an optional stronger checker), given soundness-is-never-configurable?

bars and budgets:
11. does the ≤2000-line kill criterion bind the NEW substrate (kernel + one
    working modular checker), or was it specific to the engine iteration?
12. does kid-buildable bind the verifier only, or verifier + a minimal theory?
13. which v10 ratifications does the owner consider STILL BINDING for this
    derivation (e.g. pure-Lua/zero-dep, perf goals, taint/trust model), as
    opposed to reopened-as-data? the plan above assumes: repo-level
    constraints binding, v10 design content reopened — confirm.
14. is 177.5s/569 files an acceptable starting baseline for the perf
    falsifier, or already over budget?
