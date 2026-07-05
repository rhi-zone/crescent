# Adversarial attack: "unifier + mechanized stepper + one grounding rule"

Target: `design-pass-abstract-kernel/candidates/evidence.md`.
Method: re-derive each kill-test walkthrough against the cited source material
(`declarative-design.md`, `execution/first-slice-run.md`, `research/ceiling-survey/judgment.md` §5,
`open-threads.md`) rather than accepting the candidate's own narration.

---

## Attack 1 — the "open address algebra" doesn't fix the 2174-shrug; it relocates the coordination failure one abstraction level up

**Severity: FATAL** (to the specific claim "this is the direct fix for the site/slot mismatch"; not fatal to the whole candidate, see below).

The observed failure (first-slice-run.md lines ~369-403) was: `harvest_stated` emits
site `"<file>:<def_line>:<funcname>"` / slots `entry:`/`exit:`; `harvest_mined` emits
site `"<file>:<line>"` / slots `deref:`/`branch:`. These never coincide as *strings*.
The candidate's fix is: replace string-equality with term unification over an `Address`
algebra, and assert (not demonstrate) that "a stated claim's address can be
`app("param_binding", {atom("byte1"), atom("s")})` and a mined claim's address can be
`app("param_binding", {atom("byte1"), atom("s")})` too — same functor, same structure."

That sentence is the whole fix, and it's begging the question. Unification only does
work when two terms are already built from the *same functor vocabulary with matching
arity/field structure* — it reconciles unbound *variables*, not incompatible *shapes*.
The actual observed bug was a shape mismatch (a 3-field site key vs a 2-field site key,
disjoint slot namespaces `entry:/exit:` vs `deref:/branch:`). Unification does nothing
for that unless `harvest_stated` and `harvest_mined` are *also* rewritten to emit into a
shared functor vocabulary — at which point the real fix is "someone rewrote both
harvesters to agree," and unification is decoration on top of a coordination act that
the candidate doesn't specify anyone doing. The candidate's own text admits this is
"producer-side" and "an open, versioned interop contract between producers — not
kernel code" — i.e. exactly the same governance vacuum that produced the original
mismatch (two independently-written harvesters that never agreed on a convention),
just moved from "agree on a string format" to "agree on a term algebra," which is
*harder* to spontaneously converge on (more degrees of freedom: functor names, arity,
argument order, nesting depth) not easier. Two future producers minting
`app("nonnil_binding", {var, site})` and `app("param_binding", {site, var})` (same
facts, args swapped) fail to unify just as hard as `"file:line:fn"` vs `"file:line"`
did. Nothing in the design assigns ownership of the address-algebra convention to
anyone, reviews it, or versions it — "open, versioned" is aspirational prose, not a
mechanism.

**Why it doesn't sink the whole design:** the execution-based certificate checking
(`check_box`/`check_witness` actually calling `oracle`) is a real, independent
contribution that doesn't depend on the address-unification story working. A future
session could keep that half and admit the address-algebra half needs a real owner
(a schema registry, a canonicalization pass, or dropping term-unification for a
simpler shared key-builder function) without losing anything else.

---

## Attack 2 — `implies()` carries the actual decision power, and the walkthroughs quietly assume it away

**Severity: SERIOUS** (disclosed by the design in §4, but the disclosure is one paragraph while the mechanism does most of the invisible work in every walkthrough).

`check_box`'s condition (c), `implies(cert.invariant, claim.phi, oracle)`, is exactly
"is one predicate implied by another" — the general form of exactly the ⊨-decision
problem the original draft got stuck on (Hole H1/H2). For instances #2/#3 (HEX/FIFO)
the walkthrough calls this "trivial (identity or a one-step schema lookup)." For
instance #1/#4 (self) it's folded silently into "the invariant... is checked by
walking `oracle.entries(method)`... and confirming none passes a nil receiver — which
is itself a claim the same producer must either ground trivially... or cite
recursively." That "either/or" is doing the load-bearing work of the entire
walkthrough and is never actually discharged for the general case — only asserted
plausible for the five cherry-picked instances, which happen to be exactly the ones
selected because the corpus's own first-slice-run flagged them as "obviously decidable
in seconds by a human." The candidate is honest that `implies()` "is quietly doing
real work" and "for a hard invariant it's another undecidable-in-general call" (§4) —
but this means the actual delta over the dead draft is: a cleaner protocol boundary
(a `Predicate.decide` closure instead of an ad hoc ⊨ judgment) and closure of Hole H3
(◇-refutation as Proved(□¬φ) via the same rule) — not new decidability. The shrug
didn't disappear; it moved from "do two topic-key strings match" to "does this
producer's `implies` predicate terminate and return true," which is the same class of
problem the draft was stuck on, now wearing a Predicate-protocol costume. That's a
legitimate architectural improvement (uniform interface, composability via citations)
but the candidate's own §5 "Strong" bullets overclaim this as removing "a single
kernel-level name for self/colon-call/non-nil/branch" as if that's the hard part —
it was never the hard part; `implies()` was, and it's exactly as hard as before.

---

## Attack 3 — citation-omission laundering: the "one law" has teeth against a naive liar but none against an honest-looking mutual-recursion producer

**Severity: SERIOUS**, and it directly undercuts the "LCF-style" framing the design borrows for credibility.

Constructed scenario: producer P mints claim A with `cert.invariant_A.decide` that,
internally (not through the kernel's `phi_of` dispatch, just by closing over a shared
reference), consults claim B's truth-value as a subroutine — but P doesn't list B in
`cites`. Simultaneously (same producer or a colluding second one), claim B's
`invariant_B.decide` consults A's truth-value, also undeclared. Each `decide` closure,
called in isolation against real oracle states, may genuinely return `"true"` for the
specific finite entry/step set the kernel happens to walk (a self-referential
fixed-point that looks locally consistent, the classic unsound "assume the thing
you're trying to prove" gap) — because the kernel calls each closure directly and
never traces what other values it reads. `grounded_and_acyclic` walks only the
*declared* `cites` edges; both A and B declare `cites = {}`, so the DFS sees two
isolated, trivially-grounded claims and mints Proved for both. The circularity is
real; the kernel never sees it.

The candidate's own §4 states this plainly: "The kernel cannot detect an unreported
citation from the outside... `cites` is a producer-supplied manifest, not something
the kernel derives by inspecting the closure." That's correct, but the design then
calls this "the same 'untrusted producer, trusted kernel' boundary every LCF-style
design accepts" — that comparison undersells the gap. In genuine LCF architectures,
the *type system* prevents constructing a `thm` value except through kernel-exposed
primitive inference rules; there is no side-channel by which a term of the abstract
theorem type can come into existence without having actually passed through a
kernel-checked step. Here, `decide` is an arbitrary closure the kernel never inspects,
and the citation graph is a *separate, unenforced manifest bolted alongside it* — the
correspondence between "what the closure actually reads" and "what `cites` claims it
reads" is asserted, not derived, not typed, not checked. That is a materially weaker
guarantee than LCF's, dressed in LCF's vocabulary. The one law ("must independently
survive as an obligation") is stated in `declarative-design.md` as one of exactly three
certified pillars of the whole project — undermining its teeth is not a footnote.

Direct counter the design *does* win: naive lying (`decide = function() return "true"
end` unconditionally) is genuinely caught, because the kernel actually executes the
closure against real states rather than trusting a producer's say-so token — that part
of §3.2 is correct and is real progress over `check.lua`'s pure topic-key matching.
The gap is specifically citation-graph omission, not invariant-value lying.

---

## Attack 4 — re-deriving instance #1 (colon-method `self` non-nil): the invariant as sketched is not actually inductive over the real execution set

**Severity: FATAL** to the walkthrough as stated; exposes the classic invariant-strengthening gap the task asked me to check for.

The claim is a `□`-modal universal statement over `𝕋_Γ(P)` — "for every execution,
`self` is non-nil at method entry." The candidate's certifying invariant is checked
via `oracle.entries(method)`, described as "finitely many static call sites," with
`self` guaranteed non-nil because "colon-call syntax `obj:m(args)` is desugared... to
`obj.m(obj, args)`."

That desugaring guarantee is a property of *one calling expression*, not of the
*function* `m` universally. Lua permits a method to be invoked through paths the
colon-call desugaring doesn't cover: extracting the function value directly
(`local f = obj.m; f(nil, x)`), storing it in a dispatch table and invoking positionally,
invoking through a metatable `__index` chain where the resolved function is unrelated
to any colon-call syntax at the definition site, or calling it via `pcall`/variadic
forwarding. `oracle.entries` is typed as returning "statically enumerable entry
states" for a *definition site* — nothing in the Oracle contract guarantees this
enumeration is a *sound over-approximation of every actual invocation* of that
function across the whole program, including ones reached through first-class
references. If `entries()` is (as "statically enumerable" suggests) a syntactic
enumeration of colon-call sites found by grep-like static matching, then a first-class
escape of the method value is silently invisible to the invariant check — the
certificate would mint Proved(□non_nil(self)) while a concrete execution (calling the
extracted function with a nil first argument) refutes it. This is not the
"semantics-reality gap" §4 already names (stepper fidelity to FFI/eval/OS) — it's a
narrower, more mundane gap: whether the *enumeration procedure itself* is complete
over the execution set the modal claim quantifies over. The walkthrough's confidence
("Lua's own operational semantics... exposes that desugaring as a static fact") glides
past exactly the "does the invariant need strengthening to cover indirect invocation"
question that is the textbook failure mode of inductive-invariant checking, and the
design offers no mechanism (a whole-program escape analysis, a closed-world
call-graph assumption, anything) to close it — it simply doesn't come up.

This also infects instance #4 (`Deque:pop_front`, same producer/shape) identically.

**Separately, on `preserved_by_every_step` for looping/recursive code:** the candidate
states Lua CFGs are finite "even though execution sets are not," then describes the
check as "walk[ing] a (finite) step relation" — but a finite CFG does not make the
*concrete trace/state* relation finite when the CFG contains a loop or recursion;
`preserved_by_every_step` as literally described (call `decide(oracle, state)` against
enumerated `(event, state')` pairs from `oracle.step`) does not terminate for a
`while` loop with a large or unbounded iteration count unless the check is actually
performed structurally per-CFG-edge (classic VC generation: check the invariant is
preserved once per edge, symbolically, not once per concrete iteration) — which is a
real abstraction the sketch never states and `Predicate.decide`'s signature (`(Oracle,
State) -> verdict`, concrete state in, not CFG node) doesn't obviously support. Either
the design silently intends per-edge symbolic checking (fine, but then it needs to say
so, and `decide` would need to accept a set/class of states, not one concrete state),
or the literal mechanism as described genuinely fails to terminate on any looping
input — which would make "no search, no SMT, no invariant machinery" (claimed for
instances #2/#3, which do involve a `for` loop populating `HEX`) an overclaim.

---

## Attack 5 — evidence-first bias: the corpus that produced these 5 instances is exactly the corpus these 5 producers were built to fit

**Severity: SERIOUS.**

The 8-file, 2401-claim corpus (first-slice-run.md) is small, well-tested library code
(`lib/lru`, `lib/deque`, `lib/json`, `lib/queue`, `lib/bigint`) with a claim
distribution dominated by non-nil dereference and branch-reachability claims (~1839
of 2401 mined). The candidate's producers are hand-fit to exactly these shapes:
no-reassignment invariants (single name, single scope), colon-call self-nonnil, and
test-trace-sourced reachability. None of this is dishonest — §4 and §5 explicitly flag
the corpus-calibration risk ("the 'optimize the common case' framing is calibrated to
crescent's actual `lib/` corpus, which may not generalize").

But repo-wide Lua (per CLAUDE.md's own `docs/lua-gotchas.md`) routinely contains shapes
none of the five producers touch and the `Address`/`Oracle` sketch doesn't obviously
extend to without new design work: metatable-mediated dispatch (breaks the colon-call
desugaring assumption directly, see Attack 4), closures sharing a mutable upvalue
across multiple independently-defined functions (the no-reassign invariant's own
implementation checks `ev.site > def_site` — a textual/site-ordinal comparison, not a
temporal-execution-order-and-lexical-scope-identity test; a closure defined at an
earlier textual site but invoked later at runtime to rebind a captured upvalue would
not be caught by that specific comparison as sketched — a latent bug in the
illustrative producer itself, not just a missing feature), coroutines (yield/resume
introduces multiple live, interleaved stacks; nothing in the Oracle sketch says
whether `entries`/`step`/address `scope=N` identifiers remain stable and unambiguous
across a suspend/resume boundary), and error paths via `pcall`/`error` (routinely
under-tested, meaning the reachability fast path — instance #5's whole mechanism —
degrades to permanently, honestly Open for exactly the code most likely to hide real
bugs: error handling). The design degrades honestly where it's evidence-informed
(explicitly says thin test coverage yields thin reachability answers "for reasons that
have nothing to do with this design's ceiling") — but that's also the tell that the
headline "closes 5 real Open instances, one rule closes a whole class at once" result
is evidence-fit to a curated demo set, and there's no evidence offered (nor claimed)
about the distribution the design will actually face at repo scale.

---

## Attack 6 — the ceiling claim is an honest relabeling, not a hidden one, so it survives — but "buys" less than §5's framing implies

**Severity: COSMETIC** (fully disclosed; noted for completeness per the mandatory checklist).

§3.3 states outright: "Rice is not evaded, it's pushed to 'does a producer supply an
invariant whose preservation check terminates' — same as V/AI in the ceiling survey."
That's accurate and matches judgment.md §5's own framing that every entrant reaches
the ceiling only asymptotically. No attack sticks here beyond what the design already
concedes. What I'd push back on is §5's "Strong" bullet claiming this "never regresses
anything the current check.lua could already do" and is "strictly more general" —
true in the narrow technical sense (unification subsumes string equality as the
ground-term degenerate case, ignoring Attack 1's point that the *producers* still have
to agree on the term shape for that subsumption to fire in practice), but the actual
net new *decision power* delivered is: (a) H3 folded into one rule instead of a
separate hole — real, small, structural — and (b) a concrete, callable protocol
(`Predicate`/`InvariantCert`) replacing an abstract ⊨-judgment — an implementation
scaffold, not new theorem-proving power. Both are legitimate contributions; neither
moves the actual computability frontier, and the design doesn't claim they do — I'm
flagging only that §5's rhetoric ("strictly more general," "never regresses") reads
more triumphant than the §3.3/§4 honesty warrants.

---

## Attack 7 — repo hard-rule compliance: no kernel-level name-keying found; pure-Lua unification is fine; step-closure cost at repo scale is the real open question

**Severity: COSMETIC / OPEN**, not a design flaw so much as an unquantified risk.

Checked the kernel sketch in §2 for name-keyed special-casing: `Address`, `Predicate`,
`Modal` ("box"/"diamond"), `Claim`, `unify`, `check_box`, `check_witness` — none
branches on a domain string like "self," "FIFO," or "non-nil." This holds up; the
domain vocabulary lives entirely in the example producer (`no_reassign.lua`), which is
explicitly outside `lib/declc`'s trust boundary — consistent with the repo's
caps-first/no-special-casing rule. Robinson unification and a small stepper are both
straightforwardly implementable in pure Lua (no FFI, no external dep) — no violation
of the zero-dependency or pure-Lua-baseline rules.

The unresolved question is cost at repo scale, and it's exactly Attack 4's
termination concern generalized: if `preserved_by_every_step` is checked by literal
concrete-state enumeration rather than per-CFG-edge symbolic reasoning, cost is
unbounded for any loop/recursion, not just "large." The design states budgets exist
("within budget," §3.3) but never specifies what bounds a step-closure search when the
literal mechanism described has no structural termination guarantee independent of a
producer picking an already-tiny invariant. This is the same gap as Attack 4's second
half, restated as a scale/cost question rather than a correctness question.

---

## Verdict: SURVIVES-WOUNDED

The candidate's core architectural move — replace a flat topic-key string-equality
check with (a) a trust boundary around an executed, re-verified certificate protocol
and (b) folding ◇-refutation into the same universal-invariant rule — is real and
independently defensible; it doesn't collapse under Attack 2's or Attack 6's pressure
because it never claims to solve entailment, only to give it a clean, composable home,
and it's honest about that in its own §4. But two of the mandatory attack points land
harder than the design's self-critique acknowledges: the address-algebra story
(Attack 1) doesn't actually fix the 2174-shrug, it relocates the exact same
producer-coordination failure to a harder-to-coordinate vocabulary with no owner; and
the flagship walkthrough (Attack 4, colon-method `self`) isn't actually sound as
sketched — `oracle.entries`'s completeness over indirect/first-class invocation is
assumed, not established, which is the textbook inductive-invariant-needs-strengthening
gap the task asked me to hunt for, found in instance #1/#4 specifically, the two
instances the design leans on hardest ("one producer, one rule, closes all 5
occurrences... at once"). Attack 3 (citation-omission laundering) is real and the
LCF comparison the design borrows overstates the guarantee it actually has. None of
these are hardcoded-result violations of CLAUDE.md's no-special-casing rule — the
kernel itself stays clean — but they are real soundness/completeness gaps the
candidate's own confident narration glides past.

**Strongest idea worth grafting even if this candidate is later demoted:** folding
◇-refutation into Proved(□¬φ) via the *same* invariant rule (closing Hole H3 with zero
new machinery) is a genuine simplification independent of everything else here — worth
keeping regardless of what happens to the address algebra or the entailment story.
