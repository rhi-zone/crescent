# Adversarial attack: claim-as-executable-checker (primitive.md)

Target: `docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/primitive.md`.
Method: re-derive every walkthrough by hand against the pasted Lua, not against the prose describing it.

## Attack 0 (the flagship demo does not run as claimed) — FATAL

§2.4 wires `pool = { axiom.claim(), mined.obligation(site) }` against witness
`w = { kind="binding", site=site, via="colon_call_self", value=nil }` (built
from `binding_info = { via = "colon_call_self", value = nil }`, deliberately
nil because "harvester has no concrete runtime value"). The prose claims:

> `findings` is empty: `axiom.check(w) = "accept"` ..., `mined
> obligation.check(w) = "unknown"` (no concrete value) -> no disagreement.

Re-derive against the actual `mined_deref_nonnil.lua` body (§2.3):

```lua
if witness.value ~= nil then return "accept" end
if witness.value == nil then return "reject" end
return "unknown"
```

There is no branch that returns `"unknown"` for "no concrete value." Lua
cannot distinguish "field absent" from "field explicitly nil" — `witness.value`
IS `nil` here, so the second branch fires: `mined.obligation(site).check(w) =
"reject"`. Meanwhile `axiom.check(w) = "accept"` (via matches). That is
`ra="accept", rb="reject"` — exactly `Kernel.find_disagreement`'s match
condition. Running the pasted code produces a **Refuted** finding, not an
empty `findings` table, and never reaches the Open state the corroboration
story in §2.4/§3.1 is built on top of.

This isn't a typo in a comment — it's a category error baked into
`mined_deref_nonnil.check`'s three-way branch: "I have no data" and "I have
data and it's nil" are collapsed onto the same Lua value, and the checker
resolves that collapse toward `"reject"`, the most alarming of the three
verdicts, silently. Instance #1 — the corpus's single named example of "this
design closes what label-keying couldn't" — is broken as submitted. §3.1's
"→ Proved, receipt = (axiom_colon_self, witness)" for instance #1 does not
survive re-derivation; the actual receipt the pasted code would emit is a
false alarm (self is genuinely guaranteed non-nil; the tool would report a
contradiction).

Why this matters beyond "fix the typo": the corroboration primitive
(`find_corroboration`, added in §2.4 specifically to close instance #1) is
never actually exercised by the design's own demonstration, because the
disagreement path fires first. The one instance offered as proof the second
primitive earns its keep is also the one instance where the pasted code
contradicts the walkthrough. Nothing else in the doc independently exercises
`find_corroboration` — its code isn't even shown (only described in prose) —
so the design's second trusted-kernel primitive is asserted, not demonstrated.

## Attack 1 (pressure point 1 — does Proved ever fire on a claim that matters?) — SERIOUS-to-FATAL

Set the Attack 0 bug aside and assume a fixed checker that does return
`"unknown"` for absent data. Ask what "Proved" would mean for instance #1 even
in that repaired world.

`mined.witness_source(site, binding_info)` (§2.3) is single-shot: `emitted`
flag, emits exactly one witness, then `nil` forever. `Kernel.exhaust` on this
source trivially "observes termination" after one call — the kernel's honest
claim ("I called this until nil, nothing disagreed") is *technically* true,
but the domain it exhausted has cardinality **one**, and that one witness was
constructed by the harvester, not sampled from real executions of
`Cache:peek`. The universal claim under discussion — "`self` is non-nil on
every invocation of this method, across every call site, forever" — is a
statement about an unbounded execution space. The design closes it by
shrinking the witness domain to a single synthetic fact ("this parameter is
the first arg of a colon-defined method") that already *encodes* the
generalization the checker is supposedly proving. The kernel didn't establish
the universal claim by exhausting the relevant space; the producer relabeled
the universal claim as a singleton fact and then let the kernel "exhaust" that
singleton.

This is worse than the judgment.md "expensive fuzzer plus receipt printer"
wall (FP's admitted failure mode), not better: FP's fuzzer-receipt-printer at
least samples multiple witnesses from something resembling the real space.
Here there's no fuzzing, no sampling, no multiplicity — one hand-built table,
called once. The kernel's minimal-trust story ("I never assert exhaustion I
didn't observe") is honestly implemented, but it purchases soundness by
letting the producer choose an degenerate domain, and nothing in the kernel
can tell a domain-of-1-that-begs-the-question apart from a domain-of-1 that's
genuinely exhaustive (e.g., a boolean flag with only one reachable value).
That distinction is exactly the "semantics-reality gap" every ceiling-survey
entrant named as its likely death (judgment.md §1.11) — reintroduced one
level down, now invisible to the kernel by construction, because `Witness =
unknown` means the kernel is structurally forbidden from ever inspecting
whether a witness domain is representative.

Answering the mandatory question directly: for claims that actually matter
(universal properties over unbounded execution/invocation spaces), this
design's Proved does not fire via genuine exhaustion of the relevant space —
it fires via producer-side domain contraction to a singleton that already
assumes the answer, dressed in the vocabulary of `exhaust`. That is
structurally the wall the prompt names, wearing a kernel hat, exactly as
suspected.

## Attack 2 (pressure point 2 — witness-shape convention = 2174-shrug reborn, made *less* diagnosable) — SERIOUS

The design admits (§4) that witness-shape agreement is convention, not
kernel-enforced, and frames this as "demoted from a kernel concern to an
open-layer concern... the right place for it, but it does not disappear."
Re-derive what actually changed versus the original failure.

Before: claims carried `claim.key` (site/slot/stratum), a first-class,
kernel-adjacent field. The first-slice-run report found the 2174-shrug by
literally diffing site/slot vocabularies across harvesters (`harvest_axiom`'s
`site="*"` vs `harvest_mined`'s `"<file>:<line>"` format) — the mismatch was
*visible* and auditable as data, even though the kernel didn't fix it.

After: witness shape agreement lives entirely inside the bodies of `check`
closures (`if witness.kind ~= "binding"`, `if witness.via == "..."`, ad hoc
field names chosen independently per producer file). There is no `claim.key`
or any equivalent structured object left anywhere in the kernel-visible
layer to diff. To discover that two producers use incompatible witness
shapes now requires reading and comparing Lua closure bodies by hand, or
writing a bespoke static analysis over the producers themselves — the very
capability this whole project exists to build, applied recursively to its
own substrate, with no evidence that's planned. So the shrug isn't just
"demoted," it's demoted into a strictly less observable place: the failure
mode is identical (silent non-contact, no error, degrades to permanent Open —
the design is at least right that it never falsely fires), but the tooling
surface that made the original failure discoverable at all (a grep-able key
field) is gone. Calling this a lateral move undersells the regression in
diagnosability.

## Attack 3 (pressure point 3 — corroboration soundness) — SERIOUS, compounds Attack 0

Independent of Attack 0's concrete bug: is "accept + unknown, nothing
rejects, from an independently admitted claim" actually safe to call closed
for that witness? The design's own §4 says it believes this is sound
*per-witness* but explicitly has not made the full argument, and flags
"Proved-for-a-claim" (needs `exhaust`) as distinct from "Proved-for-a-witness"
(what corroboration actually gives you). Re-derive whether §3.1 respects that
distinction: it does not. §3.1 instance #1's payoff line reads flatly "→
**Proved**, receipt = `(axiom_colon_self, witness)`" — no "-for-a-witness"
qualifier, no gesture at needing the `exhaust` path too. The one place the
design demonstrates its own headline claim overclaims relative to the
caveat the design places two sections later. A reader taking §3.1 at face
value (as the doc invites, presenting it as the corpus payoff) walks away
believing corroboration alone delivers Proved-for-a-claim; §4 says it
doesn't. This is an internal contradiction, not a subtle inference.

On the "can two wrong checkers corroborate on a witness that reflects
neither's meaning" question directly: yes, straightforwardly. Corroboration's
only safety conditions are (a) the corroborating claim is "independently
admitted" and (b) nothing else in the current pool rejects. Neither
condition constrains whether the corroborating claim's `accept` and the
obligation's `unknown` are *about the same fact* in any sense beyond both
functions returning non-error values when handed the same table. Two
producers that each misread a shared but wrongly-populated witness field
(exactly Attack 0's shape, generalized) will corroborate every time, and
"independently admitted" provides zero defense against correlated bugs from
harvesters that share the same static-analysis blind spot (e.g., two
producers that both assume a naming convention that doesn't hold for
metatable-based indirection) — correlated-error corroboration is a known
failure mode for exactly this kind of "N sources agree" heuristic and the
design does not discuss it at all, despite naming it as the design's second
most load-bearing primitive.

## Attack 4 (pressure point 4 — O(n²) + untrusted pruning: completeness hole, and no Open artifact at all) — SERIOUS

Soundness-vs-completeness: pruning that wrongly discards a pair can only
cause a true Refuted or true corroboration to never be searched for — it
cannot manufacture a false Proved/Refuted (the kernel never trusts the
pruning layer's say-so, only its own `check` calls). So this is a
**completeness hole**, not a soundness hole, and the design's ceiling framing
survives that half of the question.

But re-derive what "the pair was never tried" looks like downstream. The
pasted `Kernel.check_pool` only ever appends entries to `findings` on
disagreement (`if w ~= nil then findings[...] = {verdict="Refuted", ...}`).
There is no code path in the shown kernel that emits an Open entry, a
receipt, or any record for a pair that was checked-and-consistent, let alone
for a pair that pruning skipped entirely. "Open" is purely the *absence* of
an entry — which means a genuinely-checked-and-consistent pair and a
never-attempted (pruned, or budget-exhausted) pair are byte-for-byte
indistinguishable in the design's own output. That directly contradicts
judgment.md's convergent criterion #3 ("surrender as a first-class,
machine-readable artifact carrying the residual obligation and reason
class" — 4/5 entrants, including this design's own ancestor E) and
contradicts the first-slice-run report's claim that Open verdicts "correctly
report... with a receipt naming the missing piece" — no such receipt
machinery exists in the kernel code this document actually shows. Either
that receipt-generation lives in an unshown reporting layer (undocumented
here, so unverifiable), or the corpus report's Open receipts were hand-narrated
by the person writing up the run rather than emitted by the kernel. Either
way, at repo scale (2401 raw claims → the design's own ~5.7M-ordered-pair
figure) an untrusted pruning layer with no distinguishing artifact means
"silently never checked" and "checked, found nothing" become
operationally the same bucket, for a user trying to decide whether to trust
a green Open.

## Attack 5 (pressure point 5 — ceiling claim honesty vs. where the power actually lives) — SERIOUS, compounds 0–3

"The kernel trusts nothing beyond I-called-this-and-got-this-back" is an
accurate description of the pasted code — there's no hidden trust in
`Kernel.find_disagreement`/`Kernel.exhaust`. But per Attacks 0–3, essentially
all of the design's actual claimed power (closing instance #1, the
corroboration primitive, "Proved" firing at all on anything universal) lives
in unverified producer convention: witness shape agreement, domain-choice
faithfulness, and the nil/unknown conflation that broke the flagship demo.
None of that is checked by anything — not the kernel (by design), and not
even crescent's own typechecker, because `Witness = unknown` makes the one
data structure every producer's soundness depends on structurally opaque to
static analysis. `bin/cr check` run over `producers/mined_deref_nonnil.lua`
cannot catch the Attack-0 bug, because nothing in that file's signature
promises anything about what `witness.value` being nil *means* — `unknown`
by definition tells the typechecker nothing. For a project whose entire
purpose is building a typechecker, shipping the typechecker's own kernel
substrate in a form its own tool is blind to is a notable irony worth
surfacing plainly, not just a stylistic nitpick: it means the exact bug class
that sank this design's flagship demo is one `bin/cr check` will never flag
in any future producer, either.

## Attack 6 (pressure point 6 — repo hard rules) — COSMETIC / mixed

- **Name-keying check:** `axiom_colon_self.check`'s `via ==
  "colon_call_self"` and `mined.obligation`'s `site` parameter are both
  applied generically by a harvester loop across many concrete sites (§3.1
  instance #4 demonstrates reuse across 4 sites with zero new code, and #2/#3
  reuse the *same* producer across two files). No hardcoded per-file/per-line
  branch was found in the shown examples — credit due, this part is clean.
- **Pure Lua/LuaJIT implementability:** plausible; coroutine-based cooperative
  budgets are a real, working pattern in LuaJIT. No zero-dependency or vendoring
  violation found.
- **Cost at repo scale:** the design's own arithmetic (2401 claims, ~5.7M
  ordered pairs) times a per-pair budget (100 witnesses in the example) is
  worst-case ~10^8-10^9 `check` invocations for one full-pool pass, with **no
  incremental/differential re-check story** anywhere in the document (contrast
  with judgment.md's ENG entry, content-addressed claims + dependency
  invalidation, which this design's lineage does not adopt). Given
  CLAUDE.md's stated tooling bar ("bun (general), tsgo for the typechecker" —
  implying an interactive-latency target), a design whose only performance
  answer is "an untrusted pruning heuristic, not yet built" is a real,
  currently-unaddressed scale gap, though honestly flagged as future work
  rather than hidden.

## Verdict

**KILLED.**

The two things this design was built to prove it can do — close instance #1
(the corpus's flagship "obviously decidable" case, the sole worked example in
the entire document) and justify the corroboration primitive added
specifically to close it — do not survive re-derivation. Running the pasted
code on the pasted example produces a false Refuted, not the claimed empty
`findings` → Proved. That is not a peripheral thin spot the doc already
disclosed (like instance #5's honest Open); it is the one place the design
claims a concrete win, and the win is fabricated by a nil/absent conflation
bug in the very checker the corroboration story depends on. Layered on top:
Proved's honest exhaustion story only ever closes producer-fabricated
singleton domains for the claims that matter (Attack 1), witness-shape
convention reproduces the founding failure with strictly less diagnostic
surface than before (Attack 2), corroboration has no defense against
correlated-error agreement between independently wrong checkers (Attack 3),
and the kernel emits no first-class artifact distinguishing "checked,
consistent" from "never attempted" (Attack 4) — each individually a SERIOUS
completeness or trust-surface hole, together enough that "survives wounded"
would be too generous: the flagship demonstration is not wounded, it is wrong
as submitted.

**Strongest idea worth grafting regardless:** the noun itself — collapse
"claim" into an executable three-valued checker over an opaque witness, so
there is no separate denotation to keep in sync with a decision procedure,
and require `"unknown"` (never a guess, never an error) whenever a checker
doesn't recognize what it's holding. That non-negotiable-`"unknown"` default
is the one piece of this design that, if kept and combined with a *typed*
witness-shape registry (so shape mismatches become a static diagnosable fact
again, restoring what Attack 2 says was lost) and an explicit distinction
between Proved-for-a-witness and Proved-for-a-claim enforced in the kernel
API rather than left to prose discipline, would be worth carrying into
whatever design replaces this one.
