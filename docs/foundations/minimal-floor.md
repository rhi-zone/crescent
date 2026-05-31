# Foundations — Minimal Floor, Bounded Generality, One-Shot Foundations

A from-first-principles account of *why* crescent is shaped the way it is: a
minimal runtime and minimal data shapes, with rigor layered on top rather than
welded in; generalities that declare their scope; and an insistence on getting
the calcifying core right before first ship. Companion to
[`pedagogy-and-the-reader.md`](pedagogy-and-the-reader.md), which covers what a
type system is *for*; this document covers what the *floor* must be.

Not a spec. A reader's artifact: the settled design positions, with the
reasoning preserved so a future reader can recover *why* and not relitigate
them.

The capability/sandbox/threat-model specifics referenced below are not restated
here — they live in [`../daemon-isolation.md`](../daemon-isolation.md).

## 1. Minimal floor, composable rigor

The substrate carries no built-in validation. Rigor — typing, validation,
schema — is a **composable, optional, escapable layer over a minimal core,
never welded into the substrate.**

The reference contrast is JSON versus XML. JSON's data model is minimal;
validation (JSON Schema) composes on top and is entirely optional. XML welded
the validation cathedral — DTD, XSD, namespaces — into the format itself, so
every consumer pays for the cathedral whether or not it needs one. JSON won.

The reasoning is about *time*. A substrate is load-bearing and effectively
permanent (see §4). Validation's notion of "correct" is not permanent — it
shifts as the domain, the schema, and taste evolve. If a notion of "correct"
lives in the floor, it calcifies an opinion that the rest of the system is then
forced to carry forever. **Built-in validation is policy welded into
mechanism.** Mechanism belongs in the floor; policy belongs in a layer above it
that can be replaced without disturbing the floor.

Crescent embodies this top to bottom:

- A **minimal runtime** — vanilla LuaJIT, unmodified, with no language
  extensions (see [`../overview.md`](../overview.md): "Crescent is not a
  language").
- **Minimal data shapes** — six opaque atoms, a nilable flag, arrows, tables,
  top/bottom (the value-universe encoding in
  [`pedagogy-and-the-reader.md` §2](pedagogy-and-the-reader.md)).
- The **typechecker as a layer over the runtime, not baked into it.** Code runs
  untyped; the checker is something you *apply* to source, not a gate the
  runtime enforces. Typing is the rigor layer; LuaJIT is the floor.

## 2. Bounded generality

A floor must be a **complete generality over a *declared* scope** — not an
open-ended "more general is always available" gradient.

The failure mode this rejects is the per-component cathedral: a generality that
is always one notch more general, never finished, never sound, because there is
always another case to fold in. That gradient is the same calcified-opinion
problem as §1, relocated into the abstraction itself. A generality that never
declares its boundary never completes.

The discipline: **each general thing declares the scope it is complete over,
with an explicit boundary and an explicit escape at the edge.** Inside the
declared scope it is total and sound; at the boundary it hands off to
blind-trust, visibly.

The typechecker is the worked instance:

- **Complete over a closed, statically-analyzable Lua subset.** The scope is
  declared, not aspirational; the checker is total within it.
- **Flag-gated escape hatch.** A file-level "trust but don't typecheck" opt-out
  and a narrow expression-level cast. Both are explicit, both are greppable.
- **Blind-trust at the boundary.** What sits outside the analyzable subset is
  trusted as declared, not silently guessed at.
- **Configurable soundness.** Strict mode is a closed, sound core. Loosened
  mode is *conditional* soundness — every hole is explicit and greppable, so
  the soundness statement is exactly "sound modulo these enumerated escapes,"
  never a vague "mostly fine."
- **The standard library and exemplar are built in strict, no-escape mode**, so
  the corpus everyone reads and copies is *provably* sound — the escape hatch
  exists for users, but the floor does not lean on it.

The generality lattice is topped by **dusklight as a ceiling.** Its universality
must be **lawful/algebraic** — optics plus laws, universal *via a small complete
core* — and explicitly **not universal-by-enumeration**. Enumerating cases at
the top would just relocate the unboundedness of §2's failure mode to the
ceiling instead of the floor. Universality is earned by a small set of laws that
generate the cases, not by a growing list of cases.

## 3. No special cases — stay where "correct" is forced

Minimality is not an aesthetic. It is the condition under which "correct" is
**determinate** rather than **underdetermined.**

- *Determinate*: there is one answer everyone converges on; the law forces it.
- *Underdetermined*: there are many defensible answers, so the resolution is
  taste, committee, and eventually incompatible fragmentation.

**A special case is precisely a place where correctness was not forced** — a
degree of freedom that was resolved by branching instead of by finding the law
or abstraction that *removes* the freedom. Every `if this specific case`
records a spot where the design failed to find the generality that would have
made the branch unnecessary.

"No special cases" therefore means: **stay in the forced regime, all the way
up.** Not "minimize branches for tidiness," but "keep choosing abstractions that
keep correctness determinate." Crescent's despecialcasing work
(`pairs`, `pcall`, and the rest of the `*-despecialcase-spec.md` line) is this
principle applied to the typechecker's own internals — each removed special case
is a degree of freedom collapsed back into a law.

## 4. A floor is a one-shot — even against its own author

A foundation that ships and is adopted **cannot be replaced afterward — even by
its own creator with a strictly superior successor.**

The cautionary record is JPEG. The committee that shipped JPEG went on to ship
six technically-superior successors — JPEG-LS, JPEG 2000, JPEG XR, JPEG XS,
JPEG XT, JPEG XL. Every one lost to their own original. Near-zero adoption,
despite being better, despite coming from the same authority that owned the
incumbent. Being right and being the author was not enough to overcome a
calcified floor.

The operational split this forces:

- **The calcifying core** — the invariants other things build *on*: the data
  model, the capability model, the protocol and composition shapes, the laws.
  This **must be right before first ship**, because it is effectively impossible
  to change afterward.
- **The non-calcifying periphery** — apps, content, anything built *on top*.
  This can ship early and iterate freely; it is downstream of the core and
  carries no one else's invariants.

The choice of core laws and invariants is the **irreducible, holistic, one-shot
kernel.** It cannot be decomposed into incremental, individually-checkable steps,
because it is *prior to* the laws that would check those steps — there is no
finer law to grade it against. Everything downstream is forced *relative to* it
(see §5). This is why crescent **prioritizes getting the core invariants right
over shipping speed for the core specifically**, while letting the periphery
move fast. Speed is cheap where mistakes are reversible and ruinous where they
are not.

## 5. Large work — recursive decomposition into forced leaves, sound reassembly

Large constructions complete in **many steps, not one.** The risk in any
many-step construction is that each step is an independent chance to be wrong.

A minimal lawful core (§1–§4) is what makes each step **forced** rather than
underdetermined: with the laws fixed, a step is *locally checkable against those
laws, in isolation, without holding the whole construction in one's head.* This
is the lever that turns "many steps, each a chance to be wrong" into "many steps,
each checked against the whole's invariants."

The division of labor:

- **Decomposition is the engine.** Break the construction into leaves small
  enough to be individually forced.
- **Cutting at the natural joints is the design judgment.** Choosing where to
  cut *is* choosing the laws and invariants. A good cut leaves each piece forced;
  a **bad cut is a special case at a seam** (§3) — a joint placed where no law
  forces it, which then has to be papered over.
- **Checking the seams is the typechecker's job.** Sound reassembly — verifying
  that locally-correct leaves compose into a globally-correct whole — is exactly
  what the checker mechanizes. It is the device that makes the decomposition
  *trustworthy*, not merely convenient.

This is the same demand-the-decision discipline as
[`pedagogy-and-the-reader.md` §8](pedagogy-and-the-reader.md), viewed from the
construction side: the checker either forces a leaf or demands the decision be
recorded, and the seams between leaves are where it earns its keep.

## See also

- [`pedagogy-and-the-reader.md`](pedagogy-and-the-reader.md) — what a type
  system is *for*; the reader; demand-the-decision.
- [`../daemon-isolation.md`](../daemon-isolation.md) — the capability model,
  sandbox, and threat model (the §1 "policy over mechanism" split applied to
  authority). Cross-referenced here, not restated.
- [`../principles.md`](../principles.md) — the user-facing north star (small
  computer, discoverability in the tool, no online resources in the loop).
- [Distribution strategy](#distribution-strategy-worse-is-better-inverted),
  below.

---

# Distribution strategy — worse-is-better, inverted

This is **go-to-market rationale, not a design principle.** It is recorded here
because it is the necessary complement to §1–§5: the principles above make the
floor *correct*; this section is how a correct floor *reaches the world*. The
two halves are asymmetric — the "right thing" half (correctness) is inert without
the distribution half, and distribution is what makes correctness reach anyone at
all.

The detailed numbers, formats, and target apps live in
[`../batteries.md` — "Distribution thesis"](../batteries.md); this section states
only the *strategy* and its reasoning.

## The premise — technical merit gains zero adoption alone

The JPEG record from §4 carries a second lesson. The six dead successors were
not merely un-replaceable — they were *better* and still gained near-zero
adoption. **Technical merit alone wins nothing against a calcified incumbent.**

Worse-is-better describes *why* the worse thing won: it won on viral, low-friction
distribution, not on correctness. The conclusion crescent draws is to **invert
it** — keep the correct floor (the "right thing"), but adopt worse-is-better's
*winning weapon* rather than competing on merit head-on.

## The strategy

- **Ride an existing host.** LuaJIT, and its embedded ubiquity — crescent does
  not ask the world to adopt a new runtime; it arrives inside one already
  everywhere.
- **Ship self-contained.** Vendored, all-platform binaries mean install is
  "download and extract" — friction far below what the target audience already
  tolerates. No registry, no build step, no network in the loop (consistent with
  [`../principles.md`](../principles.md)).
- **Distribute apps as archives and as PNGs.** The character-card-v2 lineage:
  an app is a tarball, optionally embedded in an image, so it rides an *existing
  sharing ritual* rather than asking for a new one. Format details:
  [`../batteries.md`](../batteries.md).
- **Reach users through a carrier application.** A wanted end-user app brings
  the whole OS along as cargo. The OS accretes inside hosts *after* infection —
  the user came for the app and ends up holding a complete, hackable substrate.
- **The OS is the destination of distribution, never the vector.** Nobody
  downloads "an OS in Lua." They download the thing they wanted; the OS arrives
  as a footnote (the explicit framing in
  [`../batteries.md`](../batteries.md): "the OS layer arrives as a footnote").

The asymmetry is the point: correctness without distribution stays inert, so
distribution is co-equal with correctness — not a marketing afterthought to the
real work, but the half that makes the real work matter.
