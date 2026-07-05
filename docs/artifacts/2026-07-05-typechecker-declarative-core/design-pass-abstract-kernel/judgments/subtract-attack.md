# Adversarial attack: SUBTRACT candidate (abstract kernel)

Target: `candidates/subtract.md`. Method: re-derive every walkthrough from the
cited source files rather than accept the prose; try to construct the
concrete false-Proved / false-Refuted / gaming scenarios the mandatory
pressure points name.

## Attack 1 — the flagship worked example is itself an unsound rule (FATAL)

`colon-self-nonnil-v1` (§2.2, reused in §3.1 instances 1 and 4 — 5 of the 8
corpus "obviously decidable" repro sites) checks:

```lua
return def.form == "colon"
  and def.receiver_param == target.expr
  and target.claim == "non-nil"
```

with the inline comment: "real inference: Lua's `:` calling convention
guarantees the first implicit parameter is bound to a non-nil value whenever
invoked via `:`."

That's false in general Lua semantics. Colon *definition* syntax
(`function Cache:peek(key)`) only sugars an implicit `self` parameter — it
places zero obligation on *callers*. Nothing stops `Cache.peek(nil, key)` or
`local f = Cache.peek; f(nil, key)`. The rule inspects only the definition
site; it never looks at call sites, so it cannot actually establish "self is
non-nil at this dereference" — it establishes "this function was *defined*
with colon sugar," which is a different, weaker fact. To make the claimed
inference sound you'd need a whole-program (or whole-module) call-site
census proving every call to `Cache:peek` uses `:` syntax — substantially
more machinery than the four-line `check` shown.

This is not a hypothetical "what if a rule is wrong" — it is the design's
own chosen illustration, presented as "real inference... not a string
comparison," used to retire 2 of the 5 mandatory corpus instances and to
argue the "closes whole classes at once" strength (§3.1 #4: one rule fires
across 4 sites in `deque/init.lua`). The kernel re-executes this exact
`check` faithfully, gets `true`, and mints Proved. This is a concrete,
present-day instance of the "plausible-but-wrong rule" the task asked me to
construct (cf. "locals are never reassigned") — except it didn't need
constructing; it's already load-bearing in the document under review.

Blast-radius note: §3.1 #4 touts that one rule closes 4 sites "at once" as a
virtue of the design. It is equally the liability multiplier — a single
wrong rule produces false Proved at every site it's ever applied to, with
no per-site sanity check. The efficiency claim and the soundness risk are
the same mechanism.

Secondary, milder instance of the same shape: `never-reassigned-nonnil`
(instances 2/3) checks `def.assignment_count == 1 and
def.initial_value_kind == "table"` against the deref's variable name but
never checks that the dereference is control-flow-*after* the single
assignment (no dominance/ordering check). Less severe than the self-rule
(single-assignment-of-a-table is a much stronger real invariant), but the
same genre of gap: "premise says X, target says same name" is treated as
sufficient without verifying the temporal/structural relationship the rule
name implies.

## Attack 2 — fuel-bounded re-execution buys reproducibility, not soundness (SERIOUS)

§3.2 argues the kernel's contribution is real because it re-executes
`rule.check(premises, target)` itself rather than trusting the producer's
say-so. True, but re-execution only guarantees: *the same deterministic
function, given these exact payloads, returns this exact boolean, every
time it's asked.* That is non-repudiation of the boolean, not correctness
of the boolean. If `check`'s logic is wrong (Attack 1) or its premise
*payloads* are wrong (a buggy miner reporting `assignment_count == 1` for a
variable that is in fact reassigned in a branch the miner didn't walk),
re-execution reproduces the wrong verdict with perfect fidelity. The
kernel has no channel at all to verify a payload's correspondence to the
actual source file — `admit(pool, payload)` accepts anything, unconditionally,
opaque. This is a second, distinct trust surface from "is the rule honest"
(§4's named limitation): "is the *premise* honest," which the document
never separately names. Because `close` is a transitive fixpoint, one wrong
mined fact poisons every claim reachable from it in that run's graph,
silently — the receipt for a poisoned Proved looks identical to a genuine
one; there is no lower-confidence marker, no distinct verdict for "this
chain includes a payload nobody checked against ground truth."

Net effect versus the topic-key kernel it replaces: real, but narrower than
claimed. It closes exactly the case "producer asserts a boolean and expects
credit for the assertion" (a producer forging its own conclusion). It does
nothing at all against "producer's code is wrong" or "producer's harvested
fact is wrong," which are the actually-likely failure modes for a lazy or
buggy (not malicious) producer — the more probable real-world case named in
the pressure point.

## Attack 3 — provenance deletion removes a structural anti-gaming mechanism and is a bigger subtraction than the certified core licensed (SERIOUS)

The certified formulation (`declarative-design.md`) fixes, verbatim: "a pool
of graded assumptions (grade = credence, three generation sources, no source
special-cased)." §1.2 of the candidate reasons that since (b) "self-
corroboration via duplicate submission" is now handled by edge idempotence,
provenance's anti-gaming job is obsolete and can be deleted from the kernel
entirely.

That reasoning only covers the narrowest gaming vector (literally resubmit
the identical edge). It does not cover the vector the old design's
cross-provenance requirement actually blocked: a single dishonest producer
manufacturing a *chain* of distinct ids and distinct-looking rules that all
originate from itself. The design's sole remaining discipline is pure
acyclicity — "no id may be proved via a path that runs back through
itself." That forbids literal self-reference (id X depends on X), but does
nothing to forbid id A's proof resting entirely on ids B, C, D and rules
R1, R2, R3 that are all authored and admitted by the same single actor. Old
provenance, whatever its faults, was assigned by *which harvester code path*
called `admit` (a closed 3-member enum) — a producer couldn't self-declare
a different provenance value; the tag came from the kernel's own dispatch
of a fixed set of admission entrypoints. New design deletes that enum
outright: "source becomes an opaque reporting tag on the payload" (§1.3),
i.e., self-declared, by the same untrusted party that wrote the payload. A
self-declared tag is exactly as forgeable as the payload it's attached to,
so even the reporting-layer mitigation §4 gestures at ("a policy layer
reading the opaque payload's self-declared tag") inherits zero trust from
the kernel.

This is a bigger subtraction than the certified text licenses. "No source
special-cased" says the *treatment* must be uniform; it does not say the
*concept* of "which of the three fixed sources produced this" must be
erased from the trusted core. Deleting the enum makes "no source
special-cased" trivially/vacuously true (there's nothing left to
special-case), which is a different and weaker thing than what was
certified. The design should at minimum flag this as an open question for
the owner rather than asserting (§1.2, §4) that nothing is lost.

## Attack 4 — re-deriving the 5 corpus instances

1. `lru/init.lua:155 deref:self` — **breaks**: see Attack 1. Rule doesn't
   establish the claimed fact.
2. `json/init.lua:125 deref:HEX` — mostly survives (single-assignment-of-a-
   table is close to sufficient), weakened by the missing ordering check
   noted above; not fatal on its own but the walkthrough overclaims rigor
   ("real inference" language applied uniformly to a rule with a real gap).
3. `queue/init.lua:157 deref:FIFO` — identical shape to #2; same caveat.
4. `deque/init.lua:62-65 deref:self` ×4 — **breaks**, same rule as #1,
   applied 4×; amplifies rather than mitigates Attack 1.
5. `bigint/init.lua:115 branch:then reachable` — genuinely, honestly Open;
   no rule claimed to close it. This one survives review as advertised.
   Note though (feeds Attack 6) that its receipt ("no registered rule
   connects...") does not distinguish "nobody got around to writing the
   rule yet" from "no sound rule can exist without solving reachability in
   general" — the budget-vs-limit distinction the ceiling mandate cares
   about is not present in the receipt.

So of the 5 mandatory instances, 3 (1, 4, and partially 2/3) rest on a rule
that does not establish what it claims; only 1 of 5 (#5) is unambiguously
correctly handled as designed.

## Attack 5 — ceiling claim relabels FP's fair enumerator rather than instantiating it (SERIOUS)

§3.3 explicitly claims descent from FP's "anytime fair enumerator" (citing
`judgment.md`'s survey). FP's actual mechanism (per `judgment.md` §2, "FP")
is a *dovetailed, fair* enumeration over (claim × side × strategy) —
fairness is the load-bearing property: every establishable claim is
guaranteed to eventually get an attempt from *some* strategy in the
enumeration, because the enumeration is systematic, not because someone
happened to write a rule for it. The subtract candidate has no enumeration
and no fairness mechanism at all: "the kernel does not know or care how
many rules exist... it only ever promises that whatever finite certificate
set it is handed in one run, it checks correctly and terminates on."
That's a real property (termination per run) but it is not fairness — there
is no guarantee that a decidable-in-principle claim shape will ever be
attempted, systematically or otherwise; it depends entirely on whether a
human happens to write the matching rule. That's "extensible," which is
weaker than "fair," and citing FP's ceiling framing for it borrows FP's
credibility without its mechanism. This matters against the mandate because
`judgment.md` §5's "open in all five" list names "the budget-vs-limit gap"
as unsolved everywhere — this design doesn't even attempt it; its Open
receipts (Attack 4 #5) don't carry a hardness class or hint at whether the
claim is currently-unaffordable vs. structurally undecided, which several
ceiling-survey entrants (V, FP) treat as mandatory.

## Attack 6 — union-find does not detect cycles in a directed (hyper)graph (SERIOUS, technical)

§1.1 step 4/"Edge" bullet and the kernel sketch both describe the
acyclicity check as "graph-structural, O(edges) amortized with a union-find
/ DFS check," treating the two as interchangeable. They are not. Union-find
(disjoint-set) detects cycles in *undirected* graphs (its classic use is
Kruskal's MST / detecting when two nodes are already in the same
component). The property this design actually needs — "does admitting this
edge create a path from `target` back to one of its own `premises`" — is a
*directed* reachability question. Two directed edges A→B and B→A form a
cycle that union-find, applied naively, would not distinguish from two
independent undirected merges. Correct incremental directed-cycle/topological
maintenance is a harder, separately-studied problem (e.g., Pearce–Kelly
incremental topological order, or a bounded DFS-from-each-premise check per
submission) — not "union-find with a DFS fallback" hand-waved as
equivalent. This doesn't sink the design (a correct DFS-per-submit check is
buildable, and is what the sketch's comment actually describes doing — "checks
target is not reachable FROM target through the premises" — so the prose
description in §2.1 point 2 is right; it's the §1.1 "amortized... union-find"
claim that's wrong), but it means the design's own stated complexity
argument for repo-scale feasibility (pressure point 6) is not currently
correct as written, and should not be repeated as if it were a settled
O(edges)-amortized bound. At repo scale (2401 claims/8 files ⇒ extrapolate
to maybe 10⁴–10⁵ pool entries and a comparable edge count repo-wide), a
naive DFS-per-submission is O(E·(V+E)) worst case, which could be a real
performance wall in pure LuaJIT that the "polynomial, no risk of
non-termination" framing in §3.3 elides (termination ≠ acceptable wall-clock
cost at this project's stated bar, "bun general / tsgo typechecker").

## Attack 7 — opaque Payload forces systemic force-casts, conflicting with the project's own typing discipline (SERIOUS)

The kernel sketch declares `Payload = unknown` and `Rule.check` as
`(premises: {Payload}, target: Payload) -> boolean`. Every realized rule
(§2.2's `colon_self_nonnil.check`) then indexes concrete fields —
`def.form`, `def.receiver_param`, `target.expr`, `target.claim` — directly
off values typed `unknown`. Per this repo's own CLAUDE.md: "`unknown` = TS
`unknown` (caller must narrow)... Force casts past unnarrowable `unknown` or
`A | B` are wrong; fix the producer or the typechecker bug." As sketched,
*every* rule author must either (a) write a force cast (`--[[:! T]]`) at the
top of every `check`, which CLAUDE.md calls "almost never correct," or (b)
the design needs an as-yet-undesigned narrowing mechanism at the
premises/target boundary that doesn't exist in the sketch. This isn't
incidental — it's structural: the entire pitch is "payload is fully opaque
to the kernel," and the entire realization of any rule requires treating
that opacity as if it weren't there. The design doesn't flag this tension
anywhere (§4's list of hidden assumptions omits it), and it directly
implicates a repo hard rule, not just a style nit.

## Attack 8 — does the design survive its own stated limit honestly, or does the limit swallow the result?

To the design's credit, §4 states plainly that rule-honesty is
kernel-unverifiable in principle and that this "is not a gap specific to
this design." That framing is correct in the abstract — every candidate in
the ceiling survey has this same hole (V's certificate-extraction problem,
per `judgment.md`'s "Most serious flaw" on V). But the framing in §4 treats
the risk as a *future* concern to be handled by external parity-testing
discipline ("rules are named, versioned artifacts subject to parity
testing... not re-derived live by the kernel"). Attack 1 shows this
mitigation was not applied to the design's own worked example — no parity
test against real call-site behavior is cited or exists for
`colon-self-nonnil-v1`, and the rule is wrong. So the gap isn't a
well-understood residual risk sitting one layer up, waiting for future
engineering discipline to close it — it's already unclosed in the only
concrete rule the design shows anyone building. That's the difference
between "honestly named limit" and "limit that already broke the demo."

## What survives

- The core subtraction — deleting the fixed `topic_key` grouping and
  replacing "same topic" with producer-named ids in an edge — is real and
  correctly diagnosed as the fix for the 100%-Open failure in
  `first-slice-run.md`. Nothing in my attacks undoes that diagnosis.
- Collapsing hypothesis/obligation into one graph fact plus a pure
  acyclicity law is a genuine simplification with no special-casing found
  in the kernel itself (rule ids are inert strings, not branched on).
- `close` as a monotone least fixpoint over a finite edge set is
  correctly argued to terminate and is a real improvement (an actual
  fixpoint) over "whatever the last edge said."
- Re-execution under fuel is a real, if narrower-than-claimed, improvement
  over string-comparison (Attack 2 narrows the claim, doesn't erase it).

## Verdict

**SURVIVES-WOUNDED.**

The four-primitive kernel skeleton (pool / edge+re-execution / acyclicity /
closure) is architecturally sound and a genuine fix for the diagnosed
100%-Open failure — that part should survive into whatever design wins.
But the design's soundness *story* rests entirely on rule quality, which it
(a) concedes is kernel-unverifiable in principle, (b) demonstrates broken
in its own flagship worked example (`colon-self-nonnil-v1`, unsound because
it never inspects call sites — real, not hypothetical), and (c) defends
with weaker anti-gaming structure than the design it replaces, having
deleted the closed-source-enum/independent-sourcing requirement without a
structural replacement. Combined with a technical error in the acyclicity
complexity claim (union-find does not solve directed-cycle detection) and a
systemic conflict with the project's own `unknown`-narrowing discipline at
every rule boundary, this candidate needs real repair, not just
acknowledgment, before it can be called done.

**Single strongest idea worth grafting regardless of verdict**: collapsing
"same topic" from a kernel-fixed field-hash into producer-named ids inside
an edge (`(rule, premises: {id}, target: id, polarity)`), with the law
restated as pure graph acyclicity. That's the one move that actually
explains and fixes the 2174-shrug corpus failure; any surviving composite
design should keep it even if everything else here gets rebuilt.
