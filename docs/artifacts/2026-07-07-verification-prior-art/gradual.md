# Gradual Verification as Prior Art — Sourced Digest

Research question: is gradual verification (and its practice-proven cousins —
contract systems, hybrid type checking) prior art for an engine that picks,
**per individual claim**, whether to check statically, dynamically, or
hybrid — and does it do so **automatically**, without a human marking
precision level?

Tags: **[MEASURED]** = actual benchmark numbers from a paper/study/repo
metadata. **[DOCS]** = documented design/behavior in a paper or system doc,
no benchmark. **[ANECDOTE]** = blog/experience report or unverified
secondary-source claim.

Two unresolved source conflicts are flagged inline rather than silently
picked; a small number of items are marked "could not confirm."

---

## 1. State of gradual verification research

1. "Gradual Program Verification" is by **Johannes Bader (Microsoft),
   Jonathan Aldrich (CMU), and Éric Tanter (U. Chile)** — not Nadia
   Polikarpova, who was a guess going in. Venue: **VMCAI 2018**, LNCS 10747,
   pp. 25–46, DOI 10.1007/978-3-319-73721-8_2. [DOCS]
   http://www.cs.cmu.edu/~aldrich/papers/vmcai2018-gradual-verification.pdf

2. Citation count for the VMCAI 2018 paper: **35** (Semantic Scholar, live
   figure, corpus ID 31199206). [MEASURED]

3. Direct lineage, confirmed from the papers' own text: Bader/Aldrich/Tanter
   2018 (theory) → Wise, Bader, Wong, Aldrich, Tanter, Sunshine, "Gradual
   Verification of Recursive Heap Data Structures," OOPSLA 2020 (PACMPL 4,
   art. 228, DOI 10.1145/3428296) → **Gradual C0 / GVC0**, DiVincenzo et al.,
   arXiv:2210.02428 (2022; published as ACM TOPLAS, DOI 10.1145/3704808; also
   POPL 2025). [DOCS]

4. GVC0 has a working, still-touched repo:
   https://github.com/gradual-verification/gvc0 — Scala, MIT license, 13
   stars, 7 forks, 9 contributors, 25 open / 34 closed issues, most recent
   commit by a contributor not on the original author list, repo pushed as
   recently as 2026-07-03. [DOCS/MEASURED, repo metadata]

5. GVC0's backend is **Viper** (static verification infra) using **Silicon**
   (symbolic-execution verifier) with **Z3** as the SMT solver — confirmed
   at repo level (README requires cloning gradual-verification forks of
   Silver and Silicon, symlinking Silicon in, and installing Z3 with
   `Z3_PATH`/`Z3_EXE` set). [DOCS] https://github.com/gradual-verification/gvc0

6. Two 2025 POPL Student Research Competition papers extend GVC0 by name —
   Gupta, "Increasing the Expressiveness of a Gradual Verifier"
   (arxiv.org/pdf/2507.13533), and Mutlu, "Expanding Specification
   Capabilities of a Gradual Verifier with Pure Functions"
   (arxiv.org/pdf/2511.22075) — evidence of use beyond the core author set,
   but still within the same research network (CMU/Chile/Purdue/
   Haverford/Cornell/Columbia/Brown), not independent/industrial adoption.
   [DOCS]

7. No evidence of GVC0 use outside that extended author network — no
   external forks, no industrial citations found. Gradual C0 explicitly
   targets C0, "a safe subset of C designed for education," and is
   self-described as intended for classroom use; the paper calls itself
   "the first practicable gradual verifier for recursive heap data
   structures," implying prior gradual-verification work wasn't practicable
   at all — i.e., this is framed by its own authors as a research advance,
   not a mature/production tool. [DOCS]

8. **Gradual refinement types**: "Gradual Refinement Types," Nico Lehmann
   and Éric Tanter, POPL 2017, DOI 10.1145/3009837.3009856 (not
   co-authored by Ranjit Jhala, a guess going in). This paper is
   **papers-only** — no implementation; the authors state building one as
   future work in their own conclusion. [DOCS]
   https://pleiad.cl/papers/2017/lehmannTanter-popl2017.pdf

9. The direct follow-up with a real implementation is "Gradual Liquid Type
   Inference" (Vazou, Tanter, Van Horn, OOPSLA 2018, DOI 10.1145/3276502,
   13 citations). Its implementation "GuiLT" lives on a branch of Liquid
   Haskell (github.com/ucsd-progsys/liquidhaskell/tree/gradual), frozen
   since its last commit on 2018-06-29 — though the parent liquidhaskell
   repo is actively maintained (1.3k stars, releases through 2026). GuiLT is
   **static-only**: it explicitly "leaves insertion of runtime checks to
   future work." [DOCS + MEASURED, repo metadata]

10. **Gradual dependent types**: seminal paper is "Approximate Normalization
    for Gradual Dependent Types," Eremondi, Tanter, Garcia, ICFP 2019
    (PACMPL 3, art. 88, DOI 10.1145/3341692, 21 citations). Its artifact
    (a Racket Redex model, github.com/JoeyEremondi/GDTL-artifact) is
    dormant — last push 2019-06-26, 14 stars, no maintenance since. [DOCS +
    MEASURED, repo metadata]

11. Follow-on dependent-types lineage (all with Tanter as common author) is
    uniformly papers-only or dormant-artifact: "Propositional Equality for
    Gradual Dependently Typed Programming" (ICFP 2022, 6 citations, no
    repo found); "Gradualizing the Calculus of Inductive Constructions"
    (GCIC/CastCIC, TOPLAS 2020, 21 citations, artifact at
    github.com/pleiad/GradualizingCIC, 0 stars, dormant since 2020-10-20);
    "A Reasonably Gradual Type Theory" (ICFP 2022, 10 citations, no repo
    found). [DOCS + MEASURED, repo metadata]

12. **Overall maturity picture**: of the four sub-areas surveyed, only
    Gradual C0/GVC0 has an implementation seeing any external extension (the
    2025 POPL SRC papers). Every other line — refinement types formal
    paper, GuiLT, GDTL, GCIC, Reasonably-Gradual — is either papers-only or
    has a dormant/frozen artifact with no activity since roughly 2019–2020.
    [synthesis from items 3–11, not an independent source]

---

## 2. The mechanism

13. Bader/Aldrich/Tanter (VMCAI 2018) resolve the static/dynamic boundary via
    a **strongest-postcondition function plus a diff function**:
    `diff(φ_a, φ_k)` computes the minimal residual formula still needing a
    runtime check, given what's already statically known (`φ_k`) versus
    what must hold (`φ_a`). As spec precision increases, residual formulas
    shrink toward `true`; the paper calls this a **"pay-as-you-go cost
    model"** (Proposition 5) — a proved theoretical property, not a measured
    one. The paper reports **no empirical runtime-overhead numbers at all**
    (confirmed by full-text search for "overhead"/"benchmark"/"evaluation").
    [DOCS] http://www.cs.cmu.edu/~aldrich/papers/vmcai2018-gradual-verification.pdf

14. Lehmann & Tanter's gradual refinement types (POPL 2017) resolve the
    boundary differently: unresolved predicates are gradual formulas
    `p ∧ ?`; at runtime, when "evidence" can't be combined via one of three
    defined operators, the semantics raises a cast error. The paper is
    explicit that this reference semantics is *not* an efficient
    implementation — translating it to an efficient cast calculus is listed
    as open future work. [DOCS]

15. Vazou/Tanter/Van Horn's GuiLT resolves imprecise refinements only at the
    *static* layer (enumerating "safe concretizations" from a predicate
    template set) and explicitly defers all runtime-check insertion to
    future work — there is no implemented dynamic boundary in that system.
    [DOCS] https://arxiv.org/abs/1807.02132

16. Eremondi/Tanter/Garcia's GDTL (ICFP 2019): compile-time normalization is
    approximate-but-total; runtime execution is exact-but-may-fail/diverge —
    the static/dynamic gap is literally the difference between these two
    normalization regimes, with runtime checks at the seams. [DOCS]
    https://arxiv.org/abs/1906.06469

17. **The one place with real measured overhead numbers**: the Gradual C0
    paper benchmarks Binary Search Tree, Linked List, Composite, and AVL
    Tree data structures via a "performance lattice" sampling thousands of
    partial-specification points. **Unresolved numeric conflict, flagged
    rather than adjudicated**: one direct extraction of the arXiv v3 HTML
    gives "decreases run-time overhead by an average of 11–34% compared to
    dynamic verification"; a separate pass over the same source, and a
    second independent agent's secondary-source search on the published
    TOPLAS version, instead reported figures in the 7.1–90% range across
    different re-reads. The ACM page (dl.acm.org/doi/10.1145/3704808)
    403'd on every fetch attempt, so the authoritative per-version number
    could not be pinned down. Treat as [MEASURED] in kind (a real benchmark
    exists) but **unverified in specific value** pending a clean re-read of
    the primary source. https://arxiv.org/pdf/2210.02428

18. No other paper in this survey (refinement types, GuiLT, GDTL, GCIC,
    Reasonably-Gradual) reports runtime dynamic-check overhead — each is
    either pure theory with no implementation, or (GuiLT) reports only
    inference-algorithm compute time (0.51s–1.61s per case-study function,
    up to 98s worst case, timeouts above ~2.5M concretizations) which
    measures a different cost than residual-check overhead. [MEASURED, but
    not the requested metric] https://arxiv.org/abs/1807.02132

---

## 3. Per-claim routing: human-annotated vs automatic

19. **Crux finding**: in both Gradual Program Verification (VMCAI 2018) and
    Gradual C0, the programmer writes a literal `?` into the specification
    to mark imprecision — grammar is `ϕ~ ::= ? && ϕ | θ`. Direct quote from
    the paper: "she can completely avoid specifying the auxiliary
    specifications... by instead specifying `?` in the loop invariant."
    **The human places the precision marker; the tool only decides how to
    discharge whatever imprecision the human already declared** (elaborate
    it into a runtime check). The tool never decides *where* the
    static/dynamic boundary goes. [DOCS] https://arxiv.org/html/2210.02428v3

20. Same pattern holds across every related system checked: hybrid type
    checking (Flanagan & Knowles) auto-inserts a runtime cast when a
    refinement obligation can't be statically proved, but the refinement
    annotation itself is still hand-written; mainstream gradual typing
    (TypeScript, mypy's `Any`, Sorbet's `T.untyped`) is the same
    human-placed-escape-hatch story. [DOCS]

21. Dafny/Why3/F*/Viper: the underlying SMT solver auto-decides what it
    *can* discharge, but on failure the standard behavior is reporting an
    unproved obligation, not silently falling back to a runtime check;
    Why3 reportedly has no runtime-assertion mode at all. [DOCS]

22. **Clean negative result**: after searching selective verification, VC
    caching, adaptive verification, and "automatic hybrid type checking,"
    no system was found that automatically routes an individual claim to
    static vs. dynamic checking without a human-authored imprecision
    marker. If the target engine's premise is "no human marks precision
    per claim, the system decides," **gradual verification as it currently
    exists is prior art for gradual discharge of a human-declared boundary
    — a narrower, different claim** — not for automatic per-claim routing.
    [synthesis of the negative search result across items 19–21]

---

## 4. The gradual guarantee

23. Source term of art: "Refined Criteria for Gradual Typing," Jeremy G.
    Siek, Michael M. Vitousek, Matteo Cimini, John Tang Boyland, SNAPL 2015
    (LIPIcs vol. 32, pp. 274–293, DOI 10.4230/LIPIcs.SNAPL.2015.274).
    Theorem 5 (with `e ⊑ e′` meaning "e is more precise than e′"): (1) if
    `⊢ e : T` then `⊢ e′ : T′` and `T ⊑ T′`; (2) if `e ⇓ v` then `e′ ⇓ v′`
    with `v ⊑ v′` (or both diverge); (3) if `e′ ⇓ v′` then either `e ⇓ v`
    with `v ⊑ v′`, or `e ⇓ blame` (or both diverge, or `e` blames). Plain
    gloss from the paper: "the less precise program behaves the same as the
    more precise one except that it might have fewer trapped errors."
    [DOCS] https://drops.dagstuhl.de/storage/00lipics/lipics-vol032-snapl2015/LIPIcs.SNAPL.2015.274/LIPIcs.SNAPL.2015.274.pdf

24. Bader/Aldrich/Tanter (VMCAI 2018) **prove** an adapted analogue for
    verification (not merely state it as a goal) — "fully mechanized in the
    Coq proof assistant." Proposition 3 (static guarantee): if `p1 ⊑ p2` and
    `p1` is valid, then `p2` is valid. Proposition 4 (dynamic guarantee): if
    `p1 ⊑ p2` and `π →g p1 π′`, then `π →g p2 π′`. They note the definition
    required adapting Siek et al.'s original, not reusing it verbatim,
    because verification's reduction behavior differs from typing's. They
    also flag an explicit divergence from typing intuition: "if a gradual
    program fails at runtime, then making its contracts more precise will
    not eliminate the error... doing so may only make the error manifest
    earlier during runtime or manifest statically" — called "a fundamental
    property of gradual verification." [DOCS]

25. Wise et al. (OOPSLA 2020) **prove** both guarantees for their extended
    recursive-heap calculus (Propositions 8.4, 8.6), and document a design
    path they **rejected** specifically because it would have broken the
    dynamic guarantee — direct evidence the guarantee functioned as a real
    design constraint. [DOCS]

26. Gradual C0 is the one place in this lineage where the guarantee is
    **not** proven anew — it inherits the theorem from Wise et al. 2020 for
    the underlying calculus, but validates its own symbolic-execution
    implementation's compliance only **empirically**, via sampling
    thousands of imprecise specs: "our study shows that the gradual
    guarantee holds empirically for our tool." This is an explicit
    empirical-not-mechanized gap the paper is candid about. [DOCS]

27. Lehmann & Tanter (POPL 2017) **prove** both static and dynamic
    guarantees (Propositions 2, 12) and claim novelty: "we prove that our
    language satisfies the gradual guarantee, a result that has not been
    established for any of the prior [refinement-mixing] work." [DOCS]

28. GuiLT (OOPSLA 2018) proves only the **static** guarantee (Theorem 4.5)
    and punts on the dynamic half since no runtime semantics is
    implemented, crediting Lehmann & Tanter 2017 for the dynamic half of
    the underlying calculus. [DOCS]

29. GDTL (ICFP 2019) proves both guarantees plus a novel "normalization
    gradual guarantee" (monotonicity of approximate normalization w.r.t.
    imprecision), not present in earlier work. [DOCS]

30. GCIC (TOPLAS 2020) proves a **no-go theorem**: the gradual guarantee,
    normalization, and semantic conservativity over CIC cannot all hold
    simultaneously — different GCIC variants each retain the guarantee only
    by sacrificing one of the other two properties. Which specific variant
    keeps the guarantee could not be pinned down from abstract-level access
    alone. [DOCS, partial] https://arxiv.org/abs/2011.10618

31. A tangential, unverified secondary-source claim surfaced but was not
    independently confirmed: gradual security work (Toro et al.'s GSLRef)
    reportedly cannot satisfy both noninterference and the dynamic gradual
    guarantee simultaneously (per "Reconciling noninterference and gradual
    typing," LICS 2020). Not fetched/verbatim-checked — [ANECDOTE]-tier.
    https://dl.acm.org/doi/abs/10.1145/3373718.3394778

---

## 5. Practice-proven cousins with real deployment history

### Racket contracts

32. Racket contracts originate in Findler & Felleisen, "Contracts for
    Higher-Order Functions" (ICFP 2002), extending Eiffel-style DbC to
    higher-order functions by introducing **blame**: a contract on a
    function argument/result can't be checked until application, so the
    system wraps functions, defers checks to call time, and assigns blame
    to whichever party supplied the bad value. [DOCS]
    https://www2.ccs.neu.edu/racket/pubs/icfp2002-ff.pdf

33. Blame assignment is itself a documented hard correctness problem:
    Dimoulas/Findler/Flanagan/Felleisen, "Correct Blame for Contracts: No
    More Scapegoating" (POPL 2011) shows the prior literature had no
    framework for proving blame correctness, and that a common ("picky")
    semantics for dependent higher-order contracts blames the *wrong*
    module in some cases, while the conservative ("lax") semantics misses
    violations. This is a documented pain point distinct from performance.
    [DOCS] https://www2.ccs.neu.edu/racket/pubs/popl11-dfff.pdf

34. **"Is Sound Gradual Typing Dead?"** (Takikawa, Greenman, et al., POPL
    2016) empirically measured Typed Racket's contract-based
    typed/untyped-boundary cost across a benchmark suite: overheads
    range from ~1x up to worst cases around 88–105x on specific
    benchmarks/configurations (e.g. suffixtree). With a deliberately
    generous 3x acceptable-overhead bar, the large majority of
    partially-typed configurations in almost all benchmarks *failed* even
    that bar — concentrated in mixed configurations (boundary wrapping),
    not fully-typed or fully-untyped code. [MEASURED]
    https://www2.ccs.neu.edu/racket/pubs/popl16-tfgnvf.pdf (secondary
    summary used to extract exact figures: https://blog.acolyer.org/2016/02/05/is-sound-gradual-typing-dead/)

35. Follow-up "Sound Gradual Typing: Only Mostly Dead" (Bauman et al., 2017,
    DOI 10.1145/3133878) re-ran the 2016 suite on Pycket (a tracing-JIT
    Racket) and reports eliminating >90% of the gradual-typing/contract
    overhead on typical benchmarks — suggesting much of the 2016 result is
    an implementation artifact, not inherent to contract-based gradual
    typing. Taken from secondary descriptions, not independently
    re-verified against the primary — [MEASURED, second-hand].

36. Racket's own docs treat contract cost as a first-class design concern:
    three function-contract combinators with "increasing expressiveness and
    increasing additional overheads," plus a dedicated contract-profiler
    package that exists specifically because contract overhead needs
    tooling. [DOCS] https://docs.racket-lang.org/reference/function-contracts.html,
    https://docs.racket-lang.org/contract-profile/index.html

37. Racket's baseline contract system needs **no SMT solver** — contracts
    are ordinary Racket predicate functions evaluated at boundary crossings
    via proxy/wrapper mechanisms, plus blame tracking. Solver/symbolic
    approaches ("static contract simplification," "soft contract
    verification") are separate research add-ons layered on top, not part
    of the mainline design. [DOCS] https://www2.ccs.neu.edu/racket/pubs/icfp2002-ff.pdf,
    https://arxiv.org/pdf/1703.10331, https://arxiv.org/pdf/1711.03620

### Eiffel design-by-contract

38. Eiffel (Meyer, late 1980s) is the origin of Design by Contract as a named
    methodology; the Racket higher-order-contract line explicitly frames
    itself as extending Eiffel's first-order DbC. Eiffel is still actively
    maintained — EiffelStudio 25.12 shipped with security fixes and
    platform work (Eiffel Software + ETH Zurich contributors). [DOCS]
    https://www.eiffel.com/2026/eiffelstudio-25-12/

39. Eiffel manages contract cost via granular toggles rather than
    all-or-nothing: assertion monitoring can be disabled globally,
    per-class, and per contract kind (e.g., keep postconditions, drop
    preconditions), explicitly for production performance. [DOCS]
    https://archive.eiffel.com/doc/online/eiffel50/intro/language/invitation-07.html

40. No single authoritative measured "contract checking costs X% in Eiffel"
    figure was found — all located sources characterize overhead only
    qualitatively ("small," "manageable," "likely grows with data size").
    One paper ("What Good Are Strong Specifications?", arXiv:1208.3337)
    compared weak vs. strong (model-based) contracts across 42 classes
    under AutoTest and called the stronger-contract overhead
    small/insignificant in that regime — exact percentages could not be
    extracted from the primary PDF, so this is downgraded to
    [ANECDOTE]-tier rather than [MEASURED].

### Hybrid type checking / Sage

41. Flanagan, "Hybrid Type Checking" (POPL 2006) defines λH: statically
    discharge every refinement-type obligation the checker can prove or
    refute, and insert runtime casts/checks for the statically-undecidable
    remainder — one unified system rather than separate static and
    contract phases. Sage (Gronski, Knowles, Tomb, Freund, Flanagan;
    Scheme Workshop 2006) is the implemented language applying this.
    [DOCS] https://sage.soe.ucsc.edu/, http://scheme2006.cs.uchicago.edu/06-freund.pdf
    (the POPL 2006 primary PDF host was unreachable during research; this
    description comes from the search-indexed abstract, not a direct read)

42. Sage's "preliminary experimental results" reportedly show the number of
    compiler-inserted runtime casts was very small or zero on the authors'
    benchmarks (most obligations discharged statically) — but the actual
    benchmark table could not be fetched, so no [MEASURED] overhead number
    is confirmable; downgraded to [ANECDOTE]. No evidence of ongoing
    maintenance or use of Sage/HTC today was found — it reads as a closed
    mid-2000s research-prototype lineage, unlike Racket and Eiffel, both of
    which show 2026 activity.

43. **Cross-cutting read** (synthesis, not a new sourced claim): Racket is
    the only one of the three with a rigorous large-N empirical overhead
    study, and it's the most damning number here (~100x worst case, most
    partial configurations failing even a 3x bar) — though the Pycket
    follow-up shows implementation strategy recovers most of it. Eiffel has
    decades of production deployment but only soft/qualitative overhead
    claims. Sage never got empirical treatment and is unmaintained. What
    IS settled: higher-order/boundary wrapping is the expensive shape;
    first-order Eiffel-style checks with per-kind toggles are the
    practice-proven cheap shape.

---

## 6. Honest limits: production scale and stated limitations

44. No industrial or production deployment was found anywhere in the
    gradual-verification lineage (Bader/Aldrich/Tanter, Wise et al., GVC0,
    refinement/dependent types) — searches for "GVC0 industry adoption,"
    "gradual verification production," etc. surfaced only academic
    sources. [DOCS, negative search result]

45. Gradual C0 is explicit about its own scope: it targets C0, "a safe
    subset of C designed for education," partly chosen because it's
    "planned to be used in the classroom." Combined with its own framing
    as "the first practicable gradual verifier for recursive heap data
    structures" (implying prior work in the area wasn't practicable), the
    honest read is: **this is a research advance and teaching artifact, not
    a mature or production-grade tool.** [DOCS]

46. A direct, verbatim read of the VMCAI 2018 paper's own
    Limitations/Discussion section could not be completed — the PDF
    resisted parsing and SpringerLink hit an auth wall during research.
    What's reported elsewhere about its limitations is second-hand via
    search snippets only, not independently confirmed against the primary
    text. Flag this as an open gap in this digest rather than a filled-in
    claim.

---

## 7. Implementation dependencies

47. GVC0 is, per its own paper, "built as an extension of the Viper static
    verifier" — a C0 frontend plus a Gradual Viper backend that "extends
    Viper's symbolic execution-based verifier to support imprecise
    formulas." Confirmed at repo level: GVC0's README requires the
    gradual-verification forks of Silver and Silicon, plus installing Z3
    with `Z3_PATH`/`Z3_EXE` set. **Z3 is a mandatory, explicitly-named
    dependency of GVC0's toolchain.** [DOCS]
    https://github.com/gradual-verification/gvc0

48. Viper's own docs: two backends exist, Silicon (symbolic execution) and
    Carbon (verification-condition generation / WP-style), and "both of
    these ultimately rely on an SMT solver to discharge resulting proof
    obligations. Silicon interacts directly with an SMT solver, currently
    Z3." Viper is grounded in separation-logic-style permission reasoning.
    Silicon's README lists cvc5 as an optional alternate solver — not a
    Z3-free escape hatch, since cvc5 is also a C++ binary; supporting
    alternative solvers in Viper was itself recent, nontrivial engineering
    work. [DOCS] https://www.pm.inf.ethz.ch/research/viper.html,
    https://github.com/viperproject/silicon/

49. **General pattern across the whole gradual-verification lineage**:
    symbolic execution over a separation-logic-based intermediate
    verification language, with an SMT solver (Z3/cvc5) as the discharge
    engine. No pure-language alternative appears anywhere in that pipeline.
    [DOCS]

50. **Pure-language solver landscape, checked directly for crescent's
    benefit**: every tool that *looks* like a pure-language SMT solver is
    actually a binding/orchestration layer over C/C++ — PySMT requires an
    installed C/C++ solver to actually solve; Z3Py is a ctypes wrapper over
    the C++ libz3; pycosat compiles PicoSAT's C source directly into the
    Python process; PySAT wraps Glucose/MiniSat-family C++ cores;
    MiniSat.js/logic-solver are Emscripten-compiled C++ (still executing
    compiled C++ as asm.js/WASM under the hood). [DOCS]
    https://pysmt.readthedocs.io/en/latest/getting_started.html,
    https://z3prover.github.io/api/html/z3.html,
    https://github.com/ilanschnell/pycosat, https://pysathq.github.io/

51. Genuine from-scratch pure-language **SAT** solvers do exist as
    small/educational projects (SAT.js with 2-watched-literals and
    CDCL-style clause learning; tinysat; WalkSAT-in-JS) — no C/C++
    underneath, but no production robustness or benchmark evidence either.
    [ANECDOTE — real code, unverified quality]

52. **No pure-language SMT solver was found anywhere** — a solver doing real
    theory reasoning (linear arithmetic, arrays, bitvectors, uninterpreted
    functions via DPLL(T)/Nelson-Oppen), written from scratch in any
    language without a C/C++ core. Every SMT-capable tool found is a
    binding layer over Z3/cvc5. The pure-language examples that exist are
    SAT-only — a strictly weaker and much simpler problem than SMT. Also:
    no pure-Lua SAT or SMT solver, toy or production, was found — this is
    absence of search evidence, not a proven negative. [DOCS, negative
    search result]

53. **Bottom line for crescent's zero-dependency constraint**: essentially
    everything serious in SMT-backed verification depends on Z3 or cvc5,
    both C++ binaries. A static/formal tier in a per-claim engine that
    needs real SMT-style reasoning means either vendoring a C++ solver
    binary (within the project's stated "compiled binaries when
    unavoidable" escape hatch, but against its general grain) or
    restricting the static tier to decidable fragments a from-scratch
    decision procedure could plausibly handle (SAT-level, or narrow
    theories like difference logic / quantifier-free equality) — which the
    toy-solver evidence suggests is *feasible to attempt* but is
    **unproven at production quality** by any example found in this
    research pass. [synthesis of items 47–52]

54. By contrast, **Racket's baseline contract system needs no SMT solver at
    all** — contracts are ordinary predicate functions evaluated at
    boundary crossings via proxy/wrapper mechanisms plus blame tracking.
    This is the cheap, dependency-light end of the spectrum; GVC0/Viper is
    the heavyweight, Z3-discharged end. Direct confirmation from
    docs.racket-lang.org failed (HTTP 403 on every attempt), so this rests
    on the primary contracts papers and secondary academic surveys rather
    than the official reference docs — worth a follow-up read if this
    claim becomes load-bearing. [DOCS, moderate-confidence sourcing]
    https://www2.ccs.neu.edu/racket/pubs/icfp2002-ff.pdf

---

## Open items not resolved in this pass

- Gradual C0's exact measured overhead-reduction percentage: conflicting
  reads gave 11–34%, 7.1–40.2%, and 50–90% across different fetch attempts
  of the same arXiv source, with the ACM-published version 403-blocked on
  every try. Needs a clean, single re-read of the primary source (arXiv
  v3 full text or a successfully-fetched ACM TOPLAS PDF) before this number
  is cited anywhere load-bearing.
- The VMCAI 2018 paper's own stated Limitations/Discussion section was
  never directly read (item 46) — only second-hand snippets.
- Whether GVC0 is used in CMU's 15-122 course syllabus specifically was
  implied by a search snippet but never confirmed against the syllabus
  page itself.
</content>
