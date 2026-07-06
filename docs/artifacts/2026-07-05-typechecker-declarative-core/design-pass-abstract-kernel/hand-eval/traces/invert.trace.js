// Auto-generated from invert.json — do not hand-edit; regenerate from the .json if it changes.
window.TRACES = window.TRACES || {}; window.TRACES['invert'] = {
  "design": "invert",
  "provenance": "llm-abstract-eval",
  "scenarios": {
    "corpus-1-lru-self": {
      "steps": [
        {
          "step": 1,
          "description": "Producer builds Claim{id, holds: tr -> tr:binding_at_entry(\"self\") ~= nil}. Kernel never inspects holds' body.",
          "state": { "claim": "self-nonnil@lru:155", "holds": "tr -> binding_at_entry(self) ~= nil" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [16, 29] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "Producer builds Proof certificate: rule=seq_compose, premises=[P1: 'is Cache:peek defined with : syntax?' framed as a Witness-checkable AST fact, P2: pool's err-absence axiom, used as hypothesis].",
          "state": { "cert": "Proof(seq_compose, [P1, P2])" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [215, 226] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "Kernel check() recurses into P1. Witness certificates (per the design's own definition) only ever run evaluator(input)->trace and call claim.holds(trace) -- but the trusted evaluator's own R-METHODCALL rule desugars `o:m(a) ⟿ o.m(o,a)` before any Trace event exists, i.e. colon-vs-dot syntax is erased at desugar time. No mechanism is given for a Witness cert's trace-replay check to observe erased source syntax, yet 3.1's walkthrough calls this premise 'Witness-checkable... decided by literal parse, not opinion' without reconciling the two. Cannot determine what check() actually does with P1.",
          "state": { "premise": "P1: def-form-is-colon", "mechanism": "unspecified" },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [44, 51] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [89, 99] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [215, 219] }
          ],
          "confidence": "unsure"
        }
      ],
      "verdict": "halt",
      "verdictNote": "Doc's own walkthrough (3.1.1) claims Proved, but the load-bearing premise ('defined with colon syntax') has no specified checking mechanism: Witness certs only replay Trace, and R-METHODCALL erases colon/dot before any Trace event exists. Blocking gap: no defined path for a Witness certificate to check a static-parse/AST fact under this constraint."
    },

    "corpus-2-json-hex": {
      "steps": [
        {
          "step": 1,
          "description": "Producer builds Claim (HEX non-nil at line 125) and a Proof cert rule=induct_trace; base case = Witness replay of module-top showing bind(HEX,{}) -> non-nil table (table-constructor evaluation is a trusted evaluator rule).",
          "state": { "claim": "HEX-nonnil@json:125", "cert": "Proof(induct_trace, [base_case_witness])" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [227, 238] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "Inductive step submitted is a Witness-checkable claim over ONE replayed trace ('no bind event named HEX between p0 and p125'), a single-trace occurrence scan -- not '[the evaluator's rule for event class X preserves predicate P]', which is how induct_trace's own precondition is defined in 1.2(b). The doc's abstract rule definition and its own concrete walkthrough disagree about what a valid inductive step is, and RULES.induct_trace is an unimplemented stub, so it's undetermined whether the real structural-check function would accept this substitution.",
          "state": { "inductive_step": "single-trace rebind-absence scan", "rule_definition": "evaluator-rule-preserves-P (1.2b)", "conflict": "instance-fact vs rule-level fact" },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [70, 73] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [227, 238] }
          ],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "Doc's own narration states the kernel emits Proved for this certificate. Even taking that at face value, the claim actually established (per 1.3's Witness scope) is bounded to the one witnessed execution, weaker than a standing universal fact about every module load -- the doc does not address this narrowing.",
          "state": { "verdict": "Proved (per doc narration)", "scope": "single witnessed execution, not proven universal" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [227, 238] }],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Doc explicitly narrates Proved, but the inductive step used (single-trace rebind scan) doesn't match induct_trace's own 1.2(b) definition (an evaluator-rule-preservation fact, not a per-run scan); whether the real (unspecified) structural-check function would actually accept this is undetermined by the design as written."
    },

    "corpus-3-queue-fifo": {
      "steps": [
        {
          "step": 1,
          "description": "Identical certificate schema to corpus-2 (HEX), reused verbatim per doc's own text ('same reused proof schema, not a second rule'): Proof(induct_trace, [base-case Witness table-ctor replay]).",
          "state": { "claim": "FIFO-nonnil@queue:157", "cert": "Proof(induct_trace, [base_case_witness])" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [239, 242] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "Same induct_trace instance-fact vs rule-level-fact mismatch as corpus-2's step 2: inductive step is a single-trace scan, not an evaluator-rule-preservation fact.",
          "state": { "inductive_step": "single-trace rebind-absence scan", "conflict": "instance-fact vs rule-level fact" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [70, 73] }],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "Doc narrates Proved; scope again bounded to the one witnessed execution if taken at face value.",
          "state": { "verdict": "Proved (per doc narration)" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [239, 242] }],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Same shape and same unresolved induct_trace soundness question as corpus-2 (HEX)."
    },

    "corpus-4-deque-self-x4": {
      "steps": [
        {
          "step": 1,
          "description": "Producer amortizes: one universal certificate concluding '□(every deref of self in this function body is non-nil)', four site-specific claims each proved by trivial witness projection of that one universal, per doc's explicit framing ('kernel adds no new machinery per occurrence').",
          "state": { "claim": "self-nonnil@deque:pop_front (universal)", "projections": 4 },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [243, 250] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "The underlying universal certificate is constructed identically to corpus-1's Proof(seq_compose, [def-form-is-colon AST fact, err-absence axiom]) -- it inherits corpus-1's unresolved gap: no specified mechanism for a Witness certificate to check the 'defined with colon syntax' premise given R-METHODCALL's erasure of that information before any Trace event exists.",
          "state": { "inherited_gap": "corpus-1 step 3 (AST-fact-via-Witness mechanism unspecified)" },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [44, 51] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [243, 250] }
          ],
          "confidence": "unsure"
        },
        {
          "step": 3,
          "description": "Doc frames the four-site reuse as 'one rule, reused' rather than four re-derivations -- meaning the unresolved gap in step 2 is reused identically across all four sites too, not independently re-decided per site.",
          "state": { "reuse": "single rule registration, four target ids" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [243, 250] }],
          "confidence": "determined"
        }
      ],
      "verdict": "halt",
      "verdictNote": "Inherits corpus-1's blocking gap (self-nonnil certificate construction unspecified); the doc's own 'one rule, reused 4x' framing means the gap is carried identically to all four sites rather than resolved or multiplied."
    },

    "corpus-5-bigint-reachable": {
      "steps": [
        {
          "step": 1,
          "description": "Producer builds Claim: holds(tr) = 'trace reaches an event at bigint/init.lua:115, branch then'.",
          "state": { "claim": "branch-reachable@bigint:115" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [16, 29] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "Producer's cheapest move per doc's own text: a Witness certificate with a concrete input for which the evaluator actually reaches that site. Reading the real code (lib/bigint/init.lua:104 'if ai ~= 0 then'), any multiplication involving a nonzero digit reaches line 115's then-branch trivially -- such an input plainly exists.",
          "state": { "cert": "Witness{input: mul_abs(nonzero, nonzero), polarity: true}" },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [252, 262] },
            { "file": "lib/bigint/init.lua", "lines": [104, 117] }
          ],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "check(): cert.tag==\"witness\" -> evaluator.run(program,input)->trace; claim.holds(trace) == cert.polarity(true) -> true. Reachability requires no proof calculus, purely existential replay, matching '1.2(b) replay: existential engine'.",
          "state": { "check_result": true },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [60, 64] }],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "Verdict: Proved(cert).",
          "state": { "verdict": "Proved" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [101, 104] }],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Clean case: reachability needs only a Witness replay, matching doc's own 3.1.5 'cheapest move' description exactly, and the required witness input trivially exists in the real code."
    },

    "adversarial-subtract-false-proved": {
      "steps": [
        {
          "step": 1,
          "description": "Same source file/lines as corpus-1; producer builds the identical certificate: Proof(seq_compose, [def-form-is-colon AST fact, err-absence axiom]). Nothing in the design distinguishes this scenario mechanically from corpus-1.",
          "state": { "cert": "Proof(seq_compose, [P1, P2])" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [215, 226] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "This scenario's ground truth differs: a real counterexample call, Cache.peek(nil, key), exists -- colon *definition* syntax places no obligation on *callers*. This is a fact about the corpus (established by reading the real call sites), not something invert.md itself discusses or accounts for.",
          "state": { "groundTruth": false, "counterexample": "Cache.peek(nil, key)" },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [152, 159] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "Whether check() rejects this certificate depends entirely on seq_compose's actual structural precondition -- unimplemented in the doc (RULES entries are stub functions, exact contents deferred to future substrate work per 1.2b/5). If seq_compose only verifies 'function was defined with colon sugar' (as 3.1.1 literally describes the premise), it never inspects call sites and would wrongly accept this false claim. Doc's own 'Thin' trade-offs section (5) names exactly this failure mode as a live, review-dependent risk, not a structurally prevented one -- it does not say what the actual rule table would do here.",
          "state": { "rule": "seq_compose", "structural_precondition": "unspecified (stub)", "named_risk": "5 Thin: sloppy calculus could bake in domain-shaped rule" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [376, 384] }],
          "confidence": "underdetermined"
        }
      ],
      "verdict": "halt",
      "verdictNote": "Design explicitly names this exact failure class as an open, review-dependent risk (5, 'Thin') rather than a structurally prevented one; the fixed calculus's actual rule contents (undesigned) determine whether a definition-site-only premise wrongly gets accepted as call-site-sufficient, and doc does not resolve it. Also independently inherits corpus-1's certificate-construction gap (step 3 there)."
    },

    "adversarial-saturation-b-identity-merge": {
      "steps": [
        {
          "step": 1,
          "description": "Invert's pool model (1.4): entries are (claim, role, provenance-tag); the only cross-claim operation is a dependency-graph acyclicity check over certificate-dependency edges. No merge, rewrite, or equivalence-class mechanism exists anywhere in the design (1-5).",
          "state": { "pool_operation": "DAG acyclicity check only", "merge_mechanism": "none" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [106, 133] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "factA (Cache:peek, real counterexample) and factB (Deque:pop_front, calledOnlyViaColon true) are each built as independent (claim, cert) pairs per the same schema as adversarial-subtract-false-proved and corpus-4 respectively. Nothing in invert's pool identifies them as 'the same fact' or collapses their identities -- the specific amplification mechanism this scenario targets (canonicalizing nonnil_binding(self,_) across functions) has no structural counterpart here.",
          "state": { "factA": "independent entry, no shared identity", "factB": "independent entry, no shared identity" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [106, 133] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "factA's certificate independently hits the same unresolved gap as adversarial-subtract-false-proved (seq_compose's undesigned call-site-completeness precondition, plus the corpus-1 AST-fact-via-Witness construction issue). factB's certificate independently hits the same unresolved gap as corpus-1/4 (AST-fact-via-Witness construction), though its ground truth is true. Neither can contaminate the other since no merge exists.",
          "state": { "factA_status": "inherits adversarial-subtract-false-proved halt", "factB_status": "inherits corpus-1 halt" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [215, 226] }],
          "confidence": "determined"
        }
      ],
      "verdict": "halt",
      "verdictNote": "The specific amplification mechanism this scenario targets (identity-merge across pool entries) does not exist in invert's design at all -- pool entries are never merged, only DAG-checked by dependency edges. No amplification is structurally possible. factA and factB each independently hit the same unresolved certificate-construction gaps as corpus-1/4/adversarial-subtract-false-proved, but they don't compound."
    },

    "hand-json-type-guard": {
      "steps": [
        {
          "step": 1,
          "description": "Producer would build Claim: holds(tr) = 'at the trace position for line 416, val's runtime type tag is number'. Design places no ceiling on claim content (3.3), so this closure is admissible.",
          "state": { "claim": "val-number-arm@json:416" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [284, 289] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "To prove this universally (for all inputs reaching this branch), a proof-shaped certificate is needed connecting 'branch taken because t==\"number\"' (t bound from type(val)) to 'val's runtime tag is number'. None of the three illustrative RULES (seq_compose, induct_trace, const_fold) covers this: const_fold is explicitly scoped to literal subterms with no state dependency (doc's own example: a condition syntactically false), but t == \"number\" depends on runtime state (val), not a pure literal. 1.2(b) states the rule list is 'illustrative, not exhaustive' and the exact rule set is 'itself a substrate deliverable' (5) -- whether a rule for this ordinary type()-narrowing pattern exists is left entirely open by the text.",
          "state": { "candidate_rules": ["seq_compose", "induct_trace", "const_fold"], "match": "none", "reason": "const_fold requires state-independent literal subterm; t==\"number\" is state-dependent" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [53, 83] }],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "Absent such a rule, the only remaining certified path is Witness -- which per 1.3 establishes only a per-input existential fact ('in this one witnessed run, val was a number here'), not the standing universal fact the claim implies.",
          "state": { "fallback": "Witness (existential only)" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [89, 93] }],
          "confidence": "determined"
        }
      ],
      "verdict": "halt",
      "verdictNote": "No rule in the design's illustrative calculus covers 'branch condition via a runtime type-tag check implies a runtime-type fact'; doc explicitly defers the calculus's actual contents to future substrate work, so it's undetermined whether this ordinary narrowing pattern is certifiable at all under invert as currently specified."
    },

    "hand-bigint-err-arm": {
      "steps": [
        {
          "step": 1,
          "description": "ret1-nil-arm: the returned expression at line 305's first value is syntactically the literal `nil` token -- matches const_fold's stated shape directly ('literal expressions... evaluated directly by the evaluator on the subterm alone, with no state dependency').",
          "state": { "claim": "ret1-nil-arm", "cert": "const_fold(literal nil)" },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [74, 77] },
            { "file": "lib/bigint/init.lua", "lines": [304, 306] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "ret2-string-arm: the returned expression is a concatenation of a literal and a call to the builtin type(v). Establishing 'this expression's runtime arm is string' requires knowing type() always returns a string -- a Lua-semantics invariant. 1.2(a)'s evaluator rule list names only core language forms (assignment, call/return incl. method-call desugaring, branch-taken, metamethod dispatch, error propagation) and does not mention stdlib builtins. Cannot tell from the doc whether builtin-function return-type invariants are inside the trusted evaluator's modeled semantics or would need additional (unspecified) trusted surface.",
          "state": { "claim": "ret2-string-arm", "expression": "literal .. type(v)", "gap": "stdlib builtin semantics not listed among evaluator rule forms" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [44, 51] }],
          "confidence": "unsure"
        },
        {
          "step": 3,
          "description": "Given the gap in step 2, this specific claim cannot be confirmed certifiable purely via const_fold; a Witness replay could still establish the fact for one concrete witnessed call (existential), per 1.3's stated scope.",
          "state": { "fallback": "Witness (existential only)" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [89, 93] }],
          "confidence": "determined"
        }
      ],
      "verdict": "halt",
      "verdictNote": "ret1-nil-arm proves cleanly via const_fold (literal return value, no state dependency). ret2-string-arm blocks on an unstated gap: whether Lua stdlib builtins like type() have their return-type invariants inside the trusted evaluator's modeled semantics (1.2a lists only core language forms)."
    },

    "hand-lru-field-shape": {
      "steps": [
        {
          "step": 1,
          "description": "map-table-arm: `_map = {}` is a syntactic table-constructor literal with no state dependency at all (unconditionally a fresh literal table on every invocation). const_fold applies directly, and doc's own corpus-2 walkthrough already establishes 'table-constructor evaluation is a trusted evaluator rule: constructors never produce nil'.",
          "state": { "claim": "map-table-arm", "cert": "const_fold(table constructor literal)" },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [227, 234] },
            { "file": "lib/lru/init.lua", "lines": [88, 91] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "ttl-number-arm: groundTruth is explicitly false (opts.ttl is documented optional, real nil arm exists at `_ttl = o.ttl`). No sound universal certificate exists. Natural producer move: a Witness refutation -- call M.new with opts lacking .ttl, replay, claim.holds(trace) returns false against the claimed non-nil assertion, refuting per 1.2(b)'s dualized witness-refutation mechanism ('also used, dualized, to refute claims: one witness trace where holds returns false').",
          "state": { "claim": "ttl-number-arm", "groundTruth": false, "cert": "Witness{input: M.new(n, {}), polarity: false}", "verdict": "Refuted" },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [60, 64] },
            { "file": "lib/lru/init.lua", "lines": [77, 101] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "refuted",
      "verdictNote": "map-table-arm proves cleanly (Proved via const_fold, no gap). ttl-number-arm is genuinely false and the design's dualized Witness-refutation mechanism catches it cleanly (Refuted) -- no blocking gap in either sub-claim; ttl is the diagnostically interesting one so it anchors the top-level verdict."
    },

    "hand-lru-closure-upvalue": {
      "steps": [
        {
          "step": 1,
          "description": "node-upvalue-arm: groundTruth is explicitly false (node reaches the nil arm at list exhaustion via `node = node.next`, per the source). A producer can trivially supply a Witness refutation: iterate a small (e.g. 1-element) Cache to exhaustion; the evaluator's trace shows node bound to nil at the reassignment event corresponding to list-end, refuting the claimed non-nil-throughout universal via the same dualized witness-refutation mechanism as the ttl scenario.",
          "state": { "claim": "node-upvalue-arm", "groundTruth": false, "cert": "Witness{input: 1-element cache exhaustion, polarity: false}", "verdict": "Refuted" },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [60, 64] },
            { "file": "lib/lru/init.lua", "lines": [248, 264] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "cache-upvalue-arm: `local cache = self` copies self's value; proving cache non-nil requires first establishing self ~= nil at Cache:iter's method entry -- the exact same certificate shape (colon-call self-nonnil via seq_compose over R-METHODCALL + err-absence axiom) as corpus-1, which hit an unresolved gap there (no specified mechanism for a Witness cert to check the 'defined with colon syntax' premise given R-METHODCALL's erasure of that fact before any Trace event exists). This claim is downstream of that same unresolved gap.",
          "state": { "claim": "cache-upvalue-arm", "inherited_gap": "corpus-1 step 3 (AST-fact-via-Witness mechanism unspecified)" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [44, 51] }],
          "confidence": "unsure"
        }
      ],
      "verdict": "halt",
      "verdictNote": "node-upvalue-arm refutes cleanly (Witness-based, no gap). cache-upvalue-arm inherits corpus-1's unresolved self-nonnil certificate-construction gap (it depends on self being established non-nil at method entry first), so the scenario as a whole hits a blocking gap."
    },

    "hand-json-generic-for": {
      "steps": [
        {
          "step": 1,
          "description": "Producer builds Claim: holds(tr) = 'at each loop-body-entry event for this for-in over pairs(tval), control var k is non-nil'. Generic-for is a real Lua 5.1 language form, and the evaluator is described as covering 'one rule per language form' for 'real operational semantics', so a bare generic-for control-flow rule (stop-on-first-nil-return) is plausibly within its stated scope.",
          "state": { "claim": "k-nonterminator-arms@json:437" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [44, 51] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "But the claim's actual evidence names pairs() specifically, not a generic 'any iterator never yields nil except at termination'. Establishing this requires the trusted evaluator to know pairs()'s specific never-nil-until-exhaustion behavior -- a stdlib-function semantics fact, not a bare core-language-form fact. 1.2(a)'s rule list enumerates only core forms (assignment, call/return, branch-taken, metamethod dispatch, error propagation) with no mention of stdlib functions (type, pairs, string library, etc.) as part of the trusted evaluator's modeled semantics -- the same class of gap identified in hand-bigint-err-arm's ret2 claim.",
          "state": { "gap": "stdlib builtin (pairs/next) semantics not listed among evaluator rule forms", "same_class_as": "hand-bigint-err-arm ret2-string-arm" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [44, 51] }],
          "confidence": "unsure"
        },
        {
          "step": 3,
          "description": "Absent that, the only remaining certified path is Witness, establishing only a per-input existential fact (this one witnessed iteration never saw k==nil in the body), not the universal claim across every table pairs() might iterate.",
          "state": { "fallback": "Witness (existential only)" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/invert.md", "lines": [89, 93] }],
          "confidence": "determined"
        }
      ],
      "verdict": "halt",
      "verdictNote": "Whether Lua stdlib builtins (here pairs()/next()) are covered by the trusted evaluator's modeled semantics is not stated in the design; 1.2(a) enumerates only core language forms. Same gap class as hand-bigint-err-arm's ret2-string-arm claim."
    }
  }
}
;
