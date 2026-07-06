// Auto-generated from subtract.json — do not hand-edit; regenerate from the .json if it changes.
window.TRACES = window.TRACES || {}; window.TRACES['subtract'] = {
  "design": "subtract",
  "provenance": "llm-abstract-eval",
  "scenarios": {
    "corpus-1-lru-self": {
      "steps": [
        {
          "step": 1,
          "description": "admit opaque deref-claim payload (subject=self, unionArms=[Cache,nil], claimedArms=[Cache]) -> id A; admit opaque colon-def payload (form=colon, receiver_param=self) -> id D",
          "state": { "pool": ["A", "D"], "edges": [] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [162, 226] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/scenarios.js", "lines": [79, 97] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "submit zero-premise axiom edge for D backed by a rule asserting the parse-tree read (form/def_line) is correct; kernel re-executes check() with premises={}, gets true, no cycle possible with empty premises -> edge admitted",
          "state": { "edges": ["axiom(D)+"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [248, 257] }
          ],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "submit colon-self-nonnil-v1 edge: premises={D}, target=A, polarity=supports. Kernel checks D,A are real pool ids (yes); checks acyclicity (A has no outgoing edges yet, no cycle); re-executes check(premises,target): def.form==\"colon\" && def.receiver_param==target.subject && claimedArms==unionArms\\{nil} -- all true for this payload -- edge admitted",
          "state": { "edges": ["axiom(D)+", "colon-self-nonnil-v1(D)->A +"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [211, 246] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [59, 70] }
          ],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "close(pool): fixpoint -- D Proved (zero-premise rule returned true) -> A Proved (supports-edge, sole premise D already Proved)",
          "state": { "verdicts": { "D": "proved", "A": "proved" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [185, 196] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "matches doc's own §2.2 walkthrough verbatim; happens to agree with ground truth here since calledOnlyViaColon=true, but the rule as written never inspected call sites to know that."
    },

    "corpus-2-json-hex": {
      "steps": [
        {
          "step": 1,
          "description": "admit single-assignment fact payload (name=HEX, assignment_count=1, initial_value_kind=table) -> id H1; admit deref-claim payload (subject=HEX, claimedArms=[table]) -> id H2",
          "state": { "pool": ["H1", "H2"], "edges": [] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [265, 272] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/scenarios.js", "lines": [201, 214] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "submit a zero-premise axiom edge for H1 (miner-correctness rule), by analogy to §2.2's colon_def_id base case -- needed so H1 can resolve Proved rather than Open before it can serve as a Proved premise. §3.1 item 2's own text does not spell this out explicitly (only item 1 in §2.2 does); this step is read in by structural necessity of close()'s 'premises must resolve Proved' rule, not shown directly for this instance",
          "state": { "edges": ["axiom(H1)+ (assumed)"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [265, 272] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [368, 376] }
          ],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "submit never-reassigned-nonnil edge: premises={H1}, target=H2, supports. check: assignment_count==1 && initial_value_kind==\"table\" && name==target.subject && claimedArms==unionArms\\{nil} -- all true -- acyclic -- edge admitted",
          "state": { "edges": ["never-reassigned-nonnil(H1)->H2 +"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [77, 88] }
          ],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "close(pool): H1 Proved (per step 2's assumed axiom) -> H2 Proved. Disclosed gap (no ordering/dominance check between assignment and deref) not exercised, since use is after assignment in this scenario",
          "state": { "verdicts": { "H1": "proved", "H2": "proved" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [185, 196] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "proved contingent on step 2's axiom edge, which the doc's §3.1 item 2 asserts as a result but does not walk through mechanically the way §2.2 does for item 1 -- a real gap in the doc's own account, not a fabrication on my part."
    },

    "corpus-3-queue-fifo": {
      "steps": [
        {
          "step": 1,
          "description": "admit single-assignment fact (name=FIFO, assignment_count=1, initial_value_kind=table) -> id F1; admit deref-claim (subject=FIFO, claimedArms=[table]) -> id F2. Identical shape to corpus-2/HEX",
          "state": { "pool": ["F1", "F2"], "edges": [] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [273, 276] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/scenarios.js", "lines": [333, 344] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "submit zero-premise axiom edge for F1, same unresolved gap as corpus-2 step 2: doc's §3.1 item 3 says 'identical shape to #2' but never independently re-derives the axiom step",
          "state": { "edges": ["axiom(F1)+ (assumed)"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [273, 276] }
          ],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "submit never-reassigned-nonnil edge: premises={F1}, target=F2, supports -- check returns true (same rule, same predicate shape as corpus-2), acyclic, edge admitted",
          "state": { "edges": ["never-reassigned-nonnil(F1)->F2 +"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [77, 88] }
          ],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "close(pool): F1 Proved -> F2 Proved",
          "state": { "verdicts": { "F1": "proved", "F2": "proved" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [185, 196] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "same shape and same axiom-step gap as corpus-2."
    },

    "corpus-4-deque-self-x4": {
      "steps": [
        {
          "step": 1,
          "description": "admit one colon-def payload (Deque:pop_front, form=colon, receiver_param=self) -> id D; submit its zero-premise axiom edge (same rule family as corpus-1, explicit precedent from §2.2) -> D Proved",
          "state": { "pool": ["D"], "verdicts": { "D": "proved" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [277, 283] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "admit four deref-claim payloads (subject=self, claimedArms=[Deque]), one per use line 62/63/64/65 -> ids A1..A4",
          "state": { "pool": ["D", "A1", "A2", "A3", "A4"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/scenarios.js", "lines": [425, 436] }
          ],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "submit the SAME colon-self-nonnil-v1 rule four times: premises={D}, target=Ai, supports, for i=1..4. Kernel re-executes check() independently each call (no caching of the rule's verdict across targets is described, but the rule is a pure function of its inputs so it returns true every time); each is acyclic (each Ai has no outgoing edges); all four edges admitted -- one rule registration, four separate submit() calls",
          "state": { "edges": ["colon-self-nonnil-v1(D)->A1 +", "colon-self-nonnil-v1(D)->A2 +", "colon-self-nonnil-v1(D)->A3 +", "colon-self-nonnil-v1(D)->A4 +"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [277, 283] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [59, 70] }
          ],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "close(pool): D Proved -> A1,A2,A3,A4 all Proved via the same rule, same shared premise",
          "state": { "verdicts": { "A1": "proved", "A2": "proved", "A3": "proved", "A4": "proved" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [185, 196] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "all four sites proved by one rule registration, per doc's own claim; ground truth agrees here (calledOnlyViaColon=true), but as in corpus-1 the rule never looked at call sites, so this is agreement by coincidence of this particular corpus, not by anything the rule verified."
    },

    "corpus-5-bigint-reachable": {
      "steps": [
        {
          "step": 1,
          "description": "admit branch-reachability claim payload (subject=\"branch:then@115\", kind=branch_reachable, unionArms=null, claimedArms=null) -> id B",
          "state": { "pool": ["B"], "edges": [] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/scenarios.js", "lines": [541, 545] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "no producer registers a rule connecting a branch:then presupposition payload to any reachability-evidence payload -- the minimal producer set from §2.2 (colon-self-nonnil-v1, never-reassigned-nonnil) has no rule whose check() accepts this payload shape. No submit() call targets B at all",
          "state": { "edges": [] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [284, 294] }
          ],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "close(pool): B has zero incoming edges -> Open by definition of the fixpoint (unreached ids default Open)",
          "state": { "verdicts": { "B": "open" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [185, 196] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "open",
      "verdictNote": "doc states this outcome itself (§3.1 item 5): correctly Open, with a receipt naming which rule is missing rather than a generic 'Hole H1' citation."
    },

    "adversarial-subtract-false-proved": {
      "steps": [
        {
          "step": 1,
          "description": "admit deref-claim payload (subject=self, claimedArms=[Cache]) -> id A; admit colon-def payload (form=colon, receiver_param=self) -> id D. Identical payload shape to corpus-1 -- the payload carries no field recording that a real counterexample call (Cache.peek(nil,key)) exists, because no producer in the minimal set mines call sites at all",
          "state": { "pool": ["A", "D"], "edges": [] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/scenarios.js", "lines": [603, 619] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "submit zero-premise axiom edge for D -> D Proved (same as corpus-1)",
          "state": { "verdicts": { "D": "proved" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [248, 257] }
          ],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "submit colon-self-nonnil-v1 edge: premises={D}, target=A, supports. check() inspects only def.form, def.receiver_param, target.claimedArms/unionArms -- it has no parameter carrying call-site information, so it cannot see the counterexampleCall fact even though it exists in this scenario's ground truth. check() returns true exactly as in corpus-1; acyclic; edge admitted",
          "state": { "edges": ["colon-self-nonnil-v1(D)->A +"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [59, 70] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [211, 246] }
          ],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "close(pool): D Proved -> A Proved. This is a false Proved: the rule established only 'defined with colon sugar', a weaker fact than 'self is non-nil at every call', and the design's re-execution guarantee (kill-test 2, §3.2) only re-runs THIS check faithfully -- it cannot detect that the check's logic itself doesn't address the actual claim",
          "state": { "verdicts": { "A": "proved (false)" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [185, 196] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [344, 359] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "false proved as written -- the design's own §4 names this exact limit (rule honesty is not kernel-checkable); re-execution guarantees the check ran faithfully, not that the check's logic is sound."
    },

    "adversarial-saturation-b-identity-merge": {
      "steps": [
        {
          "step": 1,
          "description": "admit factA's payloads (colon-def DA, deref-claim CA for Cache:peek/self) and factB's payloads (colon-def DB, deref-claim CB for Deque:pop_front/self) as four independent pool ids -- subtract's Pool has no notion of two payloads sharing an identity",
          "state": { "pool": ["DA", "CA", "DB", "CB"], "edges": [] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/scenarios.js", "lines": [749, 821] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [142, 168] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "submit axiom edges for DA and DB (each independently Proved), then submit colon-self-nonnil-v1(DA)->CA and colon-self-nonnil-v1(DB)->CB as two separate, non-interacting submit() calls -- the kernel interface has no merge/union/rewrite operation anywhere in admit/payload/submit/close, so there is no mechanism by which CA and CB could become the same id or share a verdict",
          "state": { "edges": ["axiom(DA)+", "axiom(DB)+", "rule(DA)->CA +", "rule(DB)->CB +"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [142, 196] }
          ],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "close(pool): CA Proved (falsely -- same root cause as adversarial-subtract-false-proved: rule never inspects call sites, real counterexample Cache.peek(nil,key) invisible to it); CB Proved (genuinely -- no counterexample for Deque:pop_front). The two verdicts are computed independently; nothing about CB's true derivation touches CA's edge set or vice versa",
          "state": { "verdicts": { "CA": "proved (false)", "CB": "proved (true)" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [185, 196] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "both CA and CB independently resolve Proved with no interaction between them -- subtract's Pool/Edge model has no merge/rewrite primitive at all (confirmed against the §2.1 interface: admit/payload/submit/close, nothing else), so the identity-merge amplification this scenario is built to test does not apply to this design; CA's Proved is still false, on its own, for the same reason as the prior scenario -- an ordinary (non-amplified) instance of the same rule-honesty gap."
    },

    "hand-json-type-guard": {
      "steps": [
        {
          "step": 1,
          "description": "admit type_guard evidence payload (boundFrom=type(val), establishesArms=[number]) -> id E; admit claim payload (subject=val, claimedArms=[number], unionArms=8 Lua types) -> id C",
          "state": { "pool": ["E", "C"], "edges": [] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/scenarios.js", "lines": [933, 947] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "submit a zero-premise axiom edge for E, by extension of the §2.2 pattern (a rule asserting the type-guard fact was read correctly off the parse tree). The doc never discusses type-guard evidence or an 'arm-subset-entailment' rule shape anywhere -- this whole rule family is outside anything subtract.md walks through; applying the axiom pattern here is a reading extended from the one worked example, not something the doc itself states for this shape",
          "state": { "edges": ["axiom(E)+ (assumed)"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [248, 257] }
          ],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "submit arm-subset-entailment-v1 edge: premises={E}, target=C, supports. check(): isSubset(ev.establishesArms, target.claimedArms) = isSubset([number],[number]) = true; acyclic; edge admitted. This is a generic rule shape the doc's §1.1 claims the kernel can run ('as rich or as thin as' the producer likes) but never itself instantiates as arm-subset logic",
          "state": { "edges": ["arm-subset-entailment-v1(E)->C +"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [40, 51] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [99, 108] }
          ],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "close(pool): E Proved (per step 2's assumed axiom) -> C Proved",
          "state": { "verdicts": { "C": "proved" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [185, 196] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "matches groundTruth=true; contingent on step 2's axiom edge, which is a reading extended from the one explicit worked example, not something the doc shows for this evidence shape."
    },

    "hand-bigint-err-arm": {
      "steps": [
        {
          "step": 1,
          "description": "for ret1-nil-arm: admit guard_return evidence (returnedForm=nil_literal, establishesArms=[nil]) -> id E1; admit claim (claimedArms=[nil]) -> id C1. For ret2-string-arm: admit guard_return evidence (returnedForm=string_concat_literal, establishesArms=[string]) -> id E2; admit claim (claimedArms=[string]) -> id C2",
          "state": { "pool": ["E1", "C1", "E2", "C2"], "edges": [] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/scenarios.js", "lines": [999, 1029] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "submit zero-premise axiom edges for E1 and E2 (same extended reading as hand-json-type-guard step 2 -- not shown in the doc for this evidence shape)",
          "state": { "edges": ["axiom(E1)+ (assumed)", "axiom(E2)+ (assumed)"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [248, 257] }
          ],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "submit arm-subset-entailment-v1(E1)->C1 supports: isSubset([nil],[nil])=true, edge admitted. submit arm-subset-entailment-v1(E2)->C2 supports: isSubset([string],[string])=true, edge admitted. Both acyclic",
          "state": { "edges": ["arm-subset(E1)->C1 +", "arm-subset(E2)->C2 +"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [40, 51] }
          ],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "close(pool): C1 Proved, C2 Proved",
          "state": { "verdicts": { "C1": "proved", "C2": "proved" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [185, 196] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "both claims proved, matching groundTruth=true for both; same axiom-step reading gap as hand-json-type-guard."
    },

    "hand-lru-field-shape": {
      "steps": [
        {
          "step": 1,
          "description": "for map-table-arm: admit field_assign evidence (valueForm=table_literal, establishesArms=[table]) -> id E1; admit claim (claimedArms=[table]) -> id C1. For ttl-number-arm: admit field_assign evidence (valueForm=opt_expr, establishesArms=null) -> id E2; admit claim (claimedArms=[number]) -> id C2",
          "state": { "pool": ["E1", "C1", "E2", "C2"], "edges": [] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/scenarios.js", "lines": [1076, 1103] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "submit axiom edge for E1 (extended reading, as above) -> E1 Proved. submit arm-subset-entailment-v1(E1)->C1 supports: isSubset([table],[table])=true, acyclic, edge admitted -> close gives C1 Proved",
          "state": { "verdicts": { "E1": "proved", "C1": "proved" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [40, 51] }
          ],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "for E2 (opt_expr, establishesArms=null): no axiom question even arises, because arm-subset-entailment-v1's check() itself returns no-match whenever establishesArms is not an array (E2.establishesArms=null fails Array.isArray). submit arm-subset-entailment-v1(E2)->C2 supports: check() returns false. Per §2.1's submit() semantics ('only if check() returns true AND the acyclicity test passes does the edge get added'), no edge is added",
          "state": { "edges": ["arm-subset(E2)->C2 REJECTED"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [45, 50] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [178, 183] }
          ],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "close(pool): C2 has no incoming edge (none was ever added) -> Open by default. No rule ever asserts a refutes-edge either, so C2 does not become Refuted -- it stays Open",
          "state": { "verdicts": { "C1": "proved", "C2": "open" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [185, 196] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "open",
      "verdictNote": "map-table-arm (C1) resolves Proved, matching groundTruth=true. ttl-number-arm (C2), the scenario's actually-interesting claim (groundTruth=false, opts.ttl really is optional/nilable), correctly fails to prove -- the generic entailment rule's own no-match-on-null-establishesArms guard blocks it, landing at Open rather than Refuted since no refutation rule was ever registered."
    },

    "hand-lru-closure-upvalue": {
      "steps": [
        {
          "step": 1,
          "description": "for cache-upvalue-arm: admit upvalue_capture evidence (capturedFrom=self, reassignedInClosure=false, establishesArms=[Cache]) -> id E1; admit claim (claimedArms=[Cache]) -> id C1. For node-upvalue-arm: admit upvalue_capture evidence (capturedFrom=self._head, reassignedInClosure=true, establishesArms=null) -> id E2; admit claim (claimedArms=[LruNode]) -> id C2",
          "state": { "pool": ["E1", "C1", "E2", "C2"], "edges": [] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/scenarios.js", "lines": [1158, 1189] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "submit axiom edge for E1 (extended reading) -> E1 Proved; submit arm-subset-entailment-v1(E1)->C1 supports: isSubset([Cache],[Cache])=true, edge admitted",
          "state": { "verdicts": { "E1": "proved" }, "edges": ["arm-subset(E1)->C1 +"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [40, 51] }
          ],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "for E2 (establishesArms=null, because the upvalue is reassigned inside the closure and truly reaches nil at exhaustion): arm-subset-entailment-v1's check() returns no-match on a non-array establishesArms -- same guard as hand-lru-field-shape. submit(E2->C2) is rejected; no edge added",
          "state": { "edges": ["arm-subset(E2)->C2 REJECTED"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [45, 50] }
          ],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "close(pool): C1 Proved; C2 no incoming edge -> Open",
          "state": { "verdicts": { "C1": "proved", "C2": "open" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [185, 196] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "open",
      "verdictNote": "cache-upvalue-arm (C1) proved, matching groundTruth=true. node-upvalue-arm (C2), the scenario's interesting claim (groundTruth=false, node really does reach the nil arm on list exhaustion), correctly fails to prove and lands Open -- same mechanism as hand-lru-field-shape."
    },

    "hand-json-generic-for": {
      "steps": [
        {
          "step": 1,
          "description": "admit generic_for_protocol evidence (iterator=pairs, establishesArms=[boolean,number,string,table,function]) -> id E; admit claim (claimedArms= the same 5-element set) -> id C",
          "state": { "pool": ["E", "C"], "edges": [] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/scenarios.js", "lines": [1235, 1250] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "submit axiom edge for E (extended reading, as above) -> E Proved",
          "state": { "verdicts": { "E": "proved" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [248, 257] }
          ],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "submit arm-subset-entailment-v1(E)->C supports: isSubset(establishesArms, claimedArms) over identical 5-element sets = true; acyclic; edge admitted",
          "state": { "edges": ["arm-subset(E)->C +"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [40, 51] }
          ],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "close(pool): E Proved -> C Proved",
          "state": { "verdicts": { "C": "proved" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/subtract.md", "lines": [185, 196] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "matches groundTruth=true; same axiom-step reading gap as the other hand scenarios."
    }
  }
}
;
