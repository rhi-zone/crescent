# Tiered / pay-as-you-go / incremental program analysis — prior art digest

Research question: prior art for a "dynamic per-claim tradeoff" verification
engine — arbitrary claims about code, typechecker-fast for the cheap cases,
escalating cost only where a rich claim demands it.

Provenance tags: **MEASURED** = specific number from a paper/benchmark/report.
**DOCS** = vendor/project documentation claim, no independent measurement.
**ANECDOTE** = blog/forum/secondary claim, unverified. Claims marked
"peer-session verified against PDF" were extracted from the primary PDF by a
peer session, not re-fetched here. Claims marked "sub-thread digest" were
handed to this file already consolidated by a separate research sub-thread
(not independently re-verified in this pass); their internal provenance tag
is preserved as given.

Method note: gathered via four parallel web-research agents (Infer/Astrée,
Datalog engines, routing/demand-driven, trust/implementability) plus one
peer-session PDF extraction, plus a later sub-thread consolidation on CodeQL
and the wider Datalog family; each agent hit primary sources where reachable.

## 1. Meta Infer — compositional/incremental

1. **MEASURED** — Infer analyzes 1000+ code-review diffs/day, each in ~10
   minutes, on apps built from millions of lines; compositional per-function
   summaries are what make diff-time analysis affordable.
   https://engineering.fb.com/2015/06/11/developer-tools/open-sourcing-facebook-infer-identify-bugs-before-you-ship/

2. **MEASURED** — Over 100,000 Infer-flagged issues fixed by developers before
   production since 2014.
   https://research.facebook.com/publications/scaling-static-analyses-at-facebook/

3. **MEASURED** (weaker — snippet only; CACM page 403'd on direct fetch,
   re-read before making it load-bearing) — Fix rate rose from near-zero
   (batch mode) to over 70% once analysis ran at diff time; the central
   deployment-methodology claim of the CACM paper.
   https://cacm.acm.org/research/scaling-static-analyses-at-facebook/

4. **MEASURED** — RacerD (compositional race detector): 1000+ multithreading
   issues caught pre-production, per-diff analysis under 15 min at
   millions-of-lines scale.
   https://engineering.fb.com/2017/10/19/android/open-sourcing-racerd-fast-static-race-detection-at-scale/

5. **MEASURED** — Pulse-X (under-approximate successor to biabduction) on
   legacy OpenSSL-1.0.1h: 73% fix rate (19/26 reported bugs fixed) vs 49%
   (39/80) for biabduction-era Infer. Architectural shift: biabduction is
   over-approximate separation logic (proves absence); Pulse uses
   Incorrectness Separation Logic (under-approximate, proves presence).
   https://loc.bitbucket.io/pulse-x.pdf

6. **DOCS** — Checker extension is a uniform registry: each checker adds a
   `{checker; callbacks}` record in `registerCheckers.ml`, paired with target
   languages. Extensible for tool authors writing OCaml; not an open claim
   language for end users.
   https://github.com/facebook/infer/blob/main/infer/src/backend/registerCheckers.ml

## 2. Abstract interpretation in production + domain selection

7. **MEASURED** — Astrée on Airbus flight-control code (~200k lines
   preprocessed C, >10k global vars): ~6 hrs/run; false alarms went
   467 → 327 → 11 → 0 as a non-expert added directives (fewer widening
   steps, then partitioning on one function). Precision escalation is real
   but human-driven.
   https://www.astree.ens.fr/papers/astree_airbus_sas2007.pdf

8. **DOCS** — Astrée's domain selection is manual, not automatic: parametric
   domains tuned via user-written directives (e.g. `__ASTREE_octagon_pack`)
   binding variable packs to specific blocks/functions. Proves absence of
   specific runtime-error classes in embedded C (overflow, div-by-zero,
   invalid pointer arith/deref, array OOB, uninitialized use).
   https://www.absint.com/astree/index.htm

9. **MEASURED** — "Domain Types" (Apel/Beyer/Friedberger/Raimondi/von Rhein):
   automatic per-variable abstract-domain choice. LOCKS benchmark solve rate:
   45% (explicit-int) → 91% (BDD-bool) → 100% (combined); on SYSTEMC,
   domain-typed configs solved ~80% vs ~32% for uniform configs. Closest
   academic analogue to automatic precision routing — but per-variable, not
   per-claim.
   https://arxiv.org/pdf/1305.6640

10. **DOCS** — CEGAR lineage: coarse abstraction → model-check → refine on
    spurious counterexample; traces to Kurshan, adapted to software by SLAM
    (predicate abstraction) and BLAST (lazy abstraction). Refinement is
    whole-program-abstraction-level, driven by counterexamples, not by claim
    richness.
    https://arxiv.org/pdf/2504.08617v1

## 3. Datalog / claims-as-queries (CodeQL, Soufflé, Doop, Flix, bddbddb, Semgrep)

11. **MEASURED** (peer-session verified against PDF) — QL paper (ECOOP 2016,
    "QL: Object-oriented Queries on Relational Data"): Error Prone
    reimplemented in QL at ~2,000 lines vs ~10,500 Java (3.5x adjusted); on
    Apache Hadoop (~1.5 MLoC), QL ran ~4x slower than handwritten Error Prone
    (201s vs 46s for 97 analyses). A later sub-thread digest reconfirms the
    same 201s/46s/97-analyses figures independently. Claims-as-queries costs a
    constant factor vs hand-written checkers even at batch scale — not
    typechecker-fast.
    https://drops.dagstuhl.de/storage/00lipics/lipics-vol056-ecoop2016/LIPIcs.ECOOP.2016.2/LIPIcs.ECOOP.2016.2.pdf

12. **DOCS** (peer-session verified against PDF) — QL compiles to Datalog;
    Semmle built their own engine after SQL backends proved "disappointing"
    (quoted from paper body). AST encoded as relations (exprs as 4-tuples
    (c, k, p, i)). ~2,500 analyses across 8 languages, all written in QL as
    of March 2016 — strong evidence the claim language is genuinely open to
    arbitrary new predicates without touching the engine.
    https://drops.dagstuhl.de/storage/00lipics/lipics-vol056-ecoop2016/LIPIcs.ECOOP.2016.2/LIPIcs.ECOOP.2016.2.pdf

13. **DOCS** (sub-thread digest) — Current CodeQL pipeline: source →
    relational DB (fixed per-language dbscheme) → QL compiled to Datalog,
    evaluated bottom-up to least fixpoint.
    https://codeql.github.com/docs/codeql-overview/about-codeql/

14. **ANECDOTE** (sub-thread digest, flagged by the sub-thread itself as
    "anecdote-grade") — CodeQL's openness is two-layered: OPEN at the query
    layer (arbitrary user predicates/classes — consistent with claim 12's
    ~2,500-analyses figure), but CLOSED at the fact layer: a genuinely new
    fact kind requires extractor + dbscheme changes, not just a new query.
    https://github.com/github/codeql/discussions/17405

15. **DOCS/MEASURED** (sub-thread digest) — CodeQL had no incrementality at
    all until March 2026; a GitHub maintainer stated in Nov 2024 that CodeQL
    "does not currently support incremental scans"
    (https://github.com/github/codeql/discussions/17886). What shipped in
    Mar 2026 is extraction-layer incrementality only — a diff DB merged with
    a cached whole-repo DB — giving 4-70% speedups tiered by baseline, across
    5 languages, github.com-only. No evidence surfaced of incremental
    *Datalog evaluation* (i.e. incremental re-fixpointing of query results);
    this narrows, but does not overturn, the earlier negative finding in
    claim 16 below.
    https://github.blog/changelog/2026-03-24-faster-incremental-analysis-with-codeql-in-pull-requests/

16. **ANECDOTE** (negative finding, peer session, superseded in scope by
    claim 15) — At the time of the original peer-session search, no
    companion paper on incremental QL/Datalog evaluation was found; the
    published QL evaluation story was purely batch (build database, run
    queries). Claim 15's March 2026 ship is extraction-layer, not evaluation-
    layer, so this negative finding about incremental *evaluation*
    specifically still stands.
    (No URL — absence of evidence from the peer session's search.)

17. **ANECDOTE** (sub-thread digest) — Scale pain reports: a 27GB CodeQL
    database with 5h+ build times, and analysis time reported as ~8x longer
    than the extraction/build step (per GitHub issue trackers, cited by the
    sub-thread as codeql issue #8342 and codeql-action issue #2378 — repo
    paths reconstructed from the sub-thread's shorthand, not independently
    re-fetched). GitHub Next prototyped an incremental engine on Viatra
    (never shipped): <15s per-commit updates but ~1h initialization and
    tens of GB of RAM — the tradeoff a real incremental Datalog/CodeQL
    engine would have to beat.
    https://githubnext.com/projects/incremental-codeql/

18. **MEASURED/DOCS mixed** (sub-thread digest) — Soufflé compiles Datalog to
    parallel C++ and solved OpenJDK7 points-to (1.4M variables) in under a
    minute (https://cav16.pdf — domain not present in the sub-thread's
    citation shorthand; treat as needing a URL fix before load-bearing use).
    Incrementality is unshipped: a PPDP 2021 research branch exists but is
    unmerged, and a tracking issue (#2162) is unanswered. Provenance
    tracking (needed to explain *why* a fact holds, relevant to any
    explainable-claims design) costs 1.27x time / 1.45x memory overhead.
    Rich Doop-style configurations can take "multiple days" to run.
    https://arxiv.org/abs/1907.05045

19. **MEASURED/DOCS** (sub-thread digest) — Doop is >15x faster than Paddle
    at equal precision (https://yanniss.github.io/doop-datalog2.0.pdf), but
    unoptimized Datalog is "over 1000x slower" than an index-optimized
    formulation of the same rules — declarative claim forms do not spare
    performance engineering underneath. Extensibility in Doop means adding
    rules with no engine change; its P/Taint extension is built this way.

20. **MEASURED** (sub-thread digest) — Flix (PLDI 2016): a Datalog
    formulation of a points-to analysis failed to scale past 13.9 kSLOC
    (425s), where Flix's own (non-pure-Datalog, lattice-typed) formulation
    solved the same input in 27s — evidence that "just add more rules" stops
    being the whole story once the analysis needs lattice-valued facts, not
    just relational ones.
    https://plg.uwaterloo.ca/~olhotak/pubs/pldi16.pdf

21. **ANECDOTE** (sub-thread digest, explicitly flagged low-confidence) —
    bddbddb is reported as "2x faster than hand-tuned" in secondary sources
    only; unconfirmed against a primary source. Semgrep is a pattern-matching
    engine, not a fixpoint/Datalog engine, so it is a contrast case rather
    than a data point for this family; its marketing throughput numbers were
    discarded for lack of a primary source.

22. **Synthesis** (sub-thread digest, own framing, not independently
    re-derived here) — Across the whole Datalog family, "open claim forms"
    means "add rules" and that much is real and shipped (CodeQL, Doop, Doop's
    P/Taint). But whole-program fixpoint economics dominate the cost model,
    nobody has shipped incremental evaluation (Soufflé: unmerged research
    branch; CodeQL: extraction-layer only as of claim 15), and nobody in this
    family has cheap-by-default-with-escalate-per-claim — every claim pays
    the same whole-database-fixpoint price regardless of how cheap the claim
    actually is.

## 4. Automatic routing between analyses by cost/precision

23. **MEASURED** (mechanism DOCS, number MEASURED) — Goblint autotuning: cheap
    syntactic pre-analysis heuristics pick which abstract domains/analyses to
    enable (e.g. disables all concurrency analyses for thread-free programs);
    auto-selected octagon relational analysis yielded 104 additional correct
    verdicts on SV-COMP NoOverflows vs both track-everything and no-octagons.
    https://link.springer.com/chapter/10.1007/978-3-031-30820-8_34

24. **MEASURED** (placement verified, margin not) — A portfolio solver was the
    overall SV-COMP winner three consecutive years (2014–2016); per-input
    tool/strategy selection empirically beats single-strategy baselines.
    Sourced from a secondary survey; the underlying scoring delta was not
    pulled from a primary SV-COMP report.
    https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7010381/

25. **DOCS** — Theta: CEGAR-based portfolio verifier (SV-COMP 2022+)
    integrating multiple abstraction-refinement configurations and multiple
    SMT solvers, selected dynamically per input. No quantified
    improvement-over-single-strategy number found in what was fetched. PARF
    (2025) is a newer adaptive abstraction-strategy tuner positioned against
    fixed autotuning (https://arxiv.org/html/2505.13229, abstract-level only).
    https://link.springer.com/chapter/10.1007/978-3-030-99527-0_34

26. **RETRACTED** — MFH, ML-based algorithm selection over 20 verifiers
    (reported 81.64% top-1 / 91.47% overall success on 15k+ tasks) was
    withdrawn from arXiv. Cite only as "attempted, contested" — not as
    evidence ML routing works at that accuracy.
    https://arxiv.org/abs/2503.22228

## 5. Demand-driven analysis — pay only for the claim asked

27. **DOCS** — Foundations: Reps/Horwitz/Sagiv IFDS (POPL '95) and the
    companion "Demand interprocedural dataflow analysis" (FSE '95) — the
    direct ancestors of demand-driven IFDS/IDE.
    https://www.semanticscholar.org/paper/91728fca6699c2e4cadc38f629cc9f8d416db154

28. **MEASURED** (secondary aggregation — verify against primary before
    load-bearing use) — Demand-driven CFL-reachability points-to: >10x
    speedups vs exhaustive analysis where only a small part of the points-to
    graph is needed; other demand-driven approaches report 10^2x–10^5x over
    exhaustive at moderate space overhead. The Sridharan/Bodík OOPSLA 2005
    primary (https://dl.acm.org/doi/10.1145/1103845.1094817) was paywalled,
    so its exact headline number is unconfirmed here.
    https://rainoftime.github.io/files/OOPSLA22-FLARE.pdf

29. **DOCS** — Boomerang (ECOOP 2016): demand-driven flow- and
    context-sensitive pointer analysis for Java; used inside production-ish
    taint tooling (FlowDroid, CogniCrypt). Demand-driven analysis has shipped,
    not just been published.
    https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.ECOOP.2016.22

## 6. Trust stories — certified vs trusted-because-tested

30. **DOCS/MEASURED** — Verasco: a static analyzer for C entirely written,
    specified, and proved sound in Coq, explicitly following Astrée's modular
    design. The field's certified counterpart to Astrée is a separate project;
    Astrée-the-implementation itself is not machine-checked — its soundness
    rests on abstract-interpretation theory plus engineering rigor
    (ANECDOTE-level for that latter characterization;
    https://www.astree.ens.fr/papers/DASIA-2009.pdf).
    https://arxiv.org/pdf/1304.3596

31. **DOCS** — Infer, CodeQL, CBMC are all trusted-because-tested: no
    checkable certificate; confidence comes from deployment track record.
    Infer's heuristic output filtering makes it deliberately unsound in
    practice (ANECDOTE: https://news.ycombinator.com/item?id=32553338).
    Dafny/F*/Why3 sit in between: formally structured verification conditions,
    but the SMT solver's yes/no is trusted directly — no proof object in the
    standard pipeline.
    https://popl25.sigplan.org/details/dafny-2025-papers/5/Towards-Proof-Stability-in-SMT-based-Program-Verification

32. **MEASURED** — The small-TCB pattern for certificate-producing verifiers:
    external solver emits a certificate checked by a small independently
    trusted checker, keeping the TCB to checker + core logic rather than the
    whole solver.
    https://hal.science/hal-03541595/document

## 7. Implementability without C dependencies

33. **DOCS** — Pure-managed Datalog engines exist and work: Jatalog (pure
    Java, semi-naive evaluation, stratified negation, zero third-party deps)
    and Datascript (Clojure/JS, no native deps). Datalog/saturation is the
    most portable of these architectures.
    https://github.com/wernsey/Jatalog | https://github.com/tonsky/datascript

34. **MEASURED** — SMT solvers are C/C++ at the production tier: JavaSMT's
    integration paper states only Princess and SMTInterpol (JVM-native) were
    easy to integrate; Z3/CVC/MathSAT/Yices all require JNI. No pure-managed
    reimplementation competitive with Z3/CVC5 surfaced; Princess/SMTInterpol
    are real but niche, and their competitiveness on hard industrial
    benchmarks is unconfirmed.
    https://link.springer.com/chapter/10.1007/978-3-030-81688-9_9

35. **ANECDOTE** (weakest-evidence area) — No production-quality pure-managed
    abstract-interpretation framework surfaced; JSAI (JavaScript abstract
    semantics) is a research platform, not a hardened tool. The gap is
    unproven-in-practice, not architecturally blocked — abstract
    interpretation is lattice ops + fixpoint iteration, nothing native-bound.
    https://arxiv.org/pdf/1403.3996

## Cross-cutting: the four ingredients, by system family

The target design needs four ingredients at once: **(a) open claim forms**
(arbitrary new claims without engine surgery), **(b) a cheap default tier**
(typechecker-fast for the common case), **(c) per-claim escalation** (cost
rises only for the specific claim that needs it, not the whole program), and
**(d) automatic routing** (the system picks the tier/tactic, not a human).
Grounded strictly in the claims above — no family has all four.

- **CodeQL / Datalog family** (claims 11-22): **(a) yes** — query layer is
  genuinely open (claim 12), though the *fact* layer is closed (claim 14),
  so openness has a ceiling. **(b) no** — QL runs ~4x slower than a
  hand-written checker even in batch (claim 11); the whole family pays a
  whole-database-fixpoint cost regardless of claim size (claim 22). **(c)
  no** — no shipped incremental Datalog evaluation anywhere in the family;
  CodeQL's Mar 2026 incrementality is extraction-layer only (claim 15),
  Soufflé's is an unmerged research branch (claim 18). **(d) no** — nothing
  routes a claim to a cheaper evaluation path; every query re-runs the same
  engine at the same cost tier.

- **Meta Infer** (claims 1-6): **(a) no** — checkers are OCaml plugins
  registered in the compiler, not an end-user claim language (claim 6).
  **(b) yes, structurally** — compositional per-function summaries are
  exactly a cheap-default mechanism; that's what makes 1000+ diffs/day
  affordable (claim 1). **(c) partial** — compositionality gives incremental
  *scope* (only touched functions re-analyzed) but not per-claim precision
  escalation; the Pulse-X vs biabduction shift (claim 5) is a global
  architecture swap, not a per-claim dial. **(d) no** — no evidence of
  automatic tier selection between checkers or precision levels per diff.

- **Astrée / abstract interpretation** (claims 7-10): **(a) no** — proves a
  fixed menu of runtime-error classes (claim 8), not arbitrary claims.
  **(b) no** — ~6 hrs/run even at its target scale (claim 7); this is a
  batch, not cheap-by-default, tool. **(c) yes, but human-driven** — the
  467→0 false-alarm trajectory (claim 7) is real per-region precision
  escalation, just operated by a human via directives, not automatic. **(d)
  no** — domain selection is manual (claim 8); CEGAR (claim 10) automates
  *refinement* on a counterexample but at whole-program-abstraction
  granularity, not per-claim.

- **Domain Types / Goblint / SV-COMP portfolios** (claims 9, 23-26): **(a)
  no** — fixed analysis/domain menus, not an open claim language. **(b)
  yes** — Goblint's syntactic pre-analysis is cheap by construction (claim
  23). **(c) no** — escalation is per-variable (Domain Types, claim 9) or
  per-program (Goblint, portfolio solvers, claims 23-24), never per-claim.
  **(d) yes** — this is the family that actually automates the tier/strategy
  choice: Goblint's autotuner (claim 23) and SV-COMP portfolio solvers
  (claim 24) pick strategy automatically, no human directive required. This
  is the closest existing analogue to "automatic routing," but it routes
  whole programs to whole strategies, never individual claims.

- **Demand-driven analysis** (claims 27-29): **(a) no** — evaluated in this
  digest only for existing analysis kinds (points-to), not as a general
  open claim language. **(b) yes by construction** — demand-driven is
  defined as computing only what's asked, giving >10x-10^5x speedups over
  exhaustive evaluation (claim 28). **(c) yes** — this is the strongest
  ingredient (c) evidence in the whole digest: cost scales with the size of
  the question, not the size of the program, which is the literal
  definition of per-claim escalation. **(d) no** — demand-drivenness answers
  "how much do I compute for this question," not "which analysis/tier do I
  route this question to."

- **Net reading**: ingredient (c) (per-claim escalation) is best evidenced
  by demand-driven analysis; ingredient (d) (automatic routing) is best
  evidenced by Goblint/portfolio solvers, but at program granularity;
  ingredient (a) (open claim forms) is best evidenced by CodeQL, capped by
  its closed fact layer; ingredient (b) (cheap default tier) is best
  evidenced by Infer's compositional summaries. No system in this digest
  combines more than two of the four. A system with all four — open claims,
  cheap by default, escalating strictly per-claim, routed automatically —
  is not attested anywhere in the prior art gathered here.

## Follow-ups (unverified load-bearing numbers)

- CACM "Scaling static analyses at Facebook" — re-read for the 70% fix-rate
  claim (403'd this pass).
- Sridharan/Bodík OOPSLA 2005 — exact demand-driven speedup number
  (paywalled this pass).
- SV-COMP primary reports — scoring margin behind the 2014–2016 portfolio
  wins.
- The 10^5x CFL-reachability figure — trace to its primary paper.
- Soufflé CAV'16 paper URL — sub-thread cited only "cav16.pdf" with no
  domain; find and confirm the primary URL before treating claim 18 as
  load-bearing.
- CodeQL scale-pain issue numbers (#8342, codeql-action #2378) — sub-thread
  gave repo-less shorthand; confirm exact github.com/github/... paths before
  citing claim 17 externally.
- Doop 1907.05045 and Soufflé PPDP 2021 incrementality branch — confirm
  current merge status directly on Soufflé's repo/issue tracker (claim 18
  says "unmerged, issue #2162 unanswered" as of the sub-thread's pass).
