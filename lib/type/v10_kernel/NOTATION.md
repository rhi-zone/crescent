# v10 kernel — certificate notation

This is the grammar the kernel (`kernel.lua`) replays. It is deliberately
small — a stranger should be able to read this page and then read
`kernel.lua` and `theories/algorithm_w.lua` without needing anything else.

## Certificate

```
Certificate = {
  theory:      string,               -- name of the registered theory (must match Registry.theory)
  nodes:       { [node_id]: Node },   -- every derivation step, keyed by its own id
  hypotheses:  { [hyp_id]: Hypothesis },  -- every hypothesis assumed anywhere in the certificate
  root:        node_id,               -- the node whose conclusion is the certificate's overall claim
}
```

## Node — a judgment-at-a-locus, justified by a rule citation

```
Node = {
  id:         string,          -- this node's own id (matches its key in Certificate.nodes)
  rule:       string,          -- CITATION: name of a rule schema registered in the theory registry
  judgment:   string,          -- which judgment this node concludes (must match the cited schema's judgment)
  locus:      string,          -- where in the source term this judgment holds ("judgment-at-a-locus")
  conclusion: <opaque>,        -- theory-specific payload (e.g. { term, type }). The kernel only checks it's non-nil.
  premises:   { node_id, ... },        -- sub-derivations this node's rule cites (its "hypotheses" in the proof-tree sense). May repeat a node_id already cited elsewhere in the certificate (a shared sub-derivation) -- premises form a DAG, not only a tree. See "Discharge scoping" below.
  assumes:    { hyp_id, ... } | nil,   -- hypothesis ids this node's derivation structurally depends on (e.g. a variable lookup)
  discharges: { hyp_id, ... } | nil,   -- hypothesis ids this node's rule discharges (e.g. a lambda binding its parameter)
}
```

## Hypothesis — an assumption that must be discharged somewhere

```
Hypothesis = {
  id:        string,
  judgment:  string,    -- what judgment this hypothesis states
  payload:   <opaque>,  -- theory-specific (e.g. { name, type })
}
```

## RuleSchema — what a theory registers, once, per rule

```
RuleSchema = {
  name:       string,    -- the string a Node.rule cites
  judgment:   string,    -- the judgment a node citing this schema must conclude
  arity:      integer,   -- exact required length of Node.premises for a node citing this schema
  assumes:    boolean | nil,     -- whether a node citing this schema may set `assumes`
  discharges: boolean | nil,     -- whether a node citing this schema may set `discharges`
}
```

**Confirmed by adding a second theory (Algorithm J, see
`theories/algorithm_j.lua`):** a `RuleSchema` describes a judgment and a
node's structural shape only — never anything about how a producer derives
that conclusion. Two producers implementing the same judgment (Algorithm W
and Algorithm J both derive the same Damas-Milner `has_type` judgment, one
functionally, one imperatively) can therefore cite the literal same
`RuleSchema` objects, registered into their own separately-scoped
`Registry` instances, with no kernel or registry changes. `registry.lua`
already scopes schemas per `Registry`, and `kernel.lua`'s `M.replay` only
ever consults the one registry passed to it — this is what makes the reuse
possible without either trusted file needing to know it's happening.

## What the kernel checks, and in what order (`kernel.lua`'s `M.replay`)

1. `certificate.theory == registry.theory` (right registry for this certificate).
2. DFS from `certificate.root` over `premises` edges. Per node visited:
   - **citation validity**: `registry.lookup(node.rule)` must resolve.
   - **rule instantiation**: `node.judgment` must equal the schema's `judgment`;
     `#node.premises` must equal the schema's `arity`; `node.assumes` may only
     be set if the schema's `assumes` is true; same for `discharges`.
   - **well-foundedness**: a node currently being visited that is visited
     again (i.e. reachable from itself) is a cycle — rejected immediately,
     no traversal ever loops.
3. **Hypothesis discharge (ancestor-scoped)**: `premises` edges form a DAG
   rooted at `certificate.root` (a tree is the special case where every node
   has exactly one parent). Compute, for every reachable node, the set of
   hypothesis ids guaranteed discharged by an ANCESTOR on **every**
   root-to-node path reaching it — the intersection, across each incoming
   `premises` edge from a parent P, of (P's own ancestor-discharge set
   UNION P's own `discharges`). Then for every `hyp_id` appearing in any
   reachable node's `assumes`, require (a) it is defined in
   `certificate.hypotheses`, and (b) it is in that node's ancestor-discharge
   set. Either miss is rejected. A hypothesis discharged only on a sibling
   branch, or only on some (not all) of the paths reaching a shared node,
   does not count — see "Discharge scoping" below.

The kernel never reads `conclusion` or `Hypothesis.payload` beyond checking
existence — it has no idea what a "type," "term," or "unify" is. All meaning
lives in the theory (the schemas registered, and the producer that cites
them, e.g. `theories/algorithm_w.lua`).

## Discharge scoping

Hypothesis discharge is checked by **ancestor-path scoping**, the way
variable scoping works in a proof tree or lambda calculus: a hypothesis a
node `assumes` must be discharged by a node that structurally encloses it —
present on every root-to-node path through `premises` — not merely by some
other node anywhere in the certificate. A discharge on an unrelated branch
no longer satisfies an assumption in a sibling branch.

`premises` edges may form a DAG, not only a tree: a node MAY be listed as a
premise of more than one parent (a shared sub-derivation). Neither W's nor
J's producers ever emit a shared node today (each is built fresh per
source-term occurrence), so this generalization has no effect on any
certificate either theory currently produces — a tree is just the DAG case
where every node has one parent. When a node genuinely is shared, its
assumption must be discharged by an ancestor on **every** path that reaches
it, not merely one: this is what makes a DAG certificate mean the same thing
as the (possibly larger) tree you'd get by unfolding each shared node into
one copy per incoming path, since each unfolded copy would independently
need its own ancestor-discharge.

Real scoping beyond this — shadowing, alpha-equivalence, binder identity,
capture-avoiding substitution — is still exactly the machinery the rejected
`lib/type/framework/` attempt built (see
`docs/typechecker-framework-postmortem.md`) and remains explicitly out of
scope for this dinner-sized prototype. See `TODO.md`.

## Term binder representation: de Bruijn indices (2026-07-27)

Both theory entries (`theories/algorithm_w.lua`, `theories/algorithm_j.lua`)
represent lambda-calculus terms using de Bruijn indices for variable
binding, not source names:

```
var term  = { tag: "var", index: integer, name: string, locus: string }
abs term  = { tag: "abs", param: string, body: Term, locus: string }
let term  = { tag: "let", name: string, value: Term, body: Term, locus: string }
```

`index` is the de Bruijn index: `0` refers to the nearest enclosing binder
(the innermost `abs`'s parameter or `let`'s bound name), `1` the next one
out, and so on. The environment each producer threads through `infer` is a
depth-indexed list (position 1 = index 0), extended by prepending one entry
per binder (`env_extend` in both theory files) — never a name-keyed table.
Variable lookup is `env[index + 1]`; there is no name comparison anywhere in
either producer's binder-resolution path.

`param` (on `abs`) and `name` (on `let` and `var`) are purely COSMETIC
display strings — used only to label hypothesis payloads and node
conclusions for readability (error messages, certificate pretty-printing).
They are never consulted for lookup, unification, or any identity- or
soundness-relevant comparison. Two variables at different de Bruijn depths
may legitimately share a display name (shadowing); when they do, the index
is what is semantically load-bearing, always — the display name is not.

**Which framework lessons this closes, and which it doesn't**
(`docs/typechecker-framework-postmortem.md`'s three carry-forward lessons):

- **Lesson 1 (binder identity must be lexical position, never source-name
  comparison) — now structurally true, not just true by implementation
  accident.** Before this change, shadowing worked only because each theory's
  environment was an ordinary Lua table chain (`setmetatable(..., { __index
  = env })`) that happened to resolve innermost-first — nothing in the
  certificate grammar tracked binder identity. Under de Bruijn there is no
  name to compare in the first place; a lookup is an integer index into a
  depth-indexed list. This is now true by construction.
- **Lesson 3 (alpha-stable digests) — now free.** Alpha-equivalent named
  terms (e.g. `\x -> x` and `\y -> y`) produce byte-identical de Bruijn terms
  (`{ tag = "abs", param = <cosmetic>, body = { tag = "var", index = 0, ... } }`
  either way — only the cosmetic `param`/`name` strings can differ, and
  those are never part of what a digest over binding structure would need to
  consider). Digesting a de Bruijn term for alpha-equivalence needs no
  dedicated machinery, unlike the rejected `framework/` attempt's 239-line
  `alpha.lua`.
- **Lesson 2 (capture-avoidance must be a CHECKED condition, never assumed)
  — only PARTIALLY resolved, do not overclaim this as closed.** De Bruijn
  shift/substitution is capture-avoiding by construction of one correct
  algorithm, which narrows what a future checked condition would need to
  verify. But the kernel's whole discipline is to trust no producer's code —
  W and J are untrusted producers `kernel.lua` never runs — and nothing in
  this kernel replays or verifies that either producer's `infer` actually
  performs shift/substitution correctly. A checked capture-avoidance
  condition, replayed by the kernel the way hypothesis discharge already is,
  remains unbuilt. See `TODO.md`.
