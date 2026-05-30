# Foundations — Pedagogy and the Reader

A from-first-principles account of what a type system is *for* in crescent, why
there is no single typechecker, and what the ecosystem is actually building. This
is the design substrate beneath the per-question checkers (the first of which is
`lib/check_kind/`, documented in `docs/checkers/value-kind.md`). It supersedes
the earlier axes-first re-derivation (see "Supersession" below).

Not a spec. A reader's artifact: the narrative that the decisions came from, so a
future reader can recover *why*.

## 1. What code and a type system are

Code is a static artifact that denotes a whole *space of runs*. A single source
file stands for every execution it can produce. It is saturated with implicit
assumptions about the shape of data and the way data flows — in Lua, mostly
table-shapes flowing through functions.

A type system reasons over all of those runs at once, without running any of
them. It assigns every expression a description of its value-set and checks that
every consumer can handle everything its producer can produce. A **type is a
claim about the value-set of an expression.**

It is sound and conservative: it trades precision for exhaustive, instant
coverage — it will reject some programs that would have run fine, in exchange for
covering *all* runs at once. The currency that precision actually buys is
**legibility**: a more precise type makes the program more legible to a reader,
not merely more permissive to the checker.

## 2. What a value is, and its encoding

The Lua/LuaJIT runtime has nine kinds, all runtime-tagged. One of them — the
table — is structured; the rest are not. `nil` is absence. Mutable identity is
the hard part.

The key result: the value universe does **not** encode as nine flat base types.
It encodes as:

- **Six opaque atoms** — `boolean`, `number`, `string`, `thread`, `userdata`,
  `cdata`. No internal structure the checker reasons about.
- **A nilable flag.** `nil` is absence, modeled as nullability carried on every
  type, not as a member of a union of base types.
- **Arrows.** Functions *and* operators carry `(args) -> (returns)`. The arrow is
  the propagation engine: **type propagation IS function application.** Without
  typed functions, nothing propagates. Functions are categorically apart from
  both atoms and data-shapes — they are not a kind of value to be inspected, they
  are the *rule* by which types move.
- **Tables** — structured data. Deferred in the first checker.
- **Top / bottom** — `unknown` and `never`.

So the encoding is six atoms + nilable + arrows + tables + top/bottom, not nine
peers.

## 3. Plurality — not one typechecker

> "We shouldn't have one typechecker — every time we answer a question, we make a
> new typechecker."

Each checker is small, narrow, single-purpose: it answers exactly one
property-question with the smallest machine that suffices.

The earlier monolithic approach (the "19-axis" design) failed because every
feature decomposed onto one shared solver. Everything entangled everything;
errors became unteachable. Plurality removes the shared substrate, so the
coupling has nowhere to live. Checkers compose by being run together, not by
sharing machinery.

## 4. Pedagogy is the point

Pedagogy here means teaching *people the point of a decision*. The deliverable of
the whole system is teaching, not the accept/reject verdict. Legibility is what
precision is *for*.

Core principle: **reasoning must be trivially recoverable from the code** —
mechanism-agnostic, comprehensively covered. Decisions are pervasive (every
decision, in every function), and their points normally evaporate the moment the
author moves on. The system's job is to keep them recoverable.

## 5. Counting decisions — surprisal

Decisions are mechanically countable as Shannon surprisal against a *reader*:

- ≈0 bits — no real decision. Forced or predicted by the reader.
- high bits — a genuine decision the reader could not have predicted.

This supplies the missing "denominator" for coverage: you can only claim to have
covered the decisions if you can count them. Low surprisal everywhere is not
free — it is **bought** by encoded taste. Nothing about it is free.

## 6. The reader

You **build** the reader. The reader **is** the encoded design decisions — taste,
convention, the *ubiquitous* decisions. Those ubiquitous decisions are the
highest-density part of a codebase, not the rare spikes; the reader's value lives
there.

The reader must be explicit, in-repo **data**, **not a model**. A model is the
wrong substrate because it is:

- **opaque** — a reader you can't read isn't one;
- **un-addressable** — you can't edit one decision in a pile of weights;
- **only approximate / unfaithful** to the actual decisions;
- **provenance-destroying** — it loses where a decision came from;
- **undistributable** — a multi-terabyte opaque binary can't ride in a git
  clone;
- **model-locked / non-transferable** — impossible with a closed model.

Models *read* the reader; they are not it. And a model's own implicit taste
actively **poisons** the codebase: on every touch it drags the code toward the
generic mean. The reader is the antidote — explicit encoded taste, fed to
whatever model touches the code.

## 7. The ultimate goal

Drive the human-supplied (irreducible) information of the codebase toward its
minimum. Encode taste once; amortize it across every occurrence and every model,
forever. Humans and agents supply only the genuinely novel decisions; the reader
supplies the rest.

This reframes the ecosystem's value proposition: the product is the **built
reader** — conventions, corpus, types, control surface — "a place where *why*
survives." Not the batteries.

## 8. Consequences for a typechecker

A checker does three things:

1. **Assign** a type to every expression.
2. **Propagate** types through every site a value moves: function/operator
   application, indexing, binding/assignment, return, control-flow joins. Not
   everything is an operator application — statement and expression forms are
   handled directly.
3. **Check & reject** at every use via subtyping.

The floor for every checker: **sound, terminating, legible.**

Complexity control is one rule: **"demand the decision, don't infer cleverly."**
Only cheap, local, decidable propagation. Anything hard becomes an annotation
obligation — and that obligation also feeds the reader. This is the same lever as
pedagogy: where the checker would have to be clever, it instead asks the author
to record the decision.

## 9. Annotation syntax does not have to rot

Crescent's own annotation surface is the proof. A fixed marker set — `--:`,
`--::`, `--[[: T]]` — and a closed compositional type algebra:
`|` `&` `~` `->` `[]` `{}` `()` `<>` `...` `%`.

Expressiveness grows through user-definable `match` type-operations, **not**
through new sigils. The governing rule: **no new `$`-intrinsics; extend `match`
instead.** Fixed surface, unbounded power by composition.

## 10. The coverage mechanism

How to ensure reasoning is recoverable *and* provably covered. Two parts.

**(a) Findability.** Every decision site in source carries a marker linking to
the doc that explains it. A deterministic lint proves the links resolve
bidirectionally (source ↔ doc).

**(b) Coverage proof.** An LLM acts as an oracle **at the leaves** (never the
control loop): it emits a per-span surprisal map of a source file against the
encoded conventions (the reader). That map is cached as a deterministic artifact
keyed by `(content hash, conventions hash)`. A deterministic CI gate then asserts
that every above-threshold span is covered by a marker → doc.

A gap resolves one of two ways:

- **explain it** — which feeds the reader, lowering future surprisal; or
- **rewrite to conform** — dropping surprisal to ≈0.

Honest limit: this is provable *relative to the meter*, not absolute. And the
documentation burden *shrinks* as the reader grows.

## 11. Open questions

Recorded as open, not resolved:

- The precise formal statement of "coverage".
- Whether the leaf-oracle-as-surprisal-meter is acceptable, or a step too far.
- The fuller account of *why* a model mis-identifies a codebase's decisions: the
  working hypothesis is that it substitutes its own averaged taste
  ("poisoning") rather than merely failing to perceive the local taste — but
  this needs a fuller account.

## 12. Supersession

The prior **axes-first / 19-axis** type-system re-derivation effort — the M1–M7
module drafts under `docs/type-system-design/` and the planned axes document — is
**superseded** by the approach above: plural, per-question checkers derived from
first principles, with complexity capped by demand-the-decision.

A future reader should **not** resume the abandoned axes-first direction. (Those
files are not deleted in this pass; their formal retirement is tracked in
`TODO.md`.)

## Concrete state

Checker #1 — the value/kind checker — exists at `lib/check_kind/` as the first
instance of the plurality. It answers exactly one question (is every value used
as the kind the operation requires?) and shares none of the v5 solver machinery.
See `docs/checkers/value-kind.md`.

Its deferrals are each framed as a *future per-question checker*, not a gap:
integer/float distinction, table shapes, literal refinement, generics,
intersections, match types, and multi-return.
