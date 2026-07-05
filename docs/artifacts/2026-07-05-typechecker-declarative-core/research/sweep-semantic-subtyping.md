# Sweep: semantic subtyping & set-theoretic types (2026-07-05)

Family: Frisch–Castagna–Benzaken semantic subtyping; Castagna's set-theoretic
line for dynamic languages; the Elixir type system (Castagna, Duboc, Valim).
Read against the certified declarative design (assumption pool, graded
credence, three-valued verdicts, never-reject, hypothesis-survives-as-
obligation). All claims below are [SOURCED] unless marked [ASSESSMENT].

## Sources

- S1. Frisch, Castagna, Benzaken, "Semantic subtyping: Dealing
  set-theoretically with function, union, intersection, and negation types,"
  JACM 55(4), 2008. https://dl.acm.org/doi/10.1145/1391289.1391293 (open
  copy: https://www.irif.fr/~gc/papers/semantic_subtyping.pdf)
- S2. Castagna, Duboc, Valim, "The Design Principles of the Elixir Type
  System," Programming 2024. https://arxiv.org/abs/2306.06391
- S3. Elixir blog, "Strong arrows: a new approach to gradual typing," 2023.
  https://elixir-lang.org/blog/2023/09/20/strong-arrows-gradual-typing/
- S4. Duboc et al., "Guard Analysis and Safe Erasure Gradual Typing: a Type
  System for Elixir," 2024. https://arxiv.org/abs/2408.14345
- S5. Elixir blog, "Lazier BDDs for set-theoretic types," Dec 2025.
  https://elixir-lang.org/blog/2025/12/02/lazier-bdds-for-set-theoretic-types/
- S6. Elixir blog, "Type inference of all constructs and the next 15
  months," Jan 2026.
  https://elixir-lang.org/blog/2026/01/09/type-inference-of-all-and-next-15/
- S7. Gesbert et al., "A Logical Approach to Deciding Semantic Subtyping,"
  TOPLAS 2015. http://tyrex.inria.fr/publications/toplas15.pdf
- S8. Hexdocs, "Gradual set-theoretic types."
  https://hexdocs.pm/elixir/gradual-set-theoretic-types.html

## (a) Types-as-sets-of-values vs the design's "value descriptions"

- S1 defines types as sets of values and subtyping as set containment; the
  paper's central contribution is making this circular-looking definition
  well-founded in the presence of arrow types, and deriving a *complete*
  subtyping algorithm from the semantic interpretation.
- [ASSESSMENT] The design's forward layer — assumptions as descriptions of
  the executions/values a program point can produce, checked for mutual
  consistency — is semantically the same move: an assumption "x is described
  by D" is a set of values, and "assumptions A and B are mutually
  inconsistent" is exactly "⟦A⟧ ∩ ⟦B⟧ = ∅", i.e. an emptiness test on a
  set-theoretic type. The design IS quietly reinventing the semantic
  interpretation; the literature has 20+ years of machinery for precisely
  this emptiness test.
- Cost: deciding subtyping/emptiness for full set-theoretic types (union,
  intersection, negation, arrows, products) is EXPTIME-complete — it reduces
  to inclusion of nondeterministic tree automata (S7; also the sst-tutorial
  https://pnwamk.github.io/sst-tutorial/). In practice implementations use
  DNF or BDD representations with heavy memoization; Elixir's experience
  (S5) is that the worst case bites for real: naive DNFs blow up
  exponentially on chained intersections of unions; the v1.19 BDD
  representation still made "projects that type checked instantaneously in
  v1.18 take minutes"; a bespoke "lazier BDD" (unions kept in node fields)
  was needed to recover. Implementation-cost data point, not just theory.
- Buys: principled negation/union/intersection with the distributive laws
  holding *by construction* — no ad-hoc normalization rules to hand-prove.
  Directly relevant to Lua: `T | nil` handling, `T \ nil` after a
  `if x ~= nil` narrow, and guard-driven refinement are literally set
  difference and intersection. S4 shows guard analysis compiles into
  set-theoretic operations cleanly. [ASSESSMENT] For crescent this is the
  strongest argument that the consistency-check core should be a semantic
  (emptiness-based) engine rather than syntactic rule matching — the
  no-special-casing constraint is exactly what semantic subtyping delivers:
  one emptiness algorithm, zero per-connective special cases.

## (b) Elixir deployment lessons (never-reject retrofit onto a dynamic language)

- Posture: warnings, not rejections. Type info is fully erased; "no changes
  to Elixir's compilation pipeline or runtime" (S4). RC releases explicitly
  said "do not change your programs based on these warnings yet" and
  admitted expected false positives (S6). This is a live, published
  never-reject deployment.
- `dynamic()` is the gradual escape hatch, but crucially it is *boundable*:
  `dynamic() and number()` = "known only at runtime, but must be numeric"
  (S3, S8). [ASSESSMENT] This is a two-point credence scale in disguise —
  static claims vs runtime-trusted claims — the nearest thing this family
  has to the design's graded assumptions.
- Strong arrows (S3): a function is "strong" if it can be statically proven
  to error at runtime on inputs outside its domain. Then dynamic callers can
  be granted the declared codomain *without inserting checks*, because the
  VM/guards already enforce the domain. Soundness is delegated to existing
  runtime checks — implicit VM checks plus programmer-written guards — not
  to compile-time insertion of casts (S2, S4). This dodges the classic
  gradual-typing tax (no cast insertion, no perf cliff).
- What they compromised: (i) the three-way tradeoff in S3 — permissive
  dynamic propagation vs unsound trust vs runtime-check cost — is resolved
  per-function by strong-arrow detection, and functions that aren't strong
  get the permissive/less-useful treatment; (ii) rollout ordering: inference
  first, annotations later — v1.17 patterns only, v1.18 call checking, v1.19
  anonymous functions (+the S5 perf crisis), v1.20 whole-construct
  inference, annotations (`$` signatures) still pending; recursive and
  parametric types explicitly flagged as "may make the type system
  unfeasible" and deferred to v1.21/22 (S6); (iii) tolerated false positives
  in RCs rather than weakening the type language.
- Published worked/didn't: worked — unannotated inference finds real bugs
  "for free"; gradual behind-the-scenes rollout validated the system without
  user code changes (S6). Didn't — DNF then plain-BDD representations both
  hit exponential blowup on real projects; negations (needed for anonymous
  fn inference) triggered it (S5).

## (c) Mined assumptions, graded trust, both-ways auditing

- Mined assumptions: yes, in a strong form. Elixir's system is
  inference-first — types are mined from patterns, guards, and calls of
  entirely unannotated code, and violations reported against them (S6). S4's
  guard analysis mines developer-written runtime checks as static type
  information. That is the design's "mined beliefs" source, deployed.
- Graded trust: only the degenerate two-grade version (`dynamic()` vs
  static; strong vs non-strong arrows). No credence scale, no ordering of
  finding strength by source confidence. [ASSESSMENT] Nothing in this family
  grades assumptions on a continuum.
- Both-ways annotation auditing: partially. Strong-arrow *checking* verifies
  the implementation errors outside the declared domain — an obligation on
  the annotation, not just a hypothesis granted to callers (S3). But there
  is no symmetric "annotation as two pool entries" structure; annotations
  (once they land) are trusted modulo the strong check.

## (d) Is any of this already the assumption-pool + consistency design?

- No. [ASSESSMENT] The family supplies the *type algebra and decision
  procedure* the design's consistency check needs (emptiness of
  intersections of value descriptions), and Elixir supplies the *deployment
  playbook* (erasure, warnings-only, inference-first, strong arrows to avoid
  the gradual tax). But: verdicts are two-valued (warn / silent), not
  three-valued with witness status; there is no pool of heterogeneous graded
  assumptions — inference results and annotations live in different
  mechanisms, not one uniform pool; no hypothesis-must-survive-as-obligation
  law (strong-arrow checking is its closest single instance); no
  witness-status × credence product order. The design is not subsumed.

## Frame-threat summary

1. [ASSESSMENT] The forward layer is reinventing semantic subtyping; adopt
   the emptiness-test core (or knowingly diverge) rather than rediscover
   its normalization lemmas. The EXPTIME worst case is real in production
   (S5) and must be engineered for (lazy BDDs, memoization) from day one —
   an LuaJIT implementation with the "tsgo performance bar" cannot treat
   representation as a detail.
2. [ASSESSMENT] Elixir demonstrates never-reject retrofit is viable but
   shows the two hard costs paid: representation blowup, and a per-function
   strong/weak dichotomy replacing any finer trust grading. Crescent's
   credence scale is genuinely beyond this family — but that also means no
   published soundness story exists for it.
