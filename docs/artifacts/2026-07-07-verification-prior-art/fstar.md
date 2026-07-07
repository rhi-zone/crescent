# F* as prior art — research digest

Context: researching F* as prior art for a design question about an engine that
attempts to prove arbitrary claims about code, picking an {arbitrariness,
automation, speed} tradeoff dynamically per claim. Every claim below is tagged
with a source URL and two tags: provenance `[docs]`/`[paper]`/`[anecdote]` and
epistemic status `[measured]`/`[design-claim]`/`[opinion]`.

## 1. Tier architecture: typechecking -> SMT -> tactics

1. Routing is per-goal/per-obligation, not per-module: F* collects the proof
   obligations arising from a top-level definition and, by default, presents
   them "to Z3 in a single query with several conjuncts, which usually allows
   Z3 to efficiently solve all the conjuncts together." There is no separate
   "escalation on failure" step to a different tier — SMT is simply invoked
   wherever a refinement/logical obligation exists in the term being checked.
   [docs] [design-claim] — https://en.wikipedia.org/wiki/F*_(programming_language) (paraphrasing F*'s own description) and corroborated at https://fstar-lang.org/tutorial/book/part1/part1_prop_assertions.html

2. Fuel/ifuel control how much of the SMT tier's automatic unfolding happens,
   and are tunable at fine grain: `--initial_fuel`/`--max_fuel`/`--fuel` bound
   how many times recursive functions get unfolded for Z3; `--initial_ifuel`/
   `--max_ifuel`/`--ifuel` bound automatic inductive-type inversions ("`(HasType
   x t)` is just a macro for `(HasTypeFuel MaxIFuel x t)`"). The docs
   explicitly recommend the low-automation end of this dial: "it's a good idea
   to try to use an `ifuel` setting that is as low as possible for your
   proofs, e.g., a value less than `2`, or even `0`, if possible." [docs]
   [design-claim] — https://fstar-lang.org/tutorial/book/under_the_hood/uth_smt.html

3. `#push-options "..."` / `#pop-options` scope these SMT-tier knobs (fuel,
   ifuel, rlimit, etc.) to an arbitrary lexical region — i.e. tier
   configuration is addressable per-definition or even per-sub-expression, not
   fixed per-module. `#restart-solver` forces a fresh Z3 process at that point.
   [docs] [design-claim] — https://fstar-lang.org/tutorial/book/under_the_hood/uth_smt.html

4. `admit()` produces a term of any type with no obligation discharged at
   all — i.e. a claim can be explicitly opted out of every tier ("a proof
   isn't done until it's free of them" — admit/assume are for
   work-in-progress, not a supported terminal state). [docs] [design-claim] —
   https://fstar-lang.org/tutorial/book/part1/part1_prop_assertions.html (per WebFetch synthesis; admit/assume distinction documented across the tutorial's SMT chapter)

5. `SMTPat` lets the user hand-author the quantifier-triggering pattern that
   decides when a lemma fires during Z3's search: "collectively, `p1 ... pm`
   must mention all the bound variables. To instantiate the quantifier, the
   solver aims to find active terms `v1...vm` that match the patterns." This
   is a manual dial on automation *within* the SMT tier, independent of
   fuel/ifuel. [docs] [design-claim] — https://fstar-lang.org/tutorial/book/under_the_hood/uth_smt.html

6. Meta-F*/tactics are invoked with `by tac` (e.g. `assert (pow2 19 ==
   524288) by compute()`) and constitute the third, most-manual tier: tactics
   "massage the assertion by simplifying it, splitting it into several
   sub-goals, tweaking particular SMT options" before any residual goal is
   handed to Z3. So the tactic tier is often used precisely to *feed* the SMT
   tier a cheaper/more automatable goal, rather than replacing it — the tiers
   compose within one definition rather than being mutually exclusive
   escalation paths. [docs] [design-claim] — https://fstar-lang.org/tutorial/book/part5/part5_meta.html

## 2. Trusted core

7. F*'s own tutorial text does not characterize Z3 as trusted or untrusted in
   so many words in the pages fetched, but is explicit that Z3 is a heuristic,
   incomplete automation engine, not a checker whose answer is independently
   verified: "finding proofs in the SMT logic F* uses (first-order logic with
   uninterpreted functions and arithmetic) is an undecidable problem" and Z3
   "relies on various heuristics and partial decision procedures." No
   certificate-checking step is described — F* accepts Z3's unsat verdict
   directly. [docs] [design-claim] — https://fstar-lang.org/tutorial/book/under_the_hood/uth_smt.html

8. The HACL*/EverCrypt project states the TCB implication plainly for a real
   deployment: "EverCrypt must trust that F* itself and the Z3 theorem prover
   that F* relies on to discharge verification conditions are correct." Z3 is
   inside the trusted computing base, not outside it — there is no
   independently-checked unsat certificate in this pipeline. [anecdote]
   [design-claim] — search-derived from HACL* documentation ecosystem (https://hacl-star.github.io/), corroborating https://en.wikipedia.org/wiki/F*_(programming_language) 's architecture description. (Note: this exact sentence came back via search synthesis rather than a direct fetch of a single page; treat as attributed to the HACL*/EverCrypt documentation set generally rather than one URL.)

9. Independent of F*-specific sourcing, the general SMT-soundness point
   applies directly to this architecture: verifying an unsat claim in
   general requires either trusting the solver or having it emit an unsat
   certificate/core that a separate, simpler checker validates — "the harder
   part is verifying that no solution exists when the solver claims it
   can't find one." F*'s pipeline as documented does not describe such an
   independent certificate-checking step for Z3's unsat answers; it treats
   Z3's answer as authoritative. [paper] [design-claim] — general SMT
   literature surfaced via search, applied to the F*/Z3 case described in
   claim 7-8.

## 3. Performance reality

10. Routine, non-trivial F* code is *not* free of SMT the way ordinary
    typechecking is: "the typical code to proof ratio for functional
    correctness and security proofs is more like 1:20" — i.e. verified code
    carries roughly 20x the artifact volume of proof annotation/lemmas per
    line of implementation, implying SMT-tier work dominates routine
    development, not just occasional hard claims. [docs] [design-claim] —
    https://fstar-lang.org/oplss2021/out/lecture1.html (surfaced via search of fstar-lang.org OPLSS lecture material)

11. Z3 cost is controlled via a machine-independent resource limit (`rlimit`,
    tuned with `--z3rlimit_factor`) rather than wall-clock timeout, specifically
    *because* wall-clock varies by machine: "rlimits count the number of
    certain basic operations in Z3 like allocations, which ensures fully
    deterministic execution irrespective of machine, workload, etc." The docs
    add an explicit caveat that this proxy is imperfect: "the correspondence
    between rlimit and time is quite good [but] it's not perfect." [docs]
    [measured] — https://github.com/FStarLang/FStar/wiki/rlimits:-Machine-Independent-Resource-Limits-for-Deterministic-Execution

12. Real observed query costs, from the FStar wiki's own worked examples:
    a successful query completing in 8–129 ms at rlimit ~2,723,280, versus a
    failed query taking 171 ms at a rlimit of 21,786,240 — illustrating that
    rlimit budgets, not raw time, are the tuning unit, and that failed
    queries can still consume large resource budgets before giving up.
    [docs] [measured] — https://github.com/FStarLang/FStar/wiki/Profiling-Z3-queries (surfaced via search; numbers as reported in wiki query-stats examples)

13. Brittleness is acknowledged by the F* team itself, not just outside
    critics: "Z3 (and/or the way F* uses it) often ends up being a
    bottleneck in terms of proofs stability and predictability," and "any
    change to the queries fed to Z3 can cause unpredictable verification
    outcomes... proofs that used to work fast can stop working or take
    longer time even for simple changes like renaming a variable." [docs]
    [opinion] (team's own assessment) — https://github.com/FStarLang/FStar/wiki/Getting-better-mileage-out-of-Z3 and https://github.com/FStarLang/FStar/wiki/rlimits:-Machine-Independent-Resource-Limits-for-Deterministic-Execution

14. HACL* (a real, shipped verified crypto library) reports a concrete
    verification cost at project scale: "HACL* required 12 hours of
    verification time (reported on an Intel Core E5 1620v3 CPU)" — this is
    proof/SMT time, not compilation time, for the whole library. [anecdote]
    [measured] — surfaced via search of HACL*-related sources (https://hacl-star.github.io/, https://github.com/hacl-star/hacl-star); exact page not individually confirmed by direct fetch, flagged for follow-up if precision is needed.

15. Direct answer to "is plain typechecking fast like a normal typechecker
    or does routine code still hit SMT": the documentation is explicit that
    "for simple functions without complex proof obligations, F* by default
    uses an SMT solver to prove facts" whenever a refinement-typed or
    logical fact appears — i.e. there is no separate "pure, SMT-free"
    typechecking mode for ordinary verified code; SMT is on the routine path
    for anything carrying a refinement type, which in idiomatic F*
    (following claim 10's 1:20 ratio) is most of the code that matters.
    [docs] [design-claim] — https://fstar-lang.org/tutorial/book/part1/part1_prop_assertions.html

## 4. Claim-language extensibility

16. The core claim language (refinement types over a dependently-typed
    core, plus indexed effects/monads) is fixed; extensibility happens by
    metaprogramming over that fixed language, not by adding new primitive
    claim forms to the kernel. Meta-F* tactics are "designed to perform
    small and correct modifications of the goals" within the existing
    proof-state representation — users build new automation
    (`FStar.Tactics.Builtins` primitives composed into custom tactics) but
    "the core property language (refinement types, squashed propositions)
    remains unchanged." [docs] [design-claim] — https://fstar-lang.org/tutorial/book/part5/part5_meta.html

17. Effects themselves are the other declared extension point for *what
    kind* of property can be stated per-function: "programmers choose the
    granularity at which to specify effects by equipping each effect with a
    monadic, predicate transformer semantics" — new effects (state,
    exceptions, divergence, IO, and user-defined combinations) let a
    definition's type carry new *forms* of obligation (e.g. a Hoare-style
    pre/post pair, a cost bound) without changing the trusted kernel, because
    the effect's semantics is itself just more dependently-typed code checked
    by the same core. [paper] [design-claim] — "Dependent Types and
    Multi-Monadic Effects in F*" (POPL 2016) — https://fstar-lang.org/papers/mumon/

18. Tactics do not bypass trust: they operate on a goal/proof-state and
    ultimately still have to produce something the same fixed typechecker (or
    Z3, if the residual goal is handed off) accepts — the digest text found
    no statement that tactic-discharged goals skip re-checking by the trusted
    core. This matches the general pattern (also true of Coq/Lean tactics):
    tactics are inside the "convenience" layer, but the kernel still checks
    whatever they ultimately produce or hand to Z3. [docs] [opinion]
    (inference from absence of any stated bypass, not a direct quote) —
    https://fstar-lang.org/tutorial/book/part5/part5_meta.html

## 5. Known failure modes / criticism

19. Non-replayability / brittleness across edits is a named, documented
    problem with a dedicated mitigation feature (hints/unsat-cores), which is
    itself imperfect: Z3 "guarantees logical unsatisfiability" but "does not
    guarantee that it will be able to prove that an unsat core is indeed
    unsatisfiable, since such a proof may depend on heuristics triggered by
    facts that are not strictly part of the unsat core." A concrete
    documented brittle case (`FStar.HyperStack.ST`, `inline_stack_inv`) shows
    a lemma chain where one transitive step triggered correctly and an
    adjacent, structurally similar step silently failed to trigger until an
    extra fact was added to a definition — illustrating that proof stability
    can hinge on incidental SMT quantifier-triggering details invisible at
    the source level. [docs] [anecdote] —
    https://github.com/FStarLang/FStar/wiki/Robust,-replayable-proofs-using-unsat-cores,-(aka,-hints,-or-how-to-replay-verification-in-milliseconds-instead-of-minutes)

20. Context/lemma pollution is acknowledged by F* contributors as a live,
    poorly-understood problem, not a solved one: a Slack discussion cited on
    the FStar wiki states "unexpected lemmas in the environment can make
    otherwise simple proofs very time consuming, brittle, etc," with worked
    examples of the *same* lemma proving quickly in isolation but taking
    "WAY longer, or it may even fail to prove" once placed in a larger module
    context. The team's own framing is notably candid about the limits of
    their visibility: "we have very less visibility into the root cause of
    such behaviors" and "we have very little transparency into what's in the
    context when presenting a proof to Z3." Proposed fixes (context slicing,
    a "healthy module" notion, tactics-based manual proof) are listed as
    unimplemented ideas, not shipped solutions, in the fetched page. [docs]
    [opinion] (team's own words) —
    https://github.com/FStarLang/FStar/wiki/Getting-better-mileage-out-of-Z3

## 6. Dependencies / implementation

21. Building F* from source requires a working OCaml toolchain ("OCaml
    version 4.14.X should work") plus "a bunch of external OCaml packages"
    via OPAM (some needing system binaries like `gmp`), and a specific,
    strictly version-pinned Z3 binary: "F* requires a specific Z3 version...
    and will refuse to run if the version string does not match," currently
    `z3-4.13.3`. Source builds go through "a multi-stage bootstrapping
    process (stage0 → stage1 → stage2 → stage3)." Binary releases bundle
    their own matching Z3 and avoid the OCaml requirement entirely for
    end users (verification + OCaml codegen only; compiling the generated
    OCaml still needs an OCaml toolchain separately). [docs] [measured] —
    https://github.com/FStarLang/FStar/blob/master/INSTALL.md

22. No evidence was found (across F*-specific searches and the fetched docs)
    of F* supporting a pluggable/alternative SMT backend in place of Z3, and
    no F*-team discussion of replacing Z3 with cvc5 or another solver turned
    up in the sources checked. The strict version-pinning in claim 21
    ("refuse to run if the version string does not match") is itself
    evidence against easy solver-swapping: F*'s SMT encoding and proof/hint
    replay machinery (unsat cores, unsat-core hints) is tied closely enough
    to Z3's specific behavior that even *Z3 version* changes are flagged as
    a stability risk, let alone a different solver implementation. This is
    an absence-of-evidence claim, not a positive statement from F* sources
    that swapping is impossible — flagged as a gap for a follow-up
    targeted search of F* GitHub issues/discussions if this point matters to
    the design question. [anecdote] [opinion] — synthesized from
    https://github.com/FStarLang/FStar/blob/master/INSTALL.md and the
    absence of contrary hits in the searches recorded under section 3/6 of
    this research pass.

## Notes on search noise

One search (`F* trusted computing base kernel Z3 unsat certificate soundness`)
surfaced an arXiv paper ("Federated Formal Verification: Cross-Backend
Citation...", arxiv.org/abs/2606.02019) that reads as unreliable — it carries
a nonsensical future-dated arXiv identifier pattern and generic-sounding AI-
adjacent claims not corroborated elsewhere; it was **not** used as a source
for any claim above.
