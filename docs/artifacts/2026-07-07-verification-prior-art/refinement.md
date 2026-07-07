# Prior art: refinement/liquid types and SMT-verifier lineage

Research digest for the "dynamic per-claim tradeoff" verification engine design question.
Covers LiquidHaskell, Flux (Rust refinement types), Dafny, and the decidable-fragment /
SMT-discharge lineage generally. Compiled from live web sources on 2026-07-07 (dates in
tool output notwithstanding — see system context). Every claim is tagged `measured` (numbers
from a benchmark/paper), `docs` (official documentation/spec statement), or `anecdote`
(blog/forum/experience report, not independently verified).

---

## 1. How the decidable fragment is defined and enforced; what happens outside it

- LiquidHaskell restricts refinement predicates to a decidable logic (QF-EUFLIA:
  quantifier-free equality, uninterpreted functions, linear arithmetic) so that every
  verification-condition query it generates falls inside a fragment Z3 is guaranteed to
  decide — this is a structural restriction on what a refinement predicate is allowed to
  say, not a best-effort heuristic. — [Refinement Types For Haskell](https://goto.ucsd.edu/~nvazou/refinement_types_for_haskell.pdf) (docs)
- Stepping outside that fragment in LiquidHaskell is done with the `assume` keyword: it
  marks a predicate as accepted without proof, and the docs/community explicitly flag it as
  an escape hatch that "might compromise any safety guarantees" — every use has to be
  manually audited since it is unchecked trust, not a proof obligation discharged elsewhere. — [Haskell for all: Compile-time memory safety using Liquid Haskell](https://www.haskellforall.com/2015/12/compile-time-memory-safety-using-liquid.html) (anecdote)
- LiquidHaskell also supports the opposite direction — genuine manual proof — via
  proof-carrying functions (the `Proof`/refinement-reflection style) where a Haskell
  function *is* the proof term, checked by the same engine; this is a separate, heavier
  discipline than ordinary refinement checking, used when `assume` isn't acceptable. — [Refinement Types For Haskell](https://goto.ucsd.edu/~nvazou/refinement_types_for_haskell.pdf) (docs)
- Flux has the same shape of escape hatch: `#[flux::trusted]` lets a function's refined
  signature be accepted without the body being checked against it, for exactly the cases
  where the checker's decidable fragment can't follow the reasoning (or the code is
  unsafe/FFI). — [Flux GitHub / Lobsters discussion](https://lobste.rs/s/adm80u) (anecdote)
- Dafny draws the line differently: it has no separate proof language — a "proof" is a
  `lemma` (a ghost method whose postcondition is the theorem, discharged by the same SMT
  backend as everything else), and the automated/manual boundary is crossed with `assume`
  (accept without proof, for prototyping) or `calc` (a calculational proof skeleton where
  each step either auto-discharges or needs an explicit `assert` filled in). A proof is not
  "done" while any `assume` remains — that's Dafny's own completion criterion, not a
  convention. — [Dafny Reference Manual](https://dafny.org/dafny/DafnyRef/DafnyRef) (docs)

## 2. Inference vs. annotation economics

- LiquidHaskell's own termination-checking numbers: it proves termination automatically for
  96% of recursive functions in its evaluated codebase, at a cost of about 1.7 lines of
  termination annotation per 100 lines of code — a concrete, small, measured annotation tax
  for one specific checked property. — [Refinement Types For Haskell](https://goto.ucsd.edu/~nvazou/refinement_types_for_haskell.pdf) (measured)
- By contrast, systems with higher-order predicates (the paper names F*) require explicit
  instantiation of quantified facts by the user, whereas LiquidHaskell's predicates are
  restricted enough to be instantiated automatically — the tradeoff is stated directly:
  more expressive predicate logic buys less automation. — [Refinement Types For Haskell](https://goto.ucsd.edu/~nvazou/refinement_types_for_haskell.pdf) (docs)
- Flux's liquid inference (Houdini-style abduction over loop invariants) measurably beats
  hand-annotation: on its vector-manipulating benchmark suite versus the Prusti verifier, it
  cut annotation overhead from roughly 14% of code size (Prusti, manual loop invariants) to
  effectively 0% (Flux, inferred). — [Flux: Liquid Types for Rust, arXiv:2207.04034](https://arxiv.org/abs/2207.04034) (measured)
- LiquidHaskell's underlying solver, `liquid-fixpoint`, uses a Houdini-like predicate
  abstraction algorithm (guess-and-check over a fixed abstract-predicate template set) to do
  this inference; it is described as the least-fixpoint solver behind the whole liquid-type
  pipeline, not a bolt-on. — [liquid-fixpoint GitHub](https://github.com/ucsd-progsys/liquid-fixpoint) (docs)

## 3. Performance reality

- Flux, measured against Prusti on the same benchmark suite, is reported as roughly an
  order of magnitude faster in verification time in addition to needing half the
  specification lines — a direct paper-reported comparison, not an informal claim. — [Flux: Liquid Types for Rust, arXiv:2207.04034](https://arxiv.org/abs/2207.04034) (measured)
- The "Tunable Automation" paper's evaluation on real Verus codebases (IronKV, Splinter,
  Anvil, CapybaraKV) found that adding more ambient quantified facts to context (i.e. more
  automation) caused at most a 2x verification slowdown for ~98% of functions, but the
  worst-case slowdown for the remaining functions ranged 3x–19x — automation-for-speed is
  not a free trade even in the common case, and has a long unpredictable tail. — [Tunable Automation in Automated Program Verification, arXiv:2512.03926](https://arxiv.org/html/2512.03926) (measured)
- Dafny's own blog gives a concrete brittleness/perf number: a small rational-number `add`
  function needed ~679K Z3 "resource units" (RU) to verify under Dafny 3.13.1, then failed
  to verify at all under Dafny 4.x with no code change other than adding an unused local
  variable — refactoring the proof into smaller, more compartmentalized steps brought it
  down to 243K RU and made it verify reliably ("never fails" across repeated runs). — [Avoiding verification brittleness in Dafny](https://dafny.org/blog/2023/12/01/avoiding-verification-brittleness/) (measured)
- Dafny's own docs recommend capping per-definition solver resources (`resource-limit ≈
  200` in their unit convention) specifically so that a verification attempt fails fast and
  deterministically instead of hanging or succeeding nondeterministically near a timeout —
  this is an explicit acknowledgment that "runs as part of typechecking" does not hold
  unconditionally; large proofs are pushed toward being fast-failing rather than fast. — [Avoiding verification brittleness in Dafny](https://dafny.org/blog/2023/12/01/avoiding-verification-brittleness/) (docs)
- LiquidHaskell has been applied to 10,000+ lines of code drawn from real, popular Haskell
  libraries (bytestring, text, vector-algorithms, and others named in the paper), and the
  project's own test infrastructure records per-test CPU/wall-clock timing
  (`.dump-timings`, `--measure-timings-j1`) as a first-class concern — i.e., verification
  time is tracked as a real CI cost, not assumed negligible. — [LiquidHaskell GitHub README](https://github.com/ucsd-progsys/liquidhaskell/blob/develop/README.md) (docs)

## 4. Trust story

- Dafny's pipeline is Dafny → Boogie (verification-condition generator) → Z3 (SMT solver);
  all three layers are in the trusted base as ordinarily deployed. Separate research work
  exists specifically to make the Boogie VC generator *certifying* (i.e., independently
  checkable), explicitly framed as reducing the trusted base shared by Dafny, VCC, Corral,
  and Viper — meaning today's default Dafny setup does not have that independent check. — [Formally Validating a Practical Verification Condition Generator](https://arxiv.org/pdf/2105.14381) (docs)
- A 2021 paper on Liquid Haskell's equality axioms found a genuine unsoundness: naive
  functional-extensionality axioms interact badly with semantic subtyping, and separately,
  Liquid Haskell's default mapping of Haskell's `(==)` to SMT equality is unsound outright
  whenever a user defines a custom `Eq` instance that doesn't coincide with structural
  equality — a real, name-able soundness gap in a shipped refinement-type system, not a
  hypothetical. — [How to Safely Use Extensionality in Liquid Haskell](https://arxiv.org/pdf/2103.02177) (docs, per paper abstract/search excerpt — full PDF text could not be fetched to quote the fix directly)
- A survey framing (search-excerpted, comparing F*, Stainless, and Liquid Haskell) states
  none of the three isolates a small trusted kernel — their implementations are 1.3M,
  185.3K, and 423K lines of code respectively, and each has to be trusted to generate
  correct verification conditions in addition to trusting the SMT solver itself. — [EPTCS 396 (Logical Frameworks and Meta-Languages workshop proceedings)](https://arxiv.org/html/2311.09918) (docs)
- Z3 itself has open, live-tracked brittleness/nondeterminism issues relevant to any system
  built on top of it: a filed issue reports nondeterministic `check-sat-assuming` results
  (unsat vs. unknown) even with a fixed random seed, where an earlier `check-sat-assuming`
  call appears to leak state into a later one. — [Nondeterministic behavior observed despite seed set — Z3 issue #7525](https://github.com/Z3Prover/z3/issues/7525) (anecdote — filed issue, not yet resolved/confirmed root-caused at fetch time)
- A separate Z3 issue specifically documents "brittle use of quantifiers": whether a
  universal quantifier gets instantiated (and a proof goes through) can depend on
  irrelevant-looking details like whether a redundant antecedent is present, and this kind
  of brittleness is called out as showing up frequently through Dafny's usage pattern. — [Brittle use of quantifiers — Z3 issue #7363](https://github.com/Z3Prover/z3/issues/7363) (anecdote)
- Dafny's blog post itself names solver-version brittleness directly: Dafny changed its
  default bundled Z3 version between the 3.x and 4.x lines, and resource-unit (RU) counts
  are not directly comparable across Z3 versions — meaning "same spec, new toolchain
  release" is a documented, expected source of previously-passing proofs breaking. — [Avoiding verification brittleness in Dafny](https://dafny.org/blog/2023/12/01/avoiding-verification-brittleness/) (docs)

## 5. Escalation paths — is automation/speed/arbitrariness routed per claim, or fixed system-wide?

This is the most direct answer to the design question, so it's worth stating plainly: **in
none of the three systems studied is there a first-class, per-claim-chosen dial that a user
sets to pick a point on the {arbitrariness, automation, speed} tradeoff triangle before
asking for a proof.** What exists is either (a) a fixed default automation level with manual
opt-out/opt-in knobs discovered by trial and error, or (b) very recent research explicitly
naming this as an open gap and proposing a first mechanism.

- Dafny does have real per-claim automation control, but it is heuristic-tuning, not
  tradeoff-selection: `{:inductionTrigger}` overrides which patterns trigger automatic
  induction, and Dafny will suppress generating an induction hypothesis entirely if no
  matching trigger pattern is found (a stability feature that can also silently prevent an
  otherwise-provable claim from being proved automatically). This is a knob per lemma, set
  by hand, discovered through failure — not a designed "how hard should the system try on
  this claim" input. — [Dafny Reference Manual](https://dafny.org/dafny/DafnyRef/DafnyRef) (docs)
- Dafny's own docs describe VC splitting (breaking one large method's verification
  condition into smaller pieces checked independently) as a technique to manage
  automation/speed on hard proofs, and note Dafny "potentially dynamically adjusting these
  parameters based on previous verification attempts" — but this is described as an
  available technique/direction, not a settled, exposed per-claim selection mechanism. — [Investigating slow verification performance — Dafny wiki](https://github.com/dafny-lang/dafny/wiki/Investigating-slow-verification-performance) (docs)
- The clearest and most relevant prior art is the "Tunable Automation in Automated Program
  Verification" paper (2025, targeting Verus): it identifies exactly this gap — "tools
  choose between aggressive quantifier instantiation that provides more automation but
  longer verification times, or conservative instantiation that responds quickly but may
  require more manual proof hints" — as a *system-wide* choice today, and proposes
  `broadcast` / `broadcast use` as a mechanism to make that choice **per-function or even
  per-proof-context** rather than globally: quantified facts are opt-in at whatever
  granularity the proof author picks. Evaluated on real Verus codebases (IronKV, Splinter,
  Anvil, CapybaraKV), reducing required manual assertions by 2–8.6% depending on codebase,
  with a mostly-modest (98% of functions ≤2x) but occasionally severe (3x–19x tail)
  slowdown cost. The paper explicitly states the mechanism is "independent of Verus, and can
  be applied to other program verifiers" but was only implemented/evaluated in Verus. This
  is the one system in this survey that treats "how much automatic reasoning power to spend
  on this specific claim" as a first-class, chosen-per-claim knob rather than a global
  setting — but it is 2025-era research, not established practice, and it only tunes
  automation-vs-speed, not arbitrariness (expressiveness) as a third axis. — [Tunable Automation in Automated Program Verification, arXiv:2512.03926](https://arxiv.org/html/2512.03926) (measured — for the eval numbers; docs — for the design description)
- Separately, "gradual verification" research (a distinct line, e.g. Gradual C0 / symbolic
  execution for gradual verification) tackles a related but different problem: routing
  between static (compile-time) and dynamic (runtime) checking depending on how much of a
  spec is written, so that partially-specified code degrades to runtime checks rather than
  being rejected outright. Recent work here specifically targets the failure mode where
  prior gradual-verification systems didn't reward users with less dynamic checking as more
  of the spec was written — i.e., even this adjacent field has had to re-solve "make the
  automation/checking-cost tradeoff scale smoothly with what's specified," rather than it
  being solved. This is escalation along a static/dynamic axis, not an automation/speed
  axis, but it's the same underlying "choose per-property, not per-system" shape. — [Sound Gradual Verification with Symbolic Execution, arXiv:2311.07559](https://arxiv.org/pdf/2311.07559) (docs, per abstract/search excerpt)
- LiquidHaskell and Flux, by contrast, are effectively single-point-on-the-triangle systems:
  the decidable fragment is fixed at design time (QF-EUFLIA-ish), and the only per-claim
  lever a user has is binary — stay inside the fragment and get automatic proof, or drop to
  `assume`/`#[flux::trusted]` and get no proof at all. There is no intermediate "spend more
  solver budget on just this claim" dial documented for either system in the sources
  fetched. — [Refinement Types For Haskell](https://goto.ucsd.edu/~nvazou/refinement_types_for_haskell.pdf); [Flux GitHub](https://github.com/flux-rs/flux) (docs)

## 6. Dependencies

- Flux depends on a native Z3 binary plus its own `liquid-fixpoint` OCaml/Haskell Horn-solver
  layer; the install docs say to download a Z3 binary from Z3's GitHub releases and put both
  `liquid-fixpoint` and `z3` on `$PATH` — there is no pure-managed (JVM/JS/etc.) reimplementation
  bundled; it's a hard native-binary dependency. — [Flux Book: Install & Run](https://flux-rs.github.io/flux/guide/install.html) (docs)
- The Rust `z3` crate (used by some Rust SMT-facing tooling generally, not Flux specifically)
  offers a `vendored` feature that compiles Z3 from source via cmake and statically links it,
  as an alternative to requiring a system-installed Z3 — still native/C++, just vendored
  rather than externally installed. No pure-Rust reimplementation of Z3's decision procedures
  exists via this crate. — [z3 crate — crates.io](https://crates.io/crates/z3) (docs)
- For the JVM specifically, `JavaSMT` exists as a Java-side abstraction layer over multiple
  solvers (Z3, MathSAT5, Boolector, Yices2, CVC4) via JNI bindings — it manages *access* to
  native solvers from Java, it is not a pure-JVM reimplementation of an SMT decision
  procedure or a Horn-clause solver. — [JavaSMT 3: Interacting with SMT Solvers in Java](https://www.sosy-lab.org/research/pub/2021-CAV.JavaSMT_3_Interacting_with_SMT_Solvers_in_Java.pdf) (docs)
- No source found in this research documents a pure-managed-language (no native/C solver)
  reimplementation of Horn-clause solving or liquid-type inference for any of the three
  systems studied — LiquidHaskell's `liquid-fixpoint`, Flux, and Dafny all shell out to a
  native Z3 (or similar) binary as their SMT backend. This is a gap in what's findable, not
  a confirmed absence — flagging it as unresolved rather than asserting a negative with more
  confidence than the search supports.

## 7. Criticisms and failure modes from practitioners

- Dafny's own blog is itself a practitioner-facing acknowledgment of the "why won't this
  verify" problem: it documents a case where adding a provably-unused local variable
  (`var r1 := x + y`, never referenced again) caused a previously-verifying function to stop
  verifying — the exact "unrelated change breaks a proof" failure mode named in the
  research question, from the tool's own maintainers. — [Avoiding verification brittleness in Dafny](https://dafny.org/blog/2023/12/01/avoiding-verification-brittleness/) (anecdote, though sourced from the official blog)
- LiquidHaskell GitHub issues document the opaque-error-message experience directly: a
  "This should never happen" internal error surfaced to users with no actionable
  information, and a separate long-running issue ("Cleanup Liquid Type Errors") tracks that
  constraint-based error messages reference intermediate values introduced during
  verification that don't correspond to anything in the user's source, making failures hard
  to map back to the actual code. — [LiquidHaskell issue #647 "This should never happen"](https://github.com/ucsd-progsys/liquidhaskell/issues/647); [issue #305 "Cleanup Liquid Type Errors"](https://github.com/ucsd-progsys/liquidhaskell/issues/305) (anecdote)
- LiquidHaskell's own mitigation for this is tooling, not a fix to the underlying opacity:
  it emits an HTML dump with colorized source and mouseover-able inferred types per
  subexpression, described by the authors as "crucial for debugging the code and the
  specifications" — i.e., official acknowledgment that raw constraint failures aren't
  self-explanatory enough to debug without a separate visualization tool. — [Refinement Types For Haskell](https://goto.ucsd.edu/~nvazou/refinement_types_for_haskell.pdf) (docs)
- The Z3 quantifier-brittleness issue (#7363, cited above under Q4) is explicitly reported
  as something that "shows up frequently through Dafny's usage pattern" from a practitioner
  perspective — i.e. Dafny users hit this class of solver instability often enough that it's
  named as a recurring pattern rather than a one-off. — [Brittle use of quantifiers — Z3 issue #7363](https://github.com/Z3Prover/z3/issues/7363) (anecdote)
