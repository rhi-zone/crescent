# Sweep: typestate family (2026-07-05)

Frame-breaker hunt for the certified declarative design (graded assumption
pool, three-valued verdicts, never-reject, hypothesis-survives-as-obligation).
The design's `happens`/`paired`/`consumed` claims are classical typestate
properties (Strom-Yemini "initialized", open/close, use-after-free). Provenance:
web sources cited inline; my synthesis marked [SYNTH].

## (a) Aliasing: what 30 years concluded, what machinery was REQUIRED

- Strom & Yemini (TSE 1986, https://www.cs.cmu.edu/~aldrich/papers/classic/tse12-typestate.pdf)
  defined typestate in a language (NIL) where aliasing was *statically
  resolvable by construction* — no pointers into shared mutable state. Later
  literature uniformly identifies this as the load-bearing assumption:
  typestate tracking is trivial exactly until two names can denote one object
  and a transition through one name invalidates the state known through the
  other.
- Every subsequent *sound* typestate system paid for aliasing with explicit
  ownership machinery:
  - Fugue / DeLine-Fähndrich (ECOOP 2004, https://www.cs.cmu.edu/~aldrich/courses/819/deline-typestates.pdf)
    built on their own "Adoption and Focus" linear-types work; references are
    tracked as NotAliased/MaybeAliased, and state change is only permitted
    through references known unaliased (or temporarily focused). The paper's
    self-declared main technical problem is "reasoning about the sharing
    relationships among objects."
  - Bierhoff & Aldrich (OOPSLA 2007, http://www.cs.cmu.edu/~aldrich/papers/typestate-verification.pdf)
    generalized this to *access permissions* (unique/full/share/pure/immutable)
    with fraction-based accounting (Boyland-style fractional permissions) so
    permissions can be split and rejoined. Under `share`, the checker must
    assume any other alias may fire any transition — knowledge degrades to
    whatever is invariant across the whole protocol.
  - Plaid / typestate-oriented programming (Onward 2009,
    https://www.cs.cmu.edu/~aldrich/papers/onward2009-state.pdf;
    https://dl.acm.org/doi/pdf/10.1145/2048147.2048197) made permissions part
    of the language's type system itself; the TOPLAS 2014 foundations paper
    and the gradual-typestate line (Wolff et al., ECOOP 2011) keep permissions
    even when checking is partly dynamic.
  - Recent work continues the pattern: "Law and Order for Typestate with
    Borrowing" (OOPSLA 2024, https://dl.acm.org/doi/10.1145/3689763) uses
    Rust-style borrowing; Papaya (https://arxiv.org/pdf/2107.13101) gets
    aliasing without per-reference permissions only by going *global*
    (whole-program class-level analysis).
- The alternative that avoided linearity/permissions was whole-program alias
  analysis: Fink/Yahav/Dor/Ramalingam/Geay (ISSTA 2006 / TOSEM 2008,
  https://pages.cs.wisc.edu/~ramali/Papers/issta06.pdf) verify typestate
  soundly for Java using a staged combined typestate+alias abstract domain
  (uniqueness, focus, must/must-not alias sets). Precision came from the
  *combination* — typestate-only or alias-only domains each failed.
- [SYNTH] Verdict on the design's "aliasing union-find small theory": a
  union-find is a flow-insensitive *may/must-equality* theory. The literature's
  consistent finding is that paired/consumed checking needs either (i)
  flow-sensitive must-alias + uniqueness (Fink et al.'s domain), (ii)
  linearity/permissions (Fugue, Bierhoff-Aldrich), or (iii) whole-program
  analysis (Papaya). A sketch-level union-find is *known-insufficient for
  definite-wrong verdicts on `consumed`/`paired` through the heap*: without
  must-alias/uniqueness you cannot know a close through one name discharges
  the open through another, and without may-alias completeness you cannot
  know it doesn't. HOWEVER — this is only a frame-breaker if the design
  claims soundness or completeness there. Under three-valued never-reject
  semantics the honest degradation is: any assumption whose object escapes
  into possibly-aliased heap territory drops to `undecided` (exactly Fugue's
  MaybeAliased collapse). The literature says you lose most heap-mediated
  protocol findings that way (Fink et al. report the strong-update-capable
  machinery was needed for the majority of their verifications), not that
  the architecture is incoherent.

## (b) Never-reject / advisory typestate systems

- Yes, and they are the ones that shipped. ESP (Das/Lerner/Seigle, PLDI 2002,
  https://www.cs.cornell.edu/courses/cs711/2005fa/papers/dls-pldi02.pdf) is
  advisory typestate verification ("partial verification") — it emits
  warnings, never gates compilation; it verified all 646 fprintf call sites
  in gcc. Its property simulation deliberately trades path coverage for
  polynomial time. Microsoft's ESP/PREfix lineage and Engler's tools (below)
  were bug-finders, unsound and advisory by design, and had far more
  industrial impact than any rejecting typestate language. Fugue itself was
  a checker over annotated C#, warnings-shaped, and did not survive as a
  product; Plaid (rejecting, permission-typed language) remained academic.
- Hybrid never-reject: Clara (Bodden, https://www.bodden.de/pubs/tr-clara-2.pdf;
  STTT 2012) uses static typestate analysis not to reject but to *shrink a
  residual runtime monitor* — statically-proven-safe sites lose their
  instrumentation; unresolved ones stay monitored. Most target programs were
  fully proven; residual overhead often <10%. [SYNTH] This is the closest
  operational precedent for "hypothesis must survive as obligation": whatever
  static analysis could not discharge remains as a live (runtime) obligation
  rather than a rejection or a silent assumption.
- Gradual typestate (Wolff/Garcia/Tanter/Aldrich, ECOOP 2011,
  https://link.springer.com/chapter/10.1007/978-3-642-22655-7_22) is the
  typed-theory version: unchecked permissions become inserted dynamic checks.
- [SYNTH] What happened: advisory systems won adoption but their findings on
  aliased heap protocols were rank-ordered noise unless paired with real
  alias reasoning; rejecting systems achieved precision but demanded
  annotation burdens (permissions on every signature) that killed adoption.
  No frame-breaker against never-reject — history favors it.

## (c) Modular vs whole-program; mining beliefs in unannotated interiors

- The literature's split is stark: modular soundness ⇒ annotations at every
  boundary (Fugue's per-method pre/post typestates; Bierhoff-Aldrich's
  permission-annotated APIs; the Checker Framework resource-leak checker,
  ESEC/FSE 2021, https://dl.acm.org/doi/abs/10.1145/3468264.3468576, is
  "lightweight and modular" precisely because owning/not-owning annotations
  exist and the property is an *accumulation* problem needing no strong
  updates). No annotations + soundness ⇒ whole-program (Fink et al., Papaya).
- But that dichotomy governs *verification*, not *belief generation*. The
  design's hope of mining protocol beliefs in unannotated interiors is
  exactly Engler et al., "Bugs as Deviant Behavior" (SOSP 2001,
  https://web.stanford.edu/~engler/deviant-sosp-01.pdf): extract MUST-beliefs
  (dereference ⇒ non-null) and MAY-beliefs (a() often followed by b() ⇒
  maybe paired), cross-check for contradictions, rank statistically. It
  found hundreds of real kernel bugs with zero annotations. Specification
  mining proper (Ammons/Bodík/Larus POPL 2002; Whaley/Lam) mines protocol
  automata from traces/code, again annotation-free.
- [SYNTH] So the literature does NOT flatly contradict the mining hope — it
  contradicts a stronger claim the design must be careful never to make:
  that mined interior beliefs can yield *definite-wrong* verdicts about
  heap-aliased paired/consumed obligations without alias machinery. Mined
  beliefs + contradiction = ranked findings (Engler); mined beliefs +
  soundness = requires the (a) machinery or whole-program analysis.

## (d) Pool-shaped / graded precedents

- Direct hit: Kremenek/Twohey/Back/Ng/Engler, "From Uncertainty to Belief:
  Inferring the Specification Within" (OSDI 2006,
  https://web.stanford.edu/~engler/osdi2006-inference.pdf). A factor graph
  over binary hypotheses ("f is an allocator", "g is a deallocator" — i.e.
  *paired* claims) fuses disparate evidence (naming, checker feedback,
  behavioral signatures) into marginal probabilities; annotations, when
  present, are just high-weight evidence nodes. This is a pool of graded
  assumptions about paired-resource claims with no source special-cased —
  the certified formulation's shape, existing since 2006, for exactly the
  `paired` claim family.
- Engler 2001's MUST vs MAY belief split is a two-point credence scale;
  its z-ranking of contradictions is finding-strength = f(support,
  contradiction) — a coarse ancestor of witness-status × credence.
- Tac (ACSAC 2017, https://dl.acm.org/doi/10.1145/3134600.3134620) grades
  *alias facts* themselves by learned confidence to make typestate UAF
  checking scale — precedent for graded treatment inside the aliasing
  theory, not just the claim pool.
- [SYNTH] Notable gap in the literature = the design's novelty claim: none
  of these systems have the hypothesis-survives-as-obligation law; Engler's
  MAY-beliefs are assumed for ranking without ever being independently
  discharged, which is precisely the unsoundness the law is designed to
  close. Clara (b) is the only system where undischarged hypotheses persist
  as obligations, and it does so at runtime.

## Frame verdict

No architecture-level frame-breaker: advisory + graded + mined has strong,
successful precedent (ESP, Engler, Kremenek). One load-bearing insufficiency:
a union-find alias theory cannot support definite-wrong (or proven-fine)
verdicts for heap-mediated `paired`/`consumed` claims; the literature's floor
for that is must-alias/uniqueness tracking (Fink et al.) or permissions
(Bierhoff-Aldrich). The design survives only by routing those cases to
`undecided` — which must be an explicit, stated policy, or Sound-fine breaks
on exactly the claim family the design names as its own.
