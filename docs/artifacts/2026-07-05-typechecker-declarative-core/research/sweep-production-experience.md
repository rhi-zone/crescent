# Sweep: production gradual/optional checkers — engineering experience record

Family: shipped checkers for dynamic languages (Luau, Sorbet, Flow, mypy/Pyright,
Hack, plus Lua prior art and Dialyzer as the never-reject production datapoint).
Lens: what a new Lua checker must not re-learn; whether anything shaped like the
crescent design (graded assumption pool, three-valued verdicts, never-reject) has
production precedent. Sources are blogs/talks/RFCs/papers as read on 2026-07-05.

## (a) Hard-won lessons a new Lua checker must not re-learn

1. **False positives are the trust-killer; everything else is secondary.**
   Luau's semantic-subtyping adoption was motivated entirely by eliminating FPs
   ("syntactic subtyping... can incorrectly reject valid code") and they name the
   FP/FN tradeoff explicitly: strict mode errs FP-side, nonstrict FN-side
   [luau.org/news/2022-10-31-luau-semantic-subtyping]. Dialyzer's 15-year
   adoption is credited to "never wrong for defect detection" — success typings
   guarantee reported errors are real ("no programmer likes a tool that tells him
   his program cannot run when it has been doing so in production")
   [dl.acm.org/doi/10.1145/3471871.3480952; learnyousomeerlang.com/dialyzer].
2. **Two inference engines for two modes is a documented disaster.** Old Luau had
   separate strict/nonstrict inference; changing a module's mode broke its
   consumers. The new solver unifies inference — modes differ *only in which
   errors are reported* [rfcs.luau.org/new-nonstrict.html; devforum "General
   Release: Luau's New Type Solver"]. Directly supports crescent's shape: one
   consistency semantics, verdict grading as reporting policy.
3. **Annotation economics: annotations are resisted until tooling pays for them,
   and migration must be done *to* the codebase, not *by* its authors.** Sorbet:
   devs resisted sigs until autocomplete/jump-to-def shipped; Stripe's rollout
   was 7 months of the *tools team* running codemods "underneath people"
   [infoq.com/presentations/sorbet-type-checker-ruby]. Hack: Facebook converted
   nearly the whole PHP codebase via homegrown refactoring tools plus voluntary
   organic conversion [engineering.fb.com 2014 Hack post]. Flow admitted its
   safety turn "might make Flow more intrusive (asking for more type
   annotations)" — and that intrusiveness is what it traded external adoption for
   [medium.com/flow-type/clarity-on-flows-direction].
4. **Unannotated-code policy is the biggest semantic fork in the family.** mypy
   skips unannotated functions by default; Pyright infers and checks everything
   [github.com/microsoft/pyright/docs/mypy-comparison.md;
   pydevtools.com/handbook]. Crescent's mined-belief source is a third answer:
   check unannotated code against *graded* mined assumptions — no production
   system does this, but Pyright's experience says inference-over-unannotated is
   viable at scale; mypy's says skipping it silently rots coverage.
5. **Performance is a design constraint, not an optimization.** Sorbet: ~100k
   LOC/s/core, "10x faster than javac," millisecond IDE latency as an explicit
   requirement [InfoQ talk]. Luau: liberal normalization took typechecking "from
   under a minute to overnight"; fix was syntactic subtyping as fast path,
   normalization only on failure [semantic-subtyping post]. A consistency-pool
   design needs its own fast path story from day one.
6. **Stub/definition ecosystems are load-bearing:** RBI files (Sorbet), typeshed
   (mypy/Pyright), LLS addon definitions. Sorbet auto-generated RBIs for
   metaprogrammed code rather than asking users to write them.
7. **Error messages: Sorbet shipped suggested fixes plus an autofix flag from
   early on — friction reduction, not just diagnosis** [InfoQ talk].

## (b) Luau specifically — Lua hazards and never-reject-shaped decisions

- **Metatables:** "the mere existence of a metatable throws the type checker
  off"; no way to attach metatable type info without `typeof()` boilerplate; the
  OOP-via-setmetatable idiom needed dedicated RFCs (metatable type functions)
  [luau-lang/luau#393; rfcs.luau.org/metatable-type-functions.html; devforum].
  For crescent: setmetatable idioms are where mined beliefs will be densest and
  least reliable; grade accordingly rather than special-case.
- **Multi-return/varargs:** first-class type packs were required; casting a
  multi-return truncates to the first value — a persistent user trap
  [luau.org/types; create.roblox.com/docs/luau/type-checking].
- **require-as-dynamic-load:** strict mode only typechecks `require` of
  statically-resolvable values; dynamic requires are simply outside the system
  [create.roblox.com/docs/luau/type-checking]. Crescent's `$Require<T>` intrinsic
  is already ahead of this; the hazard is dynamic require paths.
- **Never-reject precedent inside Luau: yes, deliberately.** The new nonstrict
  mode is exactly a never-reject consistency check: "if non-strict mode reports
  an error, then we have high confidence that there is a code defect" — it
  reports only witnessed-guaranteed defects (`"hi" + 5`, guaranteed-nil access,
  write-only properties) via a constraint pass asking what argument types would
  *avoid* the runtime error (constraint ≡ `unknown` ⇒ warn)
  [rfcs.luau.org/new-nonstrict.html]. They did not reject the idea — they made it
  one of two *reporting policies* over one engine, because one policy cannot
  serve both defect-hunters and tooling-only users [hatra21 position paper,
  arxiv.org/abs/2109.11397]. hatra23 adds graded *error suppression* as a
  first-class mechanism [research.luau-lang.org/hatra23/hatra23.pdf].

## (c) Three-valued verdicts in production — the absence, and what fills the hole

No surveyed production checker ships per-site three-valued verdicts
(pass / fail / undecided) to end users. What ships instead:

- **Binary verdicts under a chosen policy** (Luau strict vs nonstrict; Dialyzer
  = never-reject only). The third value exists but is *global* (mode choice),
  not per-finding.
- **Undecidedness surfaced as coverage, not alarms:** Sorbet's file sigils
  (`# typed: false/true/strict/strong`) and typed-coverage metrics (CZI: 92%
  file-level, 75% callsite-level) [medium.com/czi-technology]; Pyright's
  `Unknown` (distinct from `Any`) surfaced via opt-in `reportUnknown*`
  diagnostics — the closest per-site precedent, and it is opt-in-strict-only.
- Practitioner framing where three-valued review checklists exist: "UNKNOWN does
  not mean safe... should be treated as a conditional FAIL pending manual
  verification" [AIRA, arxiv 2604.17587] — i.e. users binarize it anyway.
- Abstract-interpretation tools (Astrée lineage) are internally three-valued but
  present alarms binarily [arxiv cs/0701193].

**Live risk for crescent's UX bet:** the record suggests undecided-as-a-verdict
collapses in users' hands — ignored (becomes noise ⇒ de facto never-reject) or
blocking (becomes a false positive with extra steps). The production-tested
mitigations are: (i) undecided as an aggregate/queryable metric, not a per-site
alarm; (ii) undecided as mode/policy selection. Crescent's grading
(witness-status × credence) is richer than anything shipped; the frame-threat is
not that it's wrong but that no one has ever gotten users to *read* a third
value. Counterweight: Dialyzer proves never-reject alone is durable, and Luau
proves two policies over one engine works — crescent's design degenerates
cleanly to both.

## (d) What actually drove adoption

- **Sorbet:** IDE features + speed + central codemod migration. Nominal typing
  chosen for *readability* at a code-reading-heavy org, not soundness [InfoQ].
- **Hack:** runtime enforcement bridging the gradual gap + refactoring tools +
  organic voluntary conversion [engineering.fb.com].
- **Flow (negative case):** prioritized soundness/predictability for internal
  scale, explicitly ceded external adoption; TS won on ecosystem/editor, not on
  the soundness debate [medium.com/flow-type/clarity-on-flows-direction;
  mgmarlow.com/words/2025-03-01-reminiscing-on-flow].
- **Dialyzer:** zero false positives respecting already-running code; the only
  Erlang typing effort that ever reached wide adoption [Erlang 2021 keynote].
- **Luau:** telemetry-driven FP reduction for a heterogeneous (many novice)
  community; type-driven tooling valued even by users indifferent to defect
  detection [hatra21; arxiv 2403.02409 (telemetry-at-scale paper)].
- **mypy vs Pyright:** Pyright's growth tracks editor integration (Pylance
  default in VS Code) and check-everything inference, not spec soundness
  [pydevtools.com/handbook].

The literature's soundness debates predicted none of this. Adoption followed:
no false positives on running code, editor value, speed, and someone else doing
the annotation work.
