// Auto-generated from primitive.json — do not hand-edit; regenerate from the .json if it changes.
window.TRACES = window.TRACES || {}; window.TRACES['primitive'] = {
  "design": "primitive",
  "provenance": "llm-abstract-eval",
  "scenarios": {
    "corpus-1-lru-self": {
      "steps": [
        {
          "step": 1,
          "description": "Pool built from the two sketched producers: axiom_colon_self.claim() and mined_deref_nonnil.obligation(site).",
          "state": { "pool": ["axiom_colon_self", "mined_deref_nonnil(site=lib/lru/init.lua:155:deref:self)"] },
          "codeSpans": [
            { "file": "candidates/primitive.md", "lines": [189, 203] },
            { "file": "candidates/primitive.md", "lines": [216, 227] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "Harvester builds binding_info from a static AST fact only (no concrete runtime value observed) -- same construction as the doc's own §2.4 wiring example: { via = 'colon_call_self', value = nil }.",
          "state": { "binding_info": { "via": "colon_call_self", "value": null } },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [251, 253] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "Witness source emits one witness { kind='binding', site, via='colon_call_self', value=nil }, then nil on the next call.",
          "state": { "witness": { "kind": "binding", "site": "lib/lru/init.lua:155:deref:self", "via": "colon_call_self", "value": null } },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [232, 239] }],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "find_disagreement draws w; axiom_colon_self.check(w): kind and via match -> 'accept'.",
          "state": { "ra": "accept" },
          "codeSpans": [
            { "file": "candidates/primitive.md", "lines": [189, 203] },
            { "file": "candidates/primitive.md", "lines": [114, 129] }
          ],
          "confidence": "determined"
        },
        {
          "step": 5,
          "description": "mined_deref_nonnil.obligation(site).check(w): kind/site match; the two value branches (`~= nil` / `== nil`) are exhaustive in Lua, so witness.value == nil (the only value Lua nil has, whether it means 'unrecorded' or 'actually nil') falls straight to 'reject'. The written 'return unknown' on the next line is dead code.",
          "state": { "rb": "reject" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [216, 227] }],
          "confidence": "determined"
        },
        {
          "step": 6,
          "description": "ra='accept', rb='reject' on the same witness w -> find_disagreement returns (w, accept, reject); check_pool records a Refuted finding {a=axiom, b=obligation, witness=w}. This contradicts §2.4's own prose, which claims obligation.check(w)='unknown' and 'findings is empty' for this exact wiring.",
          "state": { "findings": [{ "verdict": "Refuted", "a": "axiom_colon_self", "b": "mined_deref_nonnil", "witness": "w" }] },
          "codeSpans": [
            { "file": "candidates/primitive.md", "lines": [122, 126] },
            { "file": "candidates/primitive.md", "lines": [159, 163] },
            { "file": "candidates/primitive.md", "lines": [260, 263] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "refuted",
      "verdictNote": "False Refuted: the kernel disagrees with its own worked example. mined_deref_nonnil.check's two nil-branches are exhaustive over Lua's single nil value, so an 'unrecorded value' witness reads identically to an 'actually nil' witness and is rejected -- ground truth (self genuinely non-nil) says this should not be Refuted."
    },

    "corpus-2-json-hex": {
      "steps": [
        {
          "step": 1,
          "description": "No Lua code is given anywhere in primitive.md for the #2/#3 producers (mined_single_assignment, dataflow_scan_witness_source) -- only prose in §3.1 describing what their check/witnesses do. Reconstructing: obligation.check(witness) accepts iff witness.kind=='assignment_trace', name/scope match, #assignments==1, and an ordering condition holds.",
          "state": { "producer": "reconstructed from prose, not pasted code" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [300, 312] }],
          "confidence": "underdetermined"
        },
        {
          "step": 2,
          "description": "Gap: the prose's acceptance condition compares 'assignment event position' against 'deref event position', but the witness shape the same prose states -- {kind, name, scope, assignments} -- has no deref/use-position field for check to read. The doc's own description of this producer is internally inconsistent about what the witness carries.",
          "state": { "witnessShapeStated": ["kind", "name", "scope", "assignments"], "fieldNeededByCheck": "deref_position (unstated)" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [300, 312] }],
          "confidence": "unsure"
        },
        {
          "step": 3,
          "description": "Charitably assuming the ordering field exists (scenario ground truth: useIsAfterAssign=true, assignmentCount=1): witness w={kind:'assignment_trace', name:'HEX', scope:<file>, assignments:[1 item]}; obligation.check(w) -> 'accept', per §3.1's own claimed resolution.",
          "state": { "witness": { "kind": "assignment_trace", "name": "HEX", "assignments": 1 }, "obligationResult": "accept" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [300, 312] }],
          "confidence": "underdetermined"
        },
        {
          "step": 4,
          "description": "§3.1 describes a 'companion axiom-like general rule' playing the corroborating role 'via the same witness type it emits' -- it is not clear whether this is a genuinely second, independently-admitted claim object (as axiom/obligation were for #1) or the same check function narrated twice. §4's corroboration soundness argument explicitly requires the corroborating claim be independently admitted; this text does not clearly establish that here.",
          "state": { "secondClaim": "ambiguous -- same producer or distinct?" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [265, 276] }, { "file": "candidates/primitive.md", "lines": [397, 407] }],
          "confidence": "unsure"
        },
        {
          "step": 5,
          "description": "No pool member ever returns 'reject' on w (only 'accept'/'unknown' per step 3-4) -> find_disagreement finds nothing. Kernel.exhaust runs the single-witness source, observes it return nil after one witness -> closed=true. No disagreement occurred across that exhaustive run -> Proved via the plain disagreement-absence-plus-exhaustion path of §1.3 (corroboration not even needed here, since the obligation itself already returned 'accept', not 'unknown').",
          "state": { "exhausted": true, "findings": [] },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [71, 81] }, { "file": "candidates/primitive.md", "lines": [133, 147] }],
          "confidence": "underdetermined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Reaches Proved, but only via a mechanism reconstructed from prose (no pasted code exists for this producer, unlike #1); the prose itself is internally inconsistent about what field the ordering check reads, and it's unclear whether the 'corroborating' claim is genuinely independent of the obligation."
    },

    "corpus-3-queue-fifo": {
      "steps": [
        {
          "step": 1,
          "description": "Doc states this instance uses 'literally the same producer as #2, called with a different (name, scope) pair' -- same reconstructed mined_single_assignment(name='FIFO', scope) applies verbatim; same absence of pasted code.",
          "state": { "producer": "same as corpus-2, arg name='FIFO'" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [314, 321] }],
          "confidence": "underdetermined"
        },
        {
          "step": 2,
          "description": "Same internal gap as corpus-2 step 2: the check's stated ordering condition needs a deref-position field the stated witness shape doesn't carry.",
          "state": { "witnessShapeStated": ["kind", "name", "scope", "assignments"] },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [300, 312] }],
          "confidence": "unsure"
        },
        {
          "step": 3,
          "description": "Same reconstructed accept + single-witness-source-exhaustion path as corpus-2 (ground truth: useIsAfterAssign=true, assignmentCount=1) -> no disagreement, exhausted=true -> Proved.",
          "state": { "obligationResult": "accept", "exhausted": true },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [71, 81] }, { "file": "candidates/primitive.md", "lines": [133, 147] }],
          "confidence": "underdetermined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Identical mechanism and identical gaps to corpus-2 -- string-identical producer per the doc's own claim, so the same reconstruction and the same prose inconsistency apply."
    },

    "corpus-4-deque-self-x4": {
      "steps": [
        {
          "step": 1,
          "description": "Same two producers as corpus-1 (axiom_colon_self, mined_deref_nonnil), invoked 4 times by a harvester loop that already walks every deref, once per useLine (62,63,64,65). Doc: 'zero new code'.",
          "state": { "pool_per_site": ["axiom_colon_self", "mined_deref_nonnil(site_i)"], "sites": [62, 63, 64, 65] },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [294, 299] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "For each site, harvester again has no concrete runtime value (purely structural via-fact, same as corpus-1) -> binding_info_i = { via='colon_call_self', value=nil }, for i in the four sites.",
          "state": { "binding_info_i": { "via": "colon_call_self", "value": null } },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [251, 253] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "For each site's witness w_i, axiom_colon_self.check(w_i) -> 'accept' (via matches, unconditionally of site).",
          "state": { "ra_i": "accept (all 4 sites)" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [189, 203] }],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "For each site's witness w_i, mined_deref_nonnil.obligation(site_i).check(w_i) hits the same exhaustive nil-branch bug as corpus-1's step 5 -> 'reject', at all 4 sites.",
          "state": { "rb_i": "reject (all 4 sites)" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [216, 227] }],
          "confidence": "determined"
        },
        {
          "step": 5,
          "description": "Disagreement found independently at each of the 4 sites -> 4 separate Refuted findings, one per site, from the single reused producer pair -- the same amplification the doc touts as a strength (one producer, four sites, zero new code) here reproduces the same bug four times instead.",
          "state": { "findings": [{ "site": 62, "verdict": "Refuted" }, { "site": 63, "verdict": "Refuted" }, { "site": 64, "verdict": "Refuted" }, { "site": 65, "verdict": "Refuted" }] },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [159, 166] }],
          "confidence": "determined"
        }
      ],
      "verdict": "refuted",
      "verdictNote": "Same false-Refuted bug as corpus-1, amplified x4 by the exact per-producer reuse the doc presents as the flagship payoff of this design."
    },

    "corpus-5-bigint-reachable": {
      "steps": [
        {
          "step": 1,
          "description": "Doc's own §3.1 explicitly states no producer sketched in this design supplies a branch-reachability witness source or obligation for this instance; a reachability_witness_source/obligation are described only as future producer work.",
          "state": { "pool": [], "reachabilityProducerExists": false },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [322, 333] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "With no claim in the pool for this subject and no witness source, check_pool has no pairs to evaluate and no findings are possible in either direction.",
          "state": { "findings": [] },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [152, 166] }],
          "confidence": "determined"
        }
      ],
      "verdict": "open",
      "verdictNote": "Doc is explicit and unambiguous: stays Open because no producer for branch-reachability exists yet in this design -- an acknowledged unbuilt-producer gap, not a kernel limitation."
    },

    "adversarial-subtract-false-proved": {
      "steps": [
        {
          "step": 1,
          "description": "Both sketched producers (axiom_colon_self, mined_deref_nonnil) only ever read definition-form facts (via=='colon_call_self') -- neither producer body references call sites, callers, or any dot-call-escape fact anywhere in the pasted code.",
          "state": { "callSiteAware": false },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [189, 203] }, { "file": "candidates/primitive.md", "lines": [216, 227] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "Harvester builds the SAME binding_info={via:'colon_call_self', value:nil} as corpus-1, regardless of calledOnlyViaColon being false here -- via is a static fact about the definition, unaffected by the real counterexample call Cache.peek(nil,key) existing.",
          "state": { "binding_info": { "via": "colon_call_self", "value": null } },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [251, 253] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "axiom_colon_self.check(w) -> 'accept', unconditionally -- it has no way to see the counterexample call because no witness field carries call-site information.",
          "state": { "ra": "accept" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [195, 198] }],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "mined_deref_nonnil.check(w) hits the same value/absent-conflation bug as corpus-1 -> 'reject'.",
          "state": { "rb": "reject" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [216, 227] }],
          "confidence": "determined"
        },
        {
          "step": 5,
          "description": "Disagreement found -> Refuted, coincidentally matching ground truth (not-Proved), but for the wrong reason: the finding is an artifact of the value-bug, not detection of the real counterexample call. No producer in this design ever constructs or checks a call-site witness at all.",
          "state": { "findings": [{ "verdict": "Refuted", "witness": "w" }] },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [159, 166] }],
          "confidence": "determined"
        }
      ],
      "verdict": "refuted",
      "verdictNote": "Refuted for the wrong reason -- an accidental value/absent-conflation bug, not detection of Cache.peek(nil,key). If that bug were fixed (check returning 'unknown' for unrecorded value, as intended), this same design would have no producer capable of ever surfacing the real counterexample, and would sit at Open or falsely accept instead."
    },

    "adversarial-saturation-b-identity-merge": {
      "steps": [
        {
          "step": 1,
          "description": "primitive.md's kernel has no merge, rewrite, or union-find mechanism anywhere -- check_pool (the entire pairwise-check loop) treats every claim object as independent; nothing in the pasted kernel code ever collapses two claims into one identity.",
          "state": { "mergeMechanismExists": false },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [151, 169] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "factA (Cache:peek, calledOnlyViaColon=false) is processed exactly as in adversarial-subtract-false-proved: same witness construction, same value-bug -> Refuted (wrong reason), independently of factB.",
          "state": { "factA_verdict": "Refuted (bug-driven)" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [216, 227] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "factB (Deque:pop_front, calledOnlyViaColon=true) is processed exactly as in corpus-4's per-site trace: same value-bug -> Refuted (wrong reason), independently of factA.",
          "state": { "factB_verdict": "Refuted (bug-driven)" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [216, 227] }],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "Because no merge mechanism exists, factA's and factB's findings never interact -- the identity-merge amplification this scenario is built to probe (one poisoned rewrite corrupting a second, genuine fact through a shared identity) has no attack surface in this design's kernel; both entries independently hit the same unrelated bug.",
          "state": { "sharedIdentity": false },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [151, 169] }],
          "confidence": "determined"
        }
      ],
      "verdict": "refuted",
      "verdictNote": "Both A and B independently Refuted by the same value/absent-conflation bug, with no interaction between them -- the identity-merge attack this scenario targets does not apply to a design with no merge/rewrite primitive at all."
    },

    "hand-json-type-guard": {
      "steps": [
        {
          "step": 1,
          "description": "primitive.md gives no producer for arm-subset/type-guard claims -- only producers.js's shared, cross-engine arm-subset-entailment-v1 rule exists (a two-valued 'supports'/'no-match' function), and primitive.md never states how a two-valued producer-rule result maps onto its own three-valued check vocabulary (accept/reject/unknown).",
          "state": { "mappingDefined": false },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [24, 28] }],
          "confidence": "unsure"
        },
        {
          "step": 2,
          "description": "Reading picked (scenario-local, not general): construct a claim whose check mirrors arm-subset-entailment-v1 -- witness w={kind:'arm_evidence', subject:'val', establishesArms:['number']}; claim.check(w): subject matches, isSubset(['number'],['number']) holds -> 'accept'.",
          "state": { "witness": { "subject": "val", "establishesArms": ["number"] }, "result": "accept" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [30, 35] }],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "Pool has exactly one claim -- there is no independently-admitted second claim over 'val' to corroborate against, so §1.3's corroboration path is structurally unavailable here regardless of its soundness; the only route to Proved is the plain disagreement-absence-plus-exhaustion path.",
          "state": { "pool_size": 1, "corroborationAvailable": false },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [71, 81] }],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "Single-witness source returns w then nil; Kernel.exhaust observes termination -> closed=true; no disagreement possible (no second claim) -> Proved.",
          "state": { "exhausted": true, "findings": [] },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [133, 147] }],
          "confidence": "underdetermined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Reaches Proved, but only via a claim-check I constructed myself (no arm-subset producer exists in primitive.md's own vocabulary), and only because corroboration wasn't needed here (pool size 1) -- the deeper accept/reject/unknown mapping question this exposes is left unresolved by the doc."
    },

    "hand-bigint-err-arm": {
      "steps": [
        {
          "step": 1,
          "description": "Two claims (ret1-nil-arm, ret2-string-arm), different subjects, same constructed arm-subset check as hand-json-type-guard -- same unresolved two-valued/three-valued mapping question applies to both.",
          "state": { "pool": ["ret1-nil-arm", "ret2-string-arm"] },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [30, 35] }],
          "confidence": "underdetermined"
        },
        {
          "step": 2,
          "description": "find_disagreement across the pair: each claim's check rejects unrecognized subjects as 'unknown' (per the shape-recognition convention -- unrecognized/mismatched shape must answer unknown, never error or guess), so claim1.check(witness2) and claim2.check(witness1) both return 'unknown' -- no disagreement, ever, between these two.",
          "state": { "cross_check": "unknown/unknown" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [30, 35] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "ret1-nil-arm's own witness w1={subject:'M.new return#1...', establishesArms:['nil']}: isSubset(['nil'],['nil']) -> accept; single-witness source exhausts -> Proved.",
          "state": { "claim1_verdict": "Proved" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [71, 81] }, { "file": "candidates/primitive.md", "lines": [133, 147] }],
          "confidence": "underdetermined"
        },
        {
          "step": 4,
          "description": "ret2-string-arm's own witness w2 similarly: establishesArms=['string'] subset of claimedArms=['string'] -> accept; exhausts -> Proved.",
          "state": { "claim2_verdict": "Proved" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [71, 81] }, { "file": "candidates/primitive.md", "lines": [133, 147] }],
          "confidence": "underdetermined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Both claims independently reach Proved via plain exhaustion (different subjects never meet, no corroboration involved) -- contingent on the same constructed-check gap flagged in hand-json-type-guard."
    },

    "hand-lru-field-shape": {
      "steps": [
        {
          "step": 1,
          "description": "Two claims: map-table-arm (groundTruth true, evidence.establishesArms=['table']) and ttl-number-arm (groundTruth false, evidence.establishesArms=null since opts.ttl is genuinely optional). Same constructed arm-subset check as prior hand scenarios.",
          "state": { "pool": ["map-table-arm", "ttl-number-arm"] },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [30, 35] }],
          "confidence": "underdetermined"
        },
        {
          "step": 2,
          "description": "map-table-arm: witness establishesArms=['table'] subset of claimedArms=['table'] -> accept; single-witness source exhausts -> Proved.",
          "state": { "map_verdict": "Proved" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [71, 81] }, { "file": "candidates/primitive.md", "lines": [133, 147] }],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "ttl-number-arm: evidence.establishesArms=null. producers.js's own entails() treats a non-array establishesArms as 'no-match' (not 'supports') -- reading this as primitive's 'unknown' (uninformative, nothing established) rather than 'reject' (nothing in the producer logic asserts an active contradiction). The doc does not decide this mapping; a 'reject' reading is equally defensible from the text given.",
          "state": { "witness": { "establishesArms": null }, "readingPicked": "unknown", "readingAlternative": "reject" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [30, 35] }],
          "confidence": "unsure"
        },
        {
          "step": 4,
          "description": "Under the 'unknown' reading: ttl claim's own check returns unknown; no independent second claim about Cache._ttl exists to corroborate, and nothing ever returns reject on it either -> stays Open (the false claim is not falsely proved, but this rests entirely on step 3's picked reading).",
          "state": { "ttl_verdict": "Open" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [71, 81] }],
          "confidence": "underdetermined"
        }
      ],
      "verdict": "open",
      "verdictNote": "map-table-arm reaches Proved; ttl-number-arm (the false claim) stays Open rather than being falsely Proved -- but only under one of two equally defensible readings of what a null establishesArms means in this design's three-valued vocabulary, which the doc never specifies."
    },

    "hand-lru-closure-upvalue": {
      "steps": [
        {
          "step": 1,
          "description": "Two claims: cache-upvalue-arm (groundTruth true, establishesArms=['Cache']) and node-upvalue-arm (groundTruth false -- node is reassigned in the closure and reaches nil at list exhaustion, but the claim wrongly excludes the nil arm; evidence.establishesArms=null). Same constructed arm-subset check as prior hand scenarios.",
          "state": { "pool": ["cache-upvalue-arm", "node-upvalue-arm"] },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [30, 35] }],
          "confidence": "underdetermined"
        },
        {
          "step": 2,
          "description": "cache-upvalue-arm: witness establishesArms=['Cache'] subset of claimedArms=['Cache'] -> accept; single-witness source exhausts -> Proved.",
          "state": { "cache_verdict": "Proved" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [71, 81] }, { "file": "candidates/primitive.md", "lines": [133, 147] }],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "node-upvalue-arm: evidence.establishesArms=null, same unresolved accept/reject/unknown mapping gap as hand-lru-field-shape step 3 -- picking 'unknown' again (not decided by the doc).",
          "state": { "witness": { "establishesArms": null }, "readingPicked": "unknown", "readingAlternative": "reject" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [30, 35] }],
          "confidence": "unsure"
        },
        {
          "step": 4,
          "description": "Under the 'unknown' reading: node claim's own check returns unknown; no corroborating or rejecting claim exists -> stays Open (false claim not falsely proved, contingent on step 3's picked reading).",
          "state": { "node_verdict": "Open" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [71, 81] }],
          "confidence": "underdetermined"
        }
      ],
      "verdict": "open",
      "verdictNote": "cache-upvalue-arm reaches Proved; node-upvalue-arm (the false claim, missing the nil arm reached at list exhaustion) stays Open rather than falsely Proved -- same contingent reading as hand-lru-field-shape."
    },

    "hand-json-generic-for": {
      "steps": [
        {
          "step": 1,
          "description": "Single claim (k-nonterminator-arms, groundTruth true); same constructed arm-subset check as prior hand scenarios.",
          "state": { "pool": ["k-nonterminator-arms"] },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [30, 35] }],
          "confidence": "underdetermined"
        },
        {
          "step": 2,
          "description": "witness establishesArms == claimedArms (both the full non-nil arm list) -> isSubset holds trivially -> 'accept'.",
          "state": { "result": "accept" },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [30, 35] }],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "Single-witness source exhausts (returns nil after the one witness); no second claim exists to disagree -> Proved via plain disagreement-absence-plus-exhaustion.",
          "state": { "exhausted": true, "findings": [] },
          "codeSpans": [{ "file": "candidates/primitive.md", "lines": [71, 81] }, { "file": "candidates/primitive.md", "lines": [133, 147] }],
          "confidence": "underdetermined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Straightforward Proved via plain exhaustion, contingent on the same constructed arm-subset check as the other hand scenarios (no such producer exists in primitive.md's own vocabulary)."
    }
  }
}
;
