# Adversarial attack: candidate "invert"

Target: `design-pass-abstract-kernel/candidates/invert.md`. Judge re-derives every
claimed walkthrough and load-bearing argument from the primary sources (not from the
candidate's own summary of itself).

## 1. The five witness/proof walkthroughs don't actually go through as formalized (FATAL)

§2's formal `Certificate` type is:

```
{ tag: "witness", input: ConcreteInput, polarity: boolean }
{ tag: "proof", rule: string, premises: Certificate[] }
```

`kernel/check.lua`'s `check()` has exactly two branches: run the evaluator on one
`ConcreteInput` and call `claim.holds(trace)`, or recursively verify `Proof` premises
against the fixed `RULES` table. There is no third certificate shape and no way for
`check()` to consult the program's *static* AST independent of some trace.

Re-derive instance 1 (`self` non-nil) against this: the walkthrough's `seq_compose`
premises include "the evaluator's own R-METHODCALL stepping rule instantiated at this
call site (a Witness-checkable fact about this program's AST: is `Cache:peek` defined
with `:` syntax?)". But §1.2(a) itself says method-call desugaring happens *inside* the
evaluator's stepping rule (`o:m(a) ⟿ o.m(o,a)`) — by the time a `Trace` event exists,
colon-vs-dot surface syntax has already been erased. Whether the call was written
`x:peek()` or `x.peek(x)` produces the same post-desugar event shape. So "is this
defined with colon syntax" is not a fact any `Trace` carries, and not a fact `Witness`
(which only ever inspects `claim.holds(trace)`) can check. Either:
- a third certificate kind ("static parse fact") is needed and isn't specified anywhere
  in the trusted core, expanding the "exactly this schema is the whole calculus"
  boundary the candidate leans on in §5, or
- the parse-fact premise is actually unnecessary (the real argument — "the call
  succeeded without an index-into-nil error, and indexing nil always errors
  unconditionally in Lua since you cannot attach a metatable to nil, so the receiver
  was non-nil" — works regardless of colon/dot syntax), in which case the walkthrough
  as written cites a premise the calculus can't check and doesn't need.

Either way, instance 1's certificate, as narrated, is not constructible by the trusted
code sketched two sections earlier in the same document. That's a formalization bug in
the flagship demonstration, not a nitpick — it's the thing the kill-test section exists
to prove didn't happen.

Instance 2 (`HEX` non-nil) and instance 3 (`FIFO`, same schema) are worse: the
walkthrough's `induct_trace` proof is "base case: table-constructor witness replay;
inductive step: a syntactic scan asserting no further `bind(_, HEX, _)` event exists...
checked by literally scanning the trusted trace it already has." A `Witness` produces
one finite trace from one `ConcreteInput` (§1.3: "Trace* ... a finite prefix"). Scanning
that one trace for absent rebinds proves, at most, "in *this one witnessed run*, HEX was
never rebound between these two points." The claim being certified is universal — "HEX
at line 125 is non-nil *whenever* that line executes, across every input, every call" —
which is true, but true because HEX has a single static assignment site in the source
text (an invariant of the *program's syntax*, not of any one trace). No finite number of
witnessed traces closes that gap (this is exactly the r.e.-not-recursive shape the
design itself names in §3.3): a second, unwitnessed input could in principle exercise a
different code path that reassigns HEX before line 125, and no trace-scan rules that
out. The only sound argument is a genuinely new rule — "single static assignment ⇒
trace-invariant across all executions" — which requires reasoning over the *program
text's* assignment-statement structure and relating it to trace semantics by a real
soundness theorem. That rule is not in §1.2(b)'s sketch, and it is precisely the shape
of "domain-shaped rule... instead of derived from [primitive evaluator events]" that
§5's own honesty section warns would "silently reintroduce exactly the special-casing
this frame forbids." The walkthrough either quietly assumes this undesignated rule, or
its "Proved" verdict is unsound as narrated (mistaking one witnessed-run's local fact
for a universal one). 2 of 5 "obviously decidable" corpus instances — the majority
shape, since deque (#4) reuses #1's schema and bigint (#5) is honestly left Open — rest
on this same unaddressed gap.

**Severity: FATAL to the kill-test section as evidence.** The architecture skeleton may
still be soundly patchable (see §6 below), but as written, the demonstration that this
design resolves the corpus's decidable-Open instances does not survive re-derivation.

## 2. The one law, as acyclicity, is a strictly weaker check than the certified law (SERIOUS/FATAL)

Re-derive: certified law (declarative-design.md) is "a claim used as hypothesis must
independently survive as obligation." The candidate implements this as: for every
hypothesis-role claim H, some certificate must discharge H as obligation, and that
discharge's dependency graph must not route back through a proof that used H as
hypothesis (no cycle).

Break it: nothing in the acyclicity check compares the *strength* at which H was
consumed against the *strength* at which H is discharged. Suppose H ("self is always
non-nil in this method, for every call") is used as a hypothesis inside `induct_trace`
to prove O universally, across all trace positions of that class. H's own "independent"
discharge could legally be a single `Witness` — an existential fact, true for exactly
one concrete run where self happened to be non-nil (e.g. the simplest smoke-test call).
That satisfies "some certificate independently discharges H, no cycle" — the check is
purely graph-shaped (edges, no cycle), not polarity/quantifier-aware — while leaving the
*universal* instance of H that O's proof actually leaned on completely unverified. A
false universal claim can ride to Proved on the back of a true-but-weak existential
discharge of its own hypothesis role. That is a structural path to a fake Proved, which
is exactly the failure mode the whole kernel/certificate split exists to make
impossible (ceiling-survey judgment.md's criterion (a), the first-ranked criterion of
five).

Separately, the design never specifies *when* `law_check` runs relative to when a
verdict is reported or consumed as a premise elsewhere. If it's a batch sweep over the
whole pool rather than a precondition on emitting any verdict, an O can be reported
Proved and consumed by other proofs before its hypothesis H's independent discharge
ever exists in the pool — a temporal loophole the acyclicity framing (a static graph
property) doesn't address at all.

**Severity: SERIOUS-to-FATAL** — this is a genuine soundness gap in the *one thing* this
candidate claims to have gotten cleanly right (§5's "Strong" bullet: "the one law becomes
a single, generic graph-acyclicity check"). Acyclicity is necessary but not shown
sufficient; it is a real shadow of the certified law, not an equivalent of it.

## 3. §3.3's H4 dissolution claim contradicts its own type sketch (SERIOUS, easily patched)

§3.3 asserts hyperproperties are free: "`holds` was never restricted to one `Trace`
argument... no extension needed, no kernel change needed." But §2's actual `Witness`
certificate is `{ tag: "witness", input: ConcreteInput, polarity: boolean }` — a single
`input`, not a list. A genuine 2-safety witness needs two concrete inputs producing two
traces to feed a 2-ary `holds`. As literally specified, that certificate cannot be
built. The claim "no kernel change needed" is false against the candidate's own code
sketch — patchable (make `input` a list), but the document oversells what its own
formalization currently supports, in the same paragraph that's supposed to be
collecting the design's free wins.

## 4. The calculus's growth path reproduces the v1→v4 accumulation, defended only by
   review discipline, not structure (SERIOUS)

Real Lua code the typechecker must eventually handle includes closures/upvalues,
metatables (`__index`/`__newindex`/`__call` chains, dynamic and instance-varying),
varargs, `pcall`/`xpcall` (non-local control transfer across an error boundary),
coroutines (suspended continuations, trace interleaving). None of §1.2(b)'s four rule
shapes (replay, seq/branch composition, trace induction, constant-fold) obviously covers
non-local control transfer or dynamic dispatch through a metatable resolved differently
per instance — those need either disjunctive reasoning over multiple possible dispatch
targets or something closer to separation-logic-shaped heap/aliasing reasoning, which
the design never mentions (and which every entrant in the ceiling survey named as an
unsolved gap nobody has a mechanism for — judgment.md §5 "Open in all five" item 2; this
candidate inherits that gap wholesale rather than closing or even touching it).

The design's own honesty section admits the calculus is "unavoidable trusted surface,"
"not designed here," and that discipline against domain-shaped rules "has to be
maintained by review, not enforced structurally." Re-derive what that actually means at
scale: every new Lua idiom the typechecker needs to reach requires a new named rule in
`RULES`, individually hand-proved sound "at the meta level," reviewed by a human, and
version-bumped into the trusted core. That is rule-by-rule accretion into a trusted
surface, gated by manual review rather than mechanical verification — the same *shape*
as the v1→v4 postmortem (CLAUDE.md's stated reason v5 exists), merely relocated from
"claim vocabulary" (genuinely fixed, to the design's credit) to "inference vocabulary"
(not fixed, growing, and un-mechanized). The candidate names this honestly as a
limitation but proposes no structural safeguard against it — "discipline... maintained
by review" is exactly the kind of unenforced convention the project's own hard
constraints ("no special-casing... never work around it") exist to rule out elsewhere.

## 5. "Proven sound once against the evaluator" — trust chain bottoms out informally (SERIOUS)

Nothing in the candidate specifies who proves a rule sound, in what formal system, or
what machine (if any) checks that proof. "Stated and proved once, at the meta level" —
by a human, in a comment, reviewed by another human, is the only process implied. This
relocates the exact problem the design claims to solve for claims (every claim
individually machine-checked, never trusted on say-so) one level up to rules: a rule's
soundness is trusted on the strength of an informal proof a human wrote and another
human reviewed, unmechanized. The design is honest that this surface exists (§4/§5) but
doesn't reckon with the fact that an *unmechanized* meta-proof is exactly the kind of
unverified assertion the whole architecture was built to eliminate — it's just been
moved to a smaller, less frequently touched location, not eliminated.

## 6. Evaluator target mismatch: Lua 5.1 vs. the project's actual LuaJIT+FFI surface (SERIOUS)

§1.2(a) commits the trusted evaluator to "Lua 5.1's real operational semantics." But
CLAUDE.md states the project's actual target is "Target LuaJIT, don't require it," and
the library tiering strategy (system > FFI > pure Lua, per-library) makes FFI a
first-class, common tier across the inventory, not a peripheral concern. A Lua-5.1-only
evaluator has no model for FFI cdata semantics (LuaJIT's `ffi.cdef`/`ffi.new`/ctype
arithmetic), so any claim touching FFI-typed values is outside the trusted evaluator's
domain by construction — not degraded, simply uncertifiable, forever Open. §4 lumps
this under "FFI, eval, OS interaction... assumed given," alongside metatables, as if a
peripheral blind spot; for *this* codebase, where FFI is a load-bearing performance tier
in most libraries per the repo's own conventions, the gap is closer to "a large fraction
of the corpus is out of scope for Proved/Refuted from day one," which the design doesn't
size or flag as such.

## 7. Replay cost vs. the repo's own enforced CI budget (SERIOUS, unaddressed)

Every `Witness` certificate requires running a mechanized Lua-5.1 stepper — written in
pure Lua per the zero-dependency constraint — itself interpreting the target program.
That's meta-circular interpretation overhead (an interpreter, in an interpreter, in
LuaJIT), plausibly 2-3 orders of magnitude slower than native execution for anything
with real loop/recursion depth. The repo's own pre-commit hook rejects any file whose
typecheck exceeds 30 seconds, "timeouts always reject... don't bypass." §5 admits
certificate bookkeeping cost is "unaudited... unestimated" at the first slice's already-
observed scale (2401 claims, 8 files). The design offers no argument that Witness replay
at real corpus scale fits inside the repo's own hard timeout contract; this isn't
disclosed as an open question anywhere in the candidate, unlike most of its other gaps.

## 8. Name-keying / hard-constraint check

The trusted `RULES` table is keyed by rule name (`seq_compose`, `induct_trace`,
`const_fold`) — dispatch on *inference-rule* identity, not on claim/domain vocabulary
(no `"self"`, `"colon-call"`, `"HEX"` anywhere in trusted code). That distinction holds
up under inspection and is the design's one clean, verifiable win: genuinely zero
claim-vocabulary switches in `kernel/*.lua`. The risk is entirely in what gets added to
that table later (see §4) — the boundary is real today, structurally unenforced against
erosion tomorrow.

## Verdict

**SURVIVES-WOUNDED.**

The core skeleton — opaque `Claim.holds` closures, a trusted evaluator, a small
versioned inference calculus, and a content-blind acyclicity check as the one law — is a
coherent architecture and its "no claim vocabulary in the trusted core" property holds
up under inspection (§8). But the evidence offered that it *works* mostly doesn't
survive re-derivation: 2 of 5 flagship walkthroughs (HEX, FIFO) either assume an
undesignated rule or mistake an existential replay for a universal proof; a 3rd (self
non-nil) cites a certificate kind the formal type doesn't support; the H4-for-free claim
contradicts the candidate's own `Certificate` type; and the one law's acyclicity
implementation is strictly weaker than the certified law it claims to realize (no
quantifier/strength check between a hypothesis's use and its discharge — a real path to
a fake Proved). The calculus-growth concern (§4) and the trust-chain concern (§5) are
both disclosed by the design itself, which earns it credit for honesty but doesn't
close the gaps.

**Strongest idea worth grafting regardless of outcome:** the one law recast as a
content-blind graph-acyclicity check over certificate dependency edges — provided it's
patched to also compare the *quantifier/strength* at which a hypothesis claim was
consumed against the strength at which its independent discharge actually proves it
(existential discharge must not satisfy a universal use). That patch turns a real hole
into what could be the cleanest formalization of the certified law across all
candidates in this pass.
