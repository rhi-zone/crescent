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
  premises:   { node_id, ... },        -- sub-derivations this node's rule cites (its "hypotheses" in the proof-tree sense)
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
3. **Hypothesis discharge**: over the set of nodes reachable from root,
   collect every `hyp_id` appearing in any node's `discharges`. Then for
   every `hyp_id` appearing in any reachable node's `assumes`, require (a)
   it is defined in `certificate.hypotheses`, and (b) it appears in the
   discharged set. Either miss is rejected.

The kernel never reads `conclusion` or `Hypothesis.payload` beyond checking
existence — it has no idea what a "type," "term," or "unify" is. All meaning
lives in the theory (the schemas registered, and the producer that cites
them, e.g. `theories/algorithm_w.lua`).

## Stated simplification (not a design closure)

Hypothesis discharge above is checked by **id match anywhere in the
reachable set** — it does not verify that the discharging node is a lexical
ancestor of the assuming node in the derivation tree. A certificate could,
in principle, discharge a hypothesis on an unrelated branch and this kernel
would accept it as long as ids match. Real scoping — lexical ancestry,
shadowing, alpha-equivalence, binder identity, capture-avoiding
substitution — is exactly the machinery the rejected `lib/type/framework/`
attempt built (see `docs/typechecker-framework-postmortem.md`) and is
explicitly out of scope for this dinner-sized prototype. See `TODO.md`.
