# Sweep: occurrence typing / flow typing (2026-07-05)

Frame-breaker hunt against the certified declarative-core design (pool of
graded assumptions; mutual-consistency; fine/wrong/undecided; never-reject;
one law: hypothesis must independently survive as obligation). Sources read
in full text (pdftotext) except where noted.

Sources:
- [POPL08] Tobin-Hochstadt & Felleisen, "The Design and Implementation of
  Typed Scheme", POPL 2008. https://www2.ccs.neu.edu/racket/pubs/popl08-thf.pdf
- [ICFP10] Tobin-Hochstadt & Felleisen, "Logical Types for Untyped
  Languages", ICFP 2010. https://www2.ccs.neu.edu/racket/pubs/icfp10-thf.pdf
- [CAST22] Castagna, Lanvin, Laurent, Nguyen, "Revisiting Occurrence
  Typing", Sci. Comp. Prog. 2022. arXiv:1907.05590 (full text).
- [PEARCE12] Pearce, "Sound and Complete Flow Typing with Unions,
  Intersections and Negations", VUW TR ECSTR12-20 / VMCAI 2013 (full text).
- [TR-DOCS] Typed Racket Guide §5 Occurrence Typing; racket/typed-racket
  issues #128, #32 (searched, not fetched).

## System summaries

### POPL08 — occurrence typing v1
Judgment Γ ⊢ e : τ; ψ — every expression carries a *visible predicate* ψ;
function types carry a *latent predicate* φ atop the arrow (number? :
(Any →[Number] Boolean)). T-If uses the test's visible predicate to refine
the type environment per branch. T-AbsPred: a λ gets a latent predicate
ONLY IF its body's visible predicate proves it — user-defined predicates
earn their proposition from their body, they don't assert it. Soundness
mechanically verified (Isabelle/HOL). Extra rules needed only for the
soundness proof, provably unnecessary for checking.

### ICFP10 — logical types (occurrence typing v2)
Reformulation as propositional logic. Judgment: ⊢ e : τ ; ψ+|ψ− ; o —
two proposition sets (test-true / test-false) plus an *object* o naming
which part of the environment e accesses (paths: car(p), car(cdr(x))).
Latent propositions in function types are dependent-style (named argument,
substituted with the actual object at application). A proposition
environment + a genuine proof system (their Fig. 4) does entailment,
including implications like #f_tmp ⊃ N_x for `(let ([tmp (number? x)]) …)`.
Soundness is model-theoretic: runtime environments are models of the
logic; the logic is proved sound wrt the model, type soundness follows.
Historical hook: they open by quoting Steele 1976 §5 "having to abandon
the policy of rejecting type-incorrect programs because the variables in
conditionals had overly broad types" — occurrence typing exists precisely
to make rejection tenable on untyped idioms.

### CAST22 — set-theoretic occurrence typing
Refines types of *arbitrary expressions* (not just variables/paths) under
type-cases, using full union/intersection/negation types and the `worra`
(application-inversion) operator. Declarative system deduces many types;
algorithmic system is sound with characterized incompleteness: complete
for "positive" expressions (Thm 2.7), rank-0 negation completeness
(Thm 2.9). Reconstructs intersection (overloaded) types for *unannotated*
functions from how their bodies type-case — types deduced from code with
zero annotations. Integrates gradual typing; explicitly pure language:
"our system works because all the expressions of our language are pure"
(their §related work, which lays out the side-effect spectrum: pure-only
approaches ↔ Typed Racket's fixed vocabulary of pure operations ↔ Flow's
effect system tracking mutable variables).

### PEARCE12 — flow typing (Whiley)
Defining move: *retyping* — a variable may get an unrelated type at each
program point (JVM verifier lineage). True-branch = intersection with
tested type, false-branch = intersection with its negation, join points =
union. Contribution is a sound AND complete subtyping algorithm for
union/intersection/negation types wrt the semantic (types-as-sets) model
(Frisch et al. was decidable but non-constructive). Mutation of locals is
a non-problem: assignment just retypes. Heap aliasing is dodged at the
language level — Whiley has updateable *value semantics* for compound
data (no references, no aliasing), per "Whiley: a Language Combining
Flow-Typing with Updateable Value Semantics".

## Answers to the probe questions

(a) **Is the mined-beliefs channel already formalized, more rigorously?**
Half of it, yes — and more rigorously than the sketch. Guard-mining is
exactly ICFP10: a test IS a proposition generator; propositions have
provenance-like structure (objects/paths), scoping, substitution, an
entailment proof system, and a model theory over runtime environments —
this is J1–J5-shaped machinery, already mechanized. But it is only the
*guard* half. Beliefs mined from *usage* (derefs: "x.f is read, so x is
believed a table") do not exist in this family: usage sites generate
obligations, never assumptions. And guard propositions are flow-scoped
ephemera consumed at the branch — never pooled, never graded, never
checked for mutual consistency against annotations as peers. Annotations
are ground truth that propositions refine *within*. The pool-of-peers
move is genuinely not here.

(b) **What would never-reject cost, per these authors?** Two answers.
(1) The Steele quote shows the family's founding bet: when rejection was
too costly, the fix was *more precision* (propositions), not dropping
rejection — they'd say never-reject treats a precision deficit as a
policy problem. (2) Sharper: latent propositions are load-bearing for
compositionality. A function type's latent proposition is used as a
hypothesis at every call site; POPL08's T-AbsPred grants it only when the
body *proves* it. Under never-reject, an unproven body still exists —
so proposition propagation must be gated or poisoned facts spread. The
design's one law (hypothesis must independently survive as obligation)
is exactly the T-AbsPred discipline generalized; never-reject is coherent
only because that law is present. PRE-EMPTION FINDING: the one law is not
novel — it is T-AbsPred (2008) / latent-proposition earning (2010) stated
abstractly. Not a contradiction, but priority should be acknowledged.

(c) **Aliasing/mutation.** Nobody in this family solved it; everyone
fenced it. ICFP10 footnote 3: "Racket pairs are immutable; this reasoning
is unsound for mutable pairs." set!-mutated variables are excluded from
occurrence typing entirely [TR-DOCS]; unbox gets no latent proposition;
struct selectors for mutable fields get no latent propositions or objects
[ICFP10 §soundness]. Even the fence leaked: call/cc + letrec + occurrence
typing was unsound (typed-racket issue #128). Whiley abolishes aliasing
by value semantics; CAST22 assumes total purity; Flow builds a whole
effect system just to know which variables to un-refine. FRAME THREAT:
Lua tables are mutable and aliased pervasively — the Typed Racket fence
("refine only immutable paths") would kill guard-derived beliefs about
table fields, i.e. most of the mined-beliefs channel's value. The design
cannot import this family's answer; its aliasing theory must be built,
and the precedent says three separate mature efforts chose avoidance over
theory. Mitigation unique to the design: grades. An
unsound-under-aliasing belief can be *admitted at reduced credence*
instead of discarded — occurrence typing has no such slot; its
propositions are binary, so anything mutation-tainted must be dropped.
This is the strongest argument that the graded pool is a real delta, but
it converts the aliasing problem into a credence-calibration problem
(what credence does a field-guard proposition keep across an unknown
function call?) which no source here helps with.

(d) **Graded trust / both-ways auditing?** No graded trust anywhere:
annotations are axioms in all four systems. But Typed Racket's
typed/untyped *module boundary* is a real both-ways audit: the boundary
annotation is used as hypothesis by the typed side AND enforced as a
runtime contract obligation against the untyped side. That is the one law
implemented dynamically — annotation-as-two-entries has precedent, just
at runtime, not in the checker. CAST22's intersection-type
reconstruction for unannotated functions is the nearest thing to
annotation-independence: high-value evidence that "annotations are just
assumptions" is workable, since their system derives function specs from
type-case usage alone with stated completeness theorems. Also relevant:
CAST22's declarative/algorithmic split with *characterized* incompleteness
(positive expressions, rank-0 negation) is a template for making the
design's "undecided" verdict principled rather than apologetic — undecided
= outside the completeness fragment, and the fragment is nameable.

## Verdict
No outright contradiction of the certified formulation. Two pre-emptions
(the one law ≈ T-AbsPred/latent-proposition earning; guard-mining fully
formalized in ICFP10 with better machinery than the sketch) and one
structural threat (this family's unanimous verdict that guard-propagation
under mutation/aliasing is fenced, never solved — Lua sits on the wrong
side of every fence they used).
