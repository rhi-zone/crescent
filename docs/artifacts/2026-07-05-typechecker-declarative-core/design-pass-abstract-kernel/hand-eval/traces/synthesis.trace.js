// Auto-generated from synthesis.json — do not hand-edit; regenerate from the .json if it changes.
window.TRACES = window.TRACES || {}; window.TRACES['synthesis'] = {
  "design": "synthesis",
  "provenance": "llm-abstract-eval",
  "scenarios": {
    "corpus-1-lru-self": {
      "steps": [
        {
          "step": 1,
          "description": "admit(pool, claim{self, unionArms:[Cache,nil], claimedArms:[Cache]}, admit_mined) mints id_claim; kernel tags provenance='mined' (scenario.provenance='mined' maps cleanly onto the mined entrypoint).",
          "state": { "pool": ["id_claim(mined)"] },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [152, 159] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "admit(pool, def-site fact{form:colon, receiver_param:self}, admit_mined) mints id_def alongside id_claim.",
          "state": { "pool": ["id_claim(mined)", "id_def(mined)"] },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [154, 154] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "submit(colon-self-nonnil-v1, {id_def}, id_claim, supports) check 1 (type-shape, delta 7): premise_types/target_type narrowing is named in synthesis.md itself as 'real, currently unbuilt typechecker substrate' (not yet designed in Lua). Treated here as passing vacuously since no shape mismatch is present in this payload -- there is no built mechanism to actually run.",
          "state": { "submit": "shape-check: vacuous-pass (mechanism unbuilt)" },
          "codeSpans": [],
          "confidence": "underdetermined"
        },
        {
          "step": 4,
          "description": "submit check 2 (acyclicity, bounded DFS from id_claim through {id_def}): id_def has no path back to id_claim -- passes.",
          "state": { "submit": "acyclicity: pass" },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 5,
          "description": "submit check 3 (strength admissibility) requires rule.strength. producers.js's colon-self-nonnil-v1 carries no strength field; reading adopted (matching this scenario's own synthesis note language 'universal claim, evidence cited = definition-site fact only'): rule declares strength='universal'.",
          "state": { "rule.strength": "universal (picked reading)" },
          "codeSpans": [],
          "confidence": "underdetermined"
        },
        {
          "step": 6,
          "description": "Same check, second half: id_def is a bare admitted fact with no prior submit/edge of its own, hence no strength tag to compare against a 'universal use'. synthesis.md defines the check only in terms of 'that premise's own currently-accepted edge' -- it does not say what happens when the cited premise has never been the target of any edge at all. Read here as a vacuous pass (nothing to violate).",
          "state": { "leaf-premise strength check": "vacuous-pass (picked reading)" },
          "codeSpans": [],
          "confidence": "unsure"
        },
        {
          "step": 7,
          "description": "submit check 4: sandboxed re-execution of colon-self-nonnil-v1.check({id_def: PremiseView}, id_claim: PremiseView) under fuel, no ambient pool access. Per producers.js entails(): form==colon && receiver_param==subject && setEq(claimedArms, unionArms-nil) -> returns 'supports'.",
          "state": { "check()": "supports" },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 8,
          "description": "submit check 5: verdict is 'supports' (not 'unknown') -> edge added: id_claim <-supports,universal- id_def.",
          "state": { "edges": ["id_claim <-supports,universal- id_def"] },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 9,
          "description": "close(): id_claim's only edge is universal-strength supports -> fixpoint promotes id_claim to proved_claim.",
          "state": { "verdicts": { "id_claim": "proved_claim" } },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Ground truth here is calledOnlyViaColon=true (no counterexample in this corpus) so proved_claim matches reality -- but for the wrong reason: the same rule mints an identical proved_claim in adversarial-subtract-false-proved where ground truth is false. synthesis.md's own §6 row 1 names this rule-honesty gap OPEN, by design."
    },

    "corpus-2-json-hex": {
      "steps": [
        {
          "step": 1,
          "description": "admit(pool, claim{HEX, unionArms:[table,nil], claimedArms:[table]}, admit_mined) mints id_claim.",
          "state": { "pool": ["id_claim(mined)"] },
          "codeSpans": [{ "file": "lib/json/init.lua", "lines": [27, 33] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "admit(pool, assignment fact{assignment_count:1, initial_value_kind:table}, admit_mined) mints id_assign.",
          "state": { "pool": ["id_claim(mined)", "id_assign(mined)"] },
          "codeSpans": [{ "file": "lib/json/init.lua", "lines": [28, 28] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "submit(never-reassigned-nonnil, {id_assign}, id_claim, supports): shape-check treated as vacuous-pass (delta 7 unbuilt, same as corpus-1); acyclicity passes (no cycle).",
          "state": { "submit": "shape-check vacuous-pass; acyclicity pass" },
          "codeSpans": [],
          "confidence": "underdetermined"
        },
        {
          "step": 4,
          "description": "strength admissibility: rule carries no strength field in producers.js. Reading adopted for uniformity with corpus-1 (a 'never reassigned' guarantee is meant to hold at every future dereference, structurally the same shape of claim as colon-self-nonnil): strength='universal'. Leaf-premise (id_assign) has no prior edge -- vacuous pass, same unresolved question as corpus-1 step 6.",
          "state": { "rule.strength": "universal (picked reading)" },
          "codeSpans": [],
          "confidence": "underdetermined"
        },
        {
          "step": 5,
          "description": "sandboxed check(): assignment_count==1 && initial_value_kind=='table' && name==subject -> 'supports'. Note: this rule structurally never checks control-flow ordering between assignment and dereference (subtract-attack.md Attack 4's disclosed gap, restated verbatim in producers.js's comment) -- not exercised in this scenario since useIsAfterAssign=true.",
          "state": { "check()": "supports" },
          "codeSpans": [{ "file": "lib/json/init.lua", "lines": [101, 133] }],
          "confidence": "determined"
        },
        {
          "step": 6,
          "description": "edge added: id_claim <-supports,universal- id_assign. close(): fixpoint promotes id_claim to proved_claim.",
          "state": { "verdicts": { "id_claim": "proved_claim" } },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "useIsAfterAssign=true so the disclosed ordering/dominance gap isn't exercised; ground truth is true and proved_claim matches it here, but the gap remains latent (same rule would falsely fire if use preceded assignment in control flow, which this design has no mechanism to check)."
    },

    "corpus-3-queue-fifo": {
      "steps": [
        {
          "step": 1,
          "description": "Identical shape to corpus-2: admit claim{FIFO, unionArms:[table,nil], claimedArms:[table]} and assignment fact, both admit_mined.",
          "state": { "pool": ["id_claim(mined)", "id_assign(mined)"] },
          "codeSpans": [{ "file": "lib/queue/init.lua", "lines": [152, 169] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "submit(never-reassigned-nonnil, ...): shape-check vacuous-pass, acyclicity pass, strength read as universal (same picked reading as corpus-2, same unresolved leaf-premise question).",
          "state": { "submit": "shape-check vacuous-pass; acyclicity pass; strength=universal (picked)" },
          "codeSpans": [],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "check() returns 'supports' (assignment_count==1, kind==table, name matches). Same disclosed ordering gap as corpus-2, not exercised here.",
          "state": { "check()": "supports" },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "edge added, close() promotes id_claim to proved_claim.",
          "state": { "verdicts": { "id_claim": "proved_claim" } },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Same shape and same caveat as corpus-2: ordering/dominance gap latent, not exercised because use is control-flow-after assignment in this instance."
    },

    "corpus-4-deque-self-x4": {
      "steps": [
        {
          "step": 1,
          "description": "admit(pool, claim{self, unionArms:[Deque,nil], claimedArms:[Deque]}, admit_mined) mints id_def (one def site) and 4 target claim ids id_c1..id_c4, one per use line (62,63,64,65).",
          "state": { "pool": ["id_def(mined)", "id_c1..id_c4(mined)"] },
          "codeSpans": [{ "file": "lib/deque/init.lua", "lines": [56, 67] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "One rule registration (colon-self-nonnil-v1) is submitted 4 times: submit(rule, {id_def}, id_c_k, supports) for k=1..4 -- 'one rule registration, reused... against as many targets as a producer names', per synthesis's own note on this scenario.",
          "state": { "submit calls": 4 },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "Each of the 4 submissions independently passes shape-check (vacuous-pass, delta 7 unbuilt) and acyclicity (each id_c_k has only id_def as premise, no cycle).",
          "state": { "submit": "shape-check vacuous-pass x4; acyclicity pass x4" },
          "codeSpans": [],
          "confidence": "underdetermined"
        },
        {
          "step": 4,
          "description": "Strength read as universal (same picked reading as corpus-1, same rule); leaf-premise id_def has no prior edge -- same vacuous-pass reading, unresolved by synthesis.md, applied identically 4 times.",
          "state": { "rule.strength": "universal (picked reading) x4" },
          "codeSpans": [],
          "confidence": "underdetermined"
        },
        {
          "step": 5,
          "description": "check() returns 'supports' identically at all 4 call sites (same def.form/receiver_param inputs each time) -> 4 edges added, each universal-strength.",
          "state": { "edges": ["id_c1<-supports,universal-id_def", "...", "id_c4<-supports,universal-id_def"] },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 6,
          "description": "close(): all 4 targets promoted to proved_claim.",
          "state": { "verdicts": { "id_c1": "proved_claim", "id_c2": "proved_claim", "id_c3": "proved_claim", "id_c4": "proved_claim" } },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "calledOnlyViaColon=true here so all 4 proved_claim outcomes match ground truth. synthesis's own note names the blast-radius risk directly: one wrong rule registration would have produced false Proved at all 4 sites simultaneously (as it does in the adversarial scenario using the identical rule)."
    },

    "corpus-5-bigint-reachable": {
      "steps": [
        {
          "step": 1,
          "description": "admit(pool, claim{subject:'branch:then@115', kind:branch_reachable, unionArms:null, claimedArms:null}, admit_mined) mints id_claim.",
          "state": { "pool": ["id_claim(mined)"] },
          "codeSpans": [{ "file": "lib/bigint/init.lua", "lines": [97, 121] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "No submit is possible: producers.js's PRODUCER_RULES contains exactly 3 rules (arm-subset-entailment-v1, colon-self-nonnil-v1, never-reassigned-nonnil), all of which require Array.isArray(claimedArms)/unionArms or a colon/def-form/assignment shape. This claim's claimedArms/unionArms are null and it has no def-form or assignment fact -- every rule.entails would reject before reaching kernel submit at all. facts.noRuleAvailable=true confirms this directly. No edge is ever submitted for id_claim.",
          "state": { "edges submitted for id_claim": 0 },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "close(): id_claim has zero accepted edges, ever. synthesis.md describes what happens to promote an id PAST open (via edges) but never states the base-case verdict tag for an id with no edges submitted at all -- 'open' is the only remaining tag in the Verdict enum, so this is the only fit, but the doc never says it explicitly for the zero-edge case.",
          "state": { "verdicts": { "id_claim": "open (only remaining enum value, not explicitly stated for zero-edge case)" } },
          "codeSpans": [],
          "confidence": "unsure"
        }
      ],
      "verdict": "open",
      "verdictNote": "No producer rule in this corpus's fixed rule set targets branch-reachability claims at all; the kernel correctly withholds a verdict rather than guessing, matching §2.2's own listing of 'reachability analysis' as unbuilt producer-side scope -- consistent with the known 100%-Open status of this corpus instance."
    },

    "adversarial-subtract-false-proved": {
      "steps": [
        {
          "step": 1,
          "description": "admit(pool, claim{self, unionArms:[Cache,nil], claimedArms:[Cache]}, admit_stated or admit_mined) mints id_claim; admit def-site fact mints id_def. scenario.provenance='constructed' -- this label (a hand-eval bookkeeping category for 'built from a judgments/candidates finding') has no direct counterpart among the kernel's exactly-three entrypoints (stated/axiom/mined). Read here as admit_mined since the underlying fact (colon-defined method, real corpus code) would be harvested the same way as corpus-1's identical code.",
          "state": { "pool": ["id_claim(mined, picked)", "id_def(mined, picked)"] },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [152, 159] }],
          "confidence": "underdetermined"
        },
        {
          "step": 2,
          "description": "submit(colon-self-nonnil-v1, {id_def}, id_claim, supports): identical rule, identical def.form/receiver_param/claim inputs as corpus-1 -- the premises_view the sandboxed check() receives carries no call-site information at all (only what the producer chose to submit as premises, and this producer never submits a call-site fact). Shape-check vacuous-pass, acyclicity pass, strength read as universal (same reading as corpus-1), leaf-premise vacuous-pass -- all identical to corpus-1 steps 3-6.",
          "state": { "submit": "identical to corpus-1's steps 3-6" },
          "codeSpans": [],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "check() executes the exact same code path as corpus-1 on the exact same (def.form, receiver_param, claim) inputs -> returns 'supports', identically, regardless of the real counterexample call Cache.peek(nil, key) existing elsewhere in this scenario's ground truth -- that counterexample was never made visible to check() because it was never admitted as a premise by the producer.",
          "state": { "check()": "supports" },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "edge added: id_claim <-supports,universal- id_def. close(): fixpoint promotes id_claim to proved_claim.",
          "state": { "verdicts": { "id_claim": "proved_claim" } },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "refuted",
      "verdictNote": "Ground truth here has a real counterexample (Cache.peek(nil, key)) -- self is NOT universally non-nil. The design mints proved_claim anyway. synthesis.md's own §6 row 1 names this path explicitly: 'OPEN, by design -- rule-honesty is kernel-unverifiable in principle... cannot verify the rule's logic itself,' i.e. the design itself, in its own text, concedes this exact false-Proved is not closed."
    },

    "adversarial-saturation-b-identity-merge": {
      "steps": [
        {
          "step": 1,
          "description": "admit(pool, factA-claim{Cache:peek self, unionArms:[Cache,nil], claimedArms:[Cache]}, mined-picked) mints id_A; admit(pool, factB-claim{Deque:pop_front self, unionArms:[Deque,nil], claimedArms:[Deque]}, mined-picked) mints id_B, as two entirely independent pool entries.",
          "state": { "pool": ["id_A(mined,picked)", "id_B(mined,picked)"] },
          "codeSpans": [
            { "file": "lib/lru/init.lua", "lines": [152, 159] },
            { "file": "lib/deque/init.lua", "lines": [56, 67] }
          ],
          "confidence": "underdetermined"
        },
        {
          "step": 2,
          "description": "submit(colon-self-nonnil-v1, {id_defA}, id_A, supports) and submit(colon-self-nonnil-v1, {id_defB}, id_B, supports) run as two fully separate submissions. synthesis's Pool/Edge model (this scenario's own synthesis note states directly) 'never adopted any term-rewriting/merge mechanism' -- there is no operation anywhere in §2's interface sketch that collapses two distinct ids into one identity. id_A and id_B remain distinct throughout every step, with no shared state between their edge sets.",
          "state": { "submit": "id_A and id_B: fully independent edge sets, no merge primitive exists" },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "check() on id_A returns 'supports' via the same definition-site-only logic as adversarial-subtract-false-proved (identical code/rule) -- edge added, universal strength (picked reading). check() on id_B returns 'supports' via the same logic as corpus-4 (identical code/rule, true ground truth) -- edge added, universal strength (picked reading).",
          "state": { "edges": ["id_A<-supports,universal-id_defA", "id_B<-supports,universal-id_defB"] },
          "codeSpans": [],
          "confidence": "underdetermined"
        },
        {
          "step": 4,
          "description": "close(): id_A -> proved_claim (false: A has a real counterexample, same unclosed rule-honesty gap as the single-fact adversarial scenario, not new here). id_B -> proved_claim (true). Because no merge/rewrite mechanism exists, B's genuine 'supports' verdict is never read back onto A's identity -- the saturation-B-specific amplification mechanism (a single shared term-store entry) has no counterpart in this Pool/Edge design.",
          "state": { "verdicts": { "id_A": "proved_claim (false, independent of any merge)", "id_B": "proved_claim (true)" } },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "The scenario's specific question is whether an identity-merge amplification (saturation-B's failure mode) applies here -- it structurally cannot, since synthesis has no rewrite/merge primitive at all; A and B stay distinct ids/edges throughout. A still independently reproduces the ordinary (non-merge) false-Proved from adversarial-subtract-false-proved, which is a pre-existing open gap, not new amplification."
    },

    "hand-json-type-guard": {
      "steps": [
        {
          "step": 1,
          "description": "admit(pool, claim{val, unionArms:[nil,boolean,number,string,table,function,userdata,thread], claimedArms:[number]}, ???) mints id_claim. scenario.provenance='hand' ('hand-derived... admissibility waived by owner') has no counterpart among the kernel's three entrypoints (stated/axiom/mined) -- none of the three descriptions ('declared by producer', 'axiom catalog', 'machine-harvested') obviously fits an auditor's hand-derived claim over real code with waived admissibility. Read here as admit_stated (closest fit: a directly-asserted fact, not machine-harvested and not a built-in axiom), but the doc gives no basis to prefer this over admit_axiom.",
          "state": { "pool": ["id_claim(stated, picked)"] },
          "codeSpans": [{ "file": "lib/json/init.lua", "lines": [406, 428] }],
          "confidence": "unsure"
        },
        {
          "step": 2,
          "description": "admit(pool, evidence{kind:type_guard, guardVar:t, boundFrom:'type(val)', establishesArms:[number]}, same picked entrypoint) mints id_ev.",
          "state": { "pool": ["id_claim(stated,picked)", "id_ev(stated,picked)"] },
          "codeSpans": [{ "file": "lib/json/init.lua", "lines": [408, 415] }],
          "confidence": "unsure"
        },
        {
          "step": 3,
          "description": "submit(arm-subset-entailment-v1, {id_ev}, id_claim, supports): shape-check vacuous-pass (delta 7 unbuilt), acyclicity pass.",
          "state": { "submit": "shape-check vacuous-pass; acyclicity pass" },
          "codeSpans": [],
          "confidence": "underdetermined"
        },
        {
          "step": 4,
          "description": "Strength admissibility: this claim is a single, statically-located fact at one program point (line 416), not a claim reused across multiple call/use sites the way colon-self-nonnil or never-reassigned-nonnil are. synthesis.md's strength axis is motivated specifically by hypothesis-discharge across reused claims (invert Attack 2); it gives no criterion for classifying a one-off local narrowing fact as existential vs universal. Read here (uniformly with all other scenarios in this trace) as universal, but this is a genuine gap: the doc supplies no rule to decide this case.",
          "state": { "rule.strength": "universal (picked, doc silent on criterion)" },
          "codeSpans": [],
          "confidence": "unsure"
        },
        {
          "step": 5,
          "description": "sandboxed check(): arm-subset-entailment-v1.entails(ev, c) -- ev.subject undefined vs c.subject undefined (both, per producers.js's guard, skips the subject-mismatch check), isSubset(establishesArms=[number], claimedArms=[number]) -> true -> 'supports'.",
          "state": { "check()": "supports" },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 6,
          "description": "edge added: id_claim <-supports,universal- id_ev. close(): id_claim promoted to proved_claim.",
          "state": { "verdicts": { "id_claim": "proved_claim" } },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "groundTruth=true and the design reaches proved_claim; the arm-subset entailment machinery works mechanically as intended for a straightforward type-guard-derived fact, though the provenance-entrypoint choice and the strength-axis applicability to single-site facts are both unresolved by the doc."
    },

    "hand-bigint-err-arm": {
      "steps": [
        {
          "step": 1,
          "description": "admit two claims (ret1-nil-arm: subject 'M.new return#1', claimedArms:[nil]; ret2-string-arm: subject 'M.new return#2', claimedArms:[string]) and one shared guard_return evidence fact, all via a picked entrypoint (same unresolved 'hand' provenance mapping as hand-json-type-guard).",
          "state": { "pool": ["id_c1(picked)", "id_c2(picked)", "id_ev(picked)"] },
          "codeSpans": [{ "file": "lib/bigint/init.lua", "lines": [291, 308] }],
          "confidence": "unsure"
        },
        {
          "step": 2,
          "description": "submit(arm-subset-entailment-v1, {id_ev}, id_c1, supports) and submit(arm-subset-entailment-v1, {id_ev}, id_c2, supports): shape-check vacuous-pass, acyclicity pass for both (independent targets sharing one evidence premise -- no cycle either way).",
          "state": { "submit": "both pass shape/acyclicity" },
          "codeSpans": [],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "Strength read as universal for both (same unresolved single-site-strength gap as hand-json-type-guard, applied uniformly).",
          "state": { "rule.strength": "universal (picked) x2" },
          "codeSpans": [],
          "confidence": "unsure"
        },
        {
          "step": 4,
          "description": "check() for id_c1: isSubset(establishesArms=[nil], claimedArms=[nil]) -> 'supports'. check() for id_c2: isSubset(establishesArms=[string], claimedArms=[string]) -> 'supports'.",
          "state": { "check(id_c1)": "supports", "check(id_c2)": "supports" },
          "codeSpans": [{ "file": "lib/bigint/init.lua", "lines": [304, 306] }],
          "confidence": "determined"
        },
        {
          "step": 5,
          "description": "Both edges added; close() promotes id_c1 and id_c2 to proved_claim.",
          "state": { "verdicts": { "id_c1": "proved_claim", "id_c2": "proved_claim" } },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Both claims' groundTruth=true and both reach proved_claim -- matches expected outcome, with the same unresolved provenance-entrypoint and strength-axis caveats noted above."
    },

    "hand-lru-field-shape": {
      "steps": [
        {
          "step": 1,
          "description": "admit claim map-table-arm (claimedArms:[table], groundTruth=true) with evidence{establishesArms:[table]}, and claim ttl-number-arm (claimedArms:[number], groundTruth=false) with evidence{establishesArms:null} -- all via a picked entrypoint (same unresolved 'hand' mapping).",
          "state": { "pool": ["id_map(picked)", "id_ev_map(picked)", "id_ttl(picked)", "id_ev_ttl(picked)"] },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [77, 101] }],
          "confidence": "unsure"
        },
        {
          "step": 2,
          "description": "submit(arm-subset-entailment-v1, {id_ev_map}, id_map, supports): shape/acyclicity pass; check(): isSubset([table],[table]) -> 'supports' -> edge added, strength read as universal (picked). close(): id_map -> proved_claim.",
          "state": { "verdicts": { "id_map": "proved_claim" } },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [91, 91] }],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "submit(arm-subset-entailment-v1, {id_ev_ttl}, id_ttl, supports): per producers.js's entails(), 'if (!ev || !Array.isArray(ev.establishesArms)) return \"no-match\"' -- establishesArms is null (not an array), so entails() returns 'no-match'. producers.js's own vocabulary ('no-match') is not one of the kernel's three CheckVerdict values; the only sensible mapping is no-match -> 'unknown' (it is neither supports nor refutes). synthesis.md itself never defines this producer-vocabulary-to-CheckVerdict adaptation since producers.js predates the three-valued enum, but 'unknown' is the only value left once supports/refutes are ruled out.",
          "state": { "check(id_ttl)": "no-match -> mapped to unknown" },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [94, 94] }],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "Per delta 1 (kernel never adds an edge on 'unknown'), no edge is added for id_ttl. close(): id_ttl has zero edges -> open (same zero-edge base-case gap noted in corpus-5).",
          "state": { "verdicts": { "id_ttl": "open" } },
          "codeSpans": [],
          "confidence": "unsure"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Both outcomes match ground truth: map-table-arm (true) reaches proved_claim; ttl-number-arm (false -- opts.ttl really is optional/nilable) correctly never gets certified and stays open rather than being falsely proved. The design's non-guessing discipline (delta 1) does the correct thing here without any bespoke logic."
    },

    "hand-lru-closure-upvalue": {
      "steps": [
        {
          "step": 1,
          "description": "admit claim cache-upvalue-arm (claimedArms:[Cache], groundTruth=true, establishesArms:[Cache]) and claim node-upvalue-arm (claimedArms:[LruNode], groundTruth=false, establishesArms:null), via a picked entrypoint (same unresolved 'hand' mapping).",
          "state": { "pool": ["id_cache(picked)", "id_node(picked)"] },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [248, 264] }],
          "confidence": "unsure"
        },
        {
          "step": 2,
          "description": "submit for id_cache: shape/acyclicity pass, strength read as universal (picked); check(): isSubset([Cache],[Cache]) -> 'supports' -> edge added. close(): id_cache -> proved_claim.",
          "state": { "verdicts": { "id_cache": "proved_claim" } },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [252, 252] }],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "submit for id_node: evidence.establishesArms is null -> entails() 'no-match' -> mapped to 'unknown' (same forced mapping as hand-lru-field-shape step 3) -> no edge added. close(): id_node has zero edges -> open.",
          "state": { "verdicts": { "id_node": "open" } },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [253, 257] }],
          "confidence": "unsure"
        }
      ],
      "verdict": "proved",
      "verdictNote": "cache-upvalue-arm (true) reaches proved_claim; node-upvalue-arm (false -- node genuinely reaches the nil arm at list exhaustion, wrongly excluded by the claim) correctly stays uncertified rather than falsely proved. Same non-guessing discipline as hand-lru-field-shape."
    },

    "hand-json-generic-for": {
      "steps": [
        {
          "step": 1,
          "description": "admit claim k-nonterminator-arms (claimedArms:[boolean,number,string,table,function], groundTruth=true) and evidence{kind:generic_for_protocol, establishesArms:[boolean,number,string,table,function]}, via a picked entrypoint (same unresolved 'hand' mapping as prior hand scenarios).",
          "state": { "pool": ["id_claim(picked)", "id_ev(picked)"] },
          "codeSpans": [{ "file": "lib/json/init.lua", "lines": [429, 443] }],
          "confidence": "unsure"
        },
        {
          "step": 2,
          "description": "submit(arm-subset-entailment-v1, {id_ev}, id_claim, supports): shape/acyclicity pass; strength read as universal (picked, same unresolved single-site-strength gap as the other hand scenarios).",
          "state": { "submit": "shape/acyclicity pass; strength=universal (picked)" },
          "codeSpans": [],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "check(): isSubset(establishesArms, claimedArms) with both sets exactly [boolean,number,string,table,function] -> 'supports'. edge added; close(): id_claim -> proved_claim.",
          "state": { "verdicts": { "id_claim": "proved_claim" } },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "groundTruth=true, matches proved_claim -- straightforward arm-subset entailment over pairs()'s protocol guarantee, same unresolved provenance-entrypoint and single-site-strength caveats as the other hand scenarios."
    }
  }
}
;
