# Decision tape: determinacy, not reuse, is the discriminator

**Status: exploratory, corrected.** This document replaces
`docs/design/codebase-as-grammar.md` (same directory, prior name), which
recorded a model that this session retracted. The retraction is not
cosmetic — the prior document's central claim ("a rule and a one-off
decision are the same kind of object, differing only in reuse count") is
wrong, and anyone citing it as the reason `tooling/grammar_gen/` works the
way it does would be citing the wrong reason. Read
`docs/design/dispatch-determinacy-survey.md` alongside this document: it is
the empirical ground truth the corrected model below is answerable to, and
it independently arrived at the same correction (see its own "Methodology
note on this document's own history").

Everything **measured** in the prior document (byte-for-byte reproduction
of 5 files, the whole-`lib/` induction run's raw counts, the parser
coverage numbers) is still true and still reported below — only the
*interpretation* of those numbers changes. Nothing here fixes
`tooling/grammar_gen/` code; that is out of scope for this pass and tracked
in `TODO.md` instead (see "Open items" at the end).

## The corrected model

A generator, in this framing, is a **deterministic function from context to
output**. A programmer following a convention is not sampling from a
distribution over possible next tokens — they are applying a rule that
*determines* the output, given what's already known at that point in the
code. This gives exactly two cases, and — this is the load-bearing claim —
they are not two ends of one spectrum:

- **Forced.** The context (the language spec, an established rule, an
  enumeration the code already commits to) determines the output
  completely. A forced choice costs nothing to encode, no matter how many
  or how few times it occurs in the corpus. It is not a "cheap decision" —
  it is *not a decision at all*.
- **Free.** The context does not determine the output. This, and only
  this, must be recorded. The number of free decisions in a codebase is
  the thing worth measuring; everything else is expansion of rules already
  known.

The artifact this work produces is a **decision tape**: a deterministic
expander (the rules) plus exactly the free choices the rules could not
settle, for one file or one corpus. **Compression ratio is the length of
that tape against the length of the code it expands to** — not a count of
"how many productions got reused."

## Two framings this document tried and retracted

Both are recorded here, not deleted, so nobody re-derives them and re-hits
the same wall.

### Dead end 1: reuse-count / flat-grammar (RePair/SEQUITUR-style)

The retracted prior document modeled the codebase as one flat SEQUITUR-style
grammar: every repeated span is a production, "decision cost" is
`log2(k)` over `k` established alternatives at a slot, and a production used
once versus a hundred times differ only in a statistic read off the corpus
after the fact — there is no design-time distinction between "convention"
and "one-off decision."

**Why it's wrong:** frequency is orthogonal to whether context determines
the output. A construct that appears exactly once can still be fully
forced (the JSON escape-dispatch `\u` surrogate-pair handling, Part 1.2 of
the survey, occurs once per file but is forced by the JSON spec, not by
precedent elsewhere in the corpus). Conversely a construct that repeats
constantly can still be free at every occurrence (the survey's
`RETURN(ID)` finding, below, is exactly this in miniature — high reuse,
not a bounded design choice). Reuse count is a fact about the corpus
sample; determinacy is a fact about whether *this* occurrence had another
possible value. Treating the former as a proxy for the latter is the root
error the whole prior document inherited.

### Dead end 2: probabilistic / entropy framing

A second candidate framing, tried and explicitly rejected mid-course
(mirroring the same correction the survey document records for itself):
cost a symbol as `-log P(symbol | context)`, PPM/context-mixing style, and
let "how surprising is this token" stand in for "was this a decision."

**Why it's wrong:** conventions are deterministic rules, not distributions.
A programmer applying `if err ~= nil then return nil, err end` at the top
of a function is not sampling from a learned distribution weighted toward
that shape — they are applying a rule with a definite output. Importing
probabilistic machinery models something the problem does not contain:
there is no genuine uncertainty at a forced site to assign a probability
mass function over, and forcing free sites into a probability model
obscures the actual discriminator (is there a rule, yes or no) behind an
entropy number that looks quantitative but isn't measuring the right
thing.

### A related dead end, isolated to the induction tool rather than the model

`tooling/grammar_gen/discover.lua`'s windowed clone detection (single
statements, then 2–5-statement sliding windows) has a "granularity" knob —
how many contiguous statements define one candidate span. This knob is an
artifact of the specific clone-detection technique used to *find*
candidate spans, not a parameter the corrected model has. Genuine rule
extraction asks "does a rule determine this output," which has no notion
of span length; a forced or free decision can be one token or fifty. The
windowing is scaffolding for search, not part of what's being measured —
worth being explicit about so a future reader doesn't treat "try more
window sizes" as progress toward a better decision tape.

## The `RETURN(ID)` finding, reread under the corrected model

The whole-`lib/` induction run (2026-07-28, unchanged from the prior
document's numbers) found `RETURN(ID)` — a bare `return <local>` statement
— clustered into 6417 occurrences and 925 "alternatives," nearly one
alternative per distinct identifier ever returned this way across the
corpus. The prior document flagged this honestly as a tuning problem: the
tool has no way to tell a slot with a bounded, deliberate alternative set
from a slot whose alternative count is "however many distinct identifiers
happen to exist."

Under the corrected model this is not a tuning problem to be solved by a
better threshold. **At each of those 6417 sites, the returned identifier is
forced** — it is whichever local the function has already computed as its
answer, determined by everything the function did above that line, not
chosen freely at the return statement itself. The apparent 925-way
"freedom" is an artifact of a context-free fingerprint: the tool's
single-statement window sees only `return <ID>` and abstracts the
identifier to a placeholder, discarding exactly the surrounding context
(what this function computed, what its contract promises) that made the
choice of *which* local to return a foregone conclusion. There was no
choice at any of these sites. A better alternative-count threshold cannot
fix this, because the defect is upstream of counting: the encoder erased
the context before it could see that the arm was forced. (See "Erasing
decisions," below — this is the same failure mode as the `format_date`
case, in the opposite direction of severity: here erasing context inflates
the apparent free-decision count; there, erasing content deflates it to
zero.)

## The two symmetric correctness requirements

The decision tape must contain **exactly** the free decisions the code
contains — no more, no fewer. Both directions are correctness bugs in the
encoder, and neither's severity depends on how often the triggering shape
occurs.

### Fabricating decisions

If a dispatch site is genuinely a **fold** — one rule that determines every
arm from a closed enumeration — and the encoder records it as N separate
free choices instead of one rule application, the N−1 excess entries are
**spurious**: information the measure invented that the code never
contained. This is a correctness bug in the encoder. Prevalence does not
mitigate it; "how common are folds" is the wrong question to ask when
judging whether this failure mode matters. **The encoder must be able to
express a fold as a fold.**

Concrete ground truth from the survey, all independently re-verified in
that session:

- JSON `decode_raw` (`lib/format/json/pure.lua:471-633`): 7 value
  productions plus the terminal error, all forced by RFC 8259 — 8 forced
  arms, 0 free.
- JSON string-escape dispatch (`lib/format/json/pure.lua:333-368`): 9
  permitted escapes, forced under **two** stated rules (a flat
  single-character rule for 8 of them, a `\u`-surrogate-pair rule for the
  9th) — a fold does not require one uniform rule, only that *some* stated
  rule determine every arm.
- `lib/asm/cpu.lua:173-214` arch×OS feature detection: all 9 leaf cells of
  a 3×3 enumeration are forced by one `pcall`/reset/baseline-flag rule,
  exhaustive by construction.
- `lib/locale/init.lua:341-401` `PLURAL_RULES`: the strongest form of
  forced in the survey — 9 of 14 language-code arms are literally the same
  function *object* as another arm, not merely similarly-shaped code.
  Shared reference is a stronger forced guarantee than shared shape: there
  is no drift risk between two names that point at the same function,
  where there is real drift risk between two independently-written copies
  of the same logic (see "forced but duplicated," below).

And a real counterexample against naive optimism: `lib/type/static/
solve.lua:4225-4241`'s 16-arm constraint-kind dispatch has exactly 2 arms
forced by a rule stated in the code's own comments (`solve_or`/`solve_and`)
and 14 fully independent algorithms. An encoder must not force this table
into fold shape just because it is a dispatch table over an enumeration —
14 of 16 arms are real, irreducible free decisions, and reporting them as
forced would be the fabrication failure in reverse polarity (forcing what
is actually free) — see the next section.

### Erasing decisions

The inverse failure: an encoder that keys forced-vs-free on *code shape*
will treat shape-uniform arms as forced when their *content* is free.
Visible code-shape uniformity does not imply forced content — this is the
sharper of the two failure modes to catch, because it looks like a clean
result right up until someone checks what the arms actually say.

Ground truth from the survey:

- `lib/locale/init.lua:668-727` `format_date` (12 leaf arms, style × 5
  languages): every arm follows the identical control-flow rule ("call
  `string.format`"), but each arm's literal template string encodes that
  locale's word order — real, non-derivable information every single arm
  carries. An encoder scoring this site by "does every arm follow the
  control-flow rule" calls it forced and is wrong; what must actually be
  recorded is the 12 template strings themselves.
- `lib/log_parser/init.lua:502-535` `M.pattern`'s regex-literal dispatch
  over its declared 5-type enumeration: fold-shaped in control flow (one
  regex construction per type, touching all 5 types), but each regex is
  itself free content, the same pattern as `format_date`.

These two shapes — genuine folds that must not be split into N free
choices, and shape-uniform-but-content-free arms that must not be
collapsed into one rule — bound the encoder's design from both sides. An
encoder tuned only against the fold examples above will erase the
`format_date` case; an encoder tuned only against `format_date` will
fabricate N decisions out of the JSON/CBOR/asm folds. Both are real,
independently confirmed sites in the same codebase.

### A named third bucket: forced but duplicated ("drift")

The survey found a pattern that is neither of the above and must not be
folded into either: `lib/type/static/narrow.lua`'s `negation` arm
(`info_name_id`, lines 539-554) and its `type_check`/`guard_check` pair
(`apply_narrowing`, lines 472-520) each produce output that is **fully
determined by an existing rule elsewhere in the same file**, but the source
re-implements the rule by hand instead of calling or sharing it. Recording
these as free decisions would fabricate content that isn't there
(violating the "no fabrication" requirement above); recording them as
forced-and-clean would miss a real, if minor, inconsistency in the source.
They need their own bucket: forced content, expressed with latent drift
risk between the copies.

This is worth stating carefully, without overclaiming from two instances:
a correct encoder that collapses `negation` and the `type_check`/
`guard_check` pair to "the same forced rule, applied twice" is not just
compressing — it is *detecting* that the two call sites should be one
function and currently aren't. That is a genuine argument the model has
diagnostic value beyond compression. It rests on exactly two confirmed
instances in one file; it is not yet evidence about how often this pattern
recurs across the corpus.

## What was actually built, and what it found (facts, reinterpreted)

The prototype at `tooling/grammar_gen/` (`canon.lua`, `derivations.lua`,
`discover.lua`, `generate.lua`, `induce.lua`, `luaparse.lua`) is unchanged
by this document — no code in this pass. The facts below are the same
measured facts the prior document reported; only the reading changes
where the corrected model requires it.

**Hand-induced, 5-file dispatcher family** (`compress`, `crypto`,
`format/json`, `encode/base64`, `regex` — the 5 of the originally-named 12
that actually share the tiered-dispatcher shape; `lz4`/`x509`/`csv_query`/
`word_wrap`/`text_justify` are single-tier, `keyring`/`stb` tier-select but
don't fit this shape, see the prior document's now-superseded "corpus"
section for the file-by-file reasoning, which is a factual inventory, not
part of what was retracted): `path_bootstrap`, `tier_select` (two
established alternatives, `cast_narrow` and `incremental_override`, each
with its own sub-slots), `type_alias_block` (5/5 files, zero variance —
under the corrected model this is a **rule**, not "the closest thing to a
pure convention" phrased as a matter of degree; every file's use of it is
forced once the field list is fixed), `narrow_comment`, and the
`m_table_cast_narrow`/`m_table_incremental` pair. All 5 real files
reproduce **byte-for-byte** from hand-written derivations
(`bin/luajit tooling/grammar_gen/generate.lua --all --diff` — still
passes, unchanged). Crypto's `random_bytes` remains the one confirmed
genuine free decision in this family at the "field cast" slot: the two
tiers take incompatible argument lists, no existing alternative fits, and
none should be minted.

**Automated induction** (`luaparse.lua` — an independent Lua 5.1/LuaJIT
parser, chosen over reusing `lib/type/static/parse.lua`'s FFI-arena
representation because that representation is built for typechecker
throughput and is the wrong shape for shape comparison; `canon.lua`;
`discover.lua`/`induce.lua`): rediscovers the `tier_select` slot (the
ground-truth ternary/if-else unification, see the correctness-bug section
below) and the `path_bootstrap` slot without hand-keying to either. Whole-
`lib/` run (1698 files, ~7.6s, unchanged numbers):

```
-- single-statement: 2134 rules, 6205 slots, 13081 residue
-- 2-statement windows: 3662 rules, 9513 slots, 35224 residue
-- 3-statement windows: 3611 rules, 6937 slots, 45530 residue
-- 4-statement windows: 2720 rules, 4601 slots, 45761 residue
-- 5-statement windows: 1908 rules, 3260 slots, 42692 residue
```

Read under the corrected model, not the reuse-count one: `discover.lua`'s
"rule" (zero-variance cluster, size ≥2) is a reasonable proxy for
*forced*, and its "slot" (nonzero-variance cluster, size ≥2) is a
reasonable proxy for *contains free content* — but "residue" (cluster size
1) is not a proxy for anything in the corrected model. A forced site that
happens to occur only once in the corpus (the JSON `\u`-surrogate-pair
handling is exactly this shape) is indistinguishable, by this tool, from a
genuinely free one-off decision; both land in "residue." This is a real
gap between what the tool currently measures and what the model needs it
to measure — filed in `TODO.md`.

Not rediscovered by the automated pass at all: `type_alias_block` and
`narrow_comment` live entirely inside `--:`/`--::` comment syntax, which
`luaparse.lua`'s lexer discards like any other comment. This remains a
real, structurally significant blind spot (already tracked in `TODO.md`,
carried forward unchanged by this document).

## The live correctness bug: `canon.lua`'s ternary/if-else unification is unsound

`tooling/grammar_gen/canon.lua` rewrites `local x = C and A or B` (ternary)
and `if C then x = A else x = B end` (if/else, single same-target
assignment per branch) into one shared `cond_assign` node. This is the
rewrite that makes the ground-truth result work: compress's and crypto's
`if/else` ok-check and regex's ternary land in the same slot
(`COND_ASSIGN(NAME;CALL(1))`), which is the headline evidence this document
and the prior one both cite for "the representation is abstract enough to
catch this class of equivalence."

**The two forms are not semantically equivalent, and the unification is
unsound, not merely lossy.** `C and A or B` falls through to `B` whenever
`A` evaluates to `false` or `nil`, regardless of `C`. `if C then x = A else
x = B end` does not have this failure mode — it assigns `A` exactly when
`C` is truthy, full stop. Whenever `A`'s possible value set includes
`false` or `nil`, the two forms diverge on real inputs. This is a
soundness bug in the unification, not a precision tradeoff: it is not that
information is lost in the merge (that would be an acceptable, named
lossy-clustering cost), it is that the merge asserts two forms are the
same production when they are provably not, for a real subset of possible
values.

This must be scoped precisely, not treated as disqualifying the tool
outright: it is **acceptable as a clustering heuristic** — finding
structural kinship between two idioms that a human reader would recognize
as "doing the same job here" is a legitimate, useful thing for a discovery
pass to do, and every confirmed ground-truth instance in this corpus (the
5-file dispatcher family, the 22-occurrence whole-`lib/` generalization)
happens to fall on the sound side, because none of those `A` values are
`false` or `nil`-valued in a way that changes behavior. It must **never be
treated as a semantic equivalence**, and specifically: any fidelity check
built on top of this canonicalization (i.e. any claim that a derivation
using `cond_assign` round-trips to *equivalent* code, not just
*byte-identical* code for the corpus sampled so far) would be vacuous
exactly where the bug lives — it would pass on the sample that happens not
to trigger it and give no signal about the inputs that would. Filed as a
real bug in committed code in `TODO.md`; not fixed in this pass.

## What's proven vs. aspirational

**Proven, by direct measurement, unaffected by this document's correction:**

- All 5 hand-induced dispatcher files reproduce byte-for-byte from their
  derivations (`generate.lua --all --diff`).
- The automated induction pass, run independently of the hand-induction,
  rediscovers the same ground-truth `tier_select` slot and the
  `path_bootstrap` slot, via a documented, generic canonicalization rule.
- The whole-`lib/` induction run completes in ~7.6s over 1698 files with no
  scope-narrowing.
- Real fold sites with zero free arms exist in this codebase (JSON decode
  dispatch, JSON escape dispatch, `asm/cpu.lua`, `locale.lua`'s
  `PLURAL_RULES` aliasing) — independently re-verified against source, not
  asserted.
- Real non-fold sites with genuinely independent arms exist in the same
  codebase (`solve.lua`'s 16-arm dispatch, 14 of them irreducible), so the
  fold shape is not a universal solvent — most dispatch in this corpus is
  not a fold, and that is the correct, expected reading, not a shortfall.
- The `canon.lua` ternary/if-else unification is unsound for `false`/`nil`-
  valued branches — confirmed by direct reasoning about the semantics of
  Lua's `and`/`or` short-circuit evaluation, not merely suspected.

**Not proven — genuinely open, tracked in `TODO.md`:**

- Whether an encoder that correctly expresses both fold sites and
  content-free-but-shape-uniform sites (the two symmetric requirements
  above) can be built as one mechanism, or needs a per-site classification
  step decided some other way.
- The `discover.lua` "residue" bucket's conflation of "occurs once and is
  free" with "occurs once and is forced" (the JSON-`\u` shape) — a real gap
  between the tool and the model.
- Fidelity-verification (canonical-form equality) as a distinct
  requirement from clustering canonicalization: the owner's stated
  correctness bar is canonical-form equality, and the `cond_assign`
  canonicalization this tool currently has is deliberately lossy for
  clustering purposes — it cannot also serve as the fidelity check, and no
  fidelity-specific canonicalization exists yet. This is unresolved, not
  merely unbuilt: it isn't yet decided what a fidelity canonicalization
  should preserve that the clustering one is free to drop.
- Compression ratio at scale, beyond the 5-file family: the hand-built
  prototype measured derivation source (15770 bytes) larger than the code
  it generates (13418 bytes) at n=5, for reasons believed fixable
  (repeated field lists, doc-header prose stored as an uncompressed raw
  terminal) but not yet fixed or re-measured. Reported as **open**, not as
  a negative verdict on the model — the n=5 sample is not powered to
  answer a scale question either way.
- The `keyring`/`stb` looser-family question (do they need their own
  induced grammar, an extension of this one, or neither) — untouched,
  carried forward from the prior document unchanged.

## Where this fits in crescent's docs

Filed under `docs/design/`, not `docs/decisions/`, for the same reason the
prior document gave: nothing here is a ratified verdict between named,
weighed alternatives, it is a corrected sketch. If a future session
evaluates "should crescent adopt derivation-based authoring for family F"
as a real yes/no choice, that belongs in `docs/decisions/`, separate from
this document.

## Open items

See `TODO.md`'s "Decision-tape model correction" section for the concrete,
trackable items this document's correction produced (the `canon.lua`
unsoundness, the fidelity-vs-clustering canonicalization gap, the residue-
bucket conflation, and the carried-forward open items from the prior
document's TODO entries).
