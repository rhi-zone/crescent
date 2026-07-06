// Auto-generated from saturation-a.json — do not hand-edit; regenerate from the .json if it changes.
window.TRACES = window.TRACES || {}; window.TRACES['saturation-a'] = {
  "design": "saturation-a",
  "provenance": "llm-abstract-eval",
  "scenarios": {
    "corpus-1-lru-self": {
      "steps": [
        {
          "step": 1,
          "description": "admit ground facts from harvester: def_form(F,colon), receiver_param(F,self), deref_site(F,self) for Cache:peek; F0 = {these 3 atoms}",
          "state": { "store": ["def_form(peek,colon)", "receiver_param(peek,self)", "deref_site(peek,self,155)"] },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [62, 66] },
            { "file": "lib/lru/init.lua", "lines": [152, 159] }
          ],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "rule colon-self-nonnil-v1 head-matches all three F0 atoms (bindings: F=peek, R=self); guard is the rule's own entails() test, which only inspects def_form/receiver_param -- never a call-site fact, because no call-site fact was ever admitted into F0 (harvester only emits definition/deref facts, not call-graph facts)",
          "state": { "matched_rule": "colon-self-nonnil-v1", "bindings": { "F": "peek", "R": "self" } },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [59, 69] }
          ],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "body fires: adds ground fact in_arms(self@peek155, {Cache})[supports] to F1 = F0 union {new fact}",
          "state": { "store_delta": "+in_arms(self@peek155,{Cache})[supports]" },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [85, 92] }
          ],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "no other rule head unifies against the new in_arms fact (neither remaining producer rule's heads reference in_arms/-predicate); F2 = F1, fixpoint reached",
          "state": { "fixpoint": true },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [206, 220] }
          ],
          "confidence": "determined"
        },
        {
          "step": 5,
          "description": "conflict check: no rule in this set ever derives a refutes-polarity fact (producers.js's three rules only ever return supports/no-match) -- store contains supports for self@peek155, no refutes anywhere; not a conflict",
          "state": { "conflict": false },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [110, 122] },
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [35, 90] }
          ],
          "confidence": "determined"
        },
        {
          "step": 6,
          "description": "verdict per §1.3: supports present, no ⊥ reached -> Proved. Correct by luck here (calledOnlyViaColon=true, no counterexample in this instance) even though the rule content is the identical unsound definition-site-only check subtract-attack.md Attack 1 found -- the design's own §1.5 item 1 explicitly disclaims this as a fix",
          "state": { "verdict": "Proved", "self@peek155": "supports, no conflict" },
          "codeSpans": [
            { "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [147, 157] }
          ],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Rule fires on definition-site facts only, mints Proved; correct in this instance only because ground truth happens to have no counterexample -- mechanism is unsound in general (same defect as subtract's flagship rule)."
    },
    "corpus-2-json-hex": {
      "steps": [
        {
          "step": 1,
          "description": "admit facts: single_assignment(HEX), assigned_kind(HEX,table), deref_site(HEX,125)",
          "state": { "store": ["single_assignment(HEX)", "assigned_kind(HEX,table)", "deref_site(HEX,125)"] },
          "codeSpans": [{ "file": "lib/json/init.lua", "lines": [27, 33] }, { "file": "lib/json/init.lua", "lines": [101, 133] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "rule never-reassigned-nonnil head-matches (assignment_count=1, initial_value_kind=table, name=HEX); no head pattern or guard inspects control-flow ordering between assignment and use -- the rule's entails() only compares assignment-count/kind/name",
          "state": { "matched_rule": "never-reassigned-nonnil", "bindings": { "X": "HEX" } },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [77, 88] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "body fires: adds in_arms(HEX@125,{table})[supports]; no ordering/dominance fact exists in the store to gate this, so the gap subtract-attack.md Attack 4 found is present but not exercised here (useIsAfterAssign=true in ground truth)",
          "state": { "store_delta": "+in_arms(HEX@125,{table})[supports]" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [158, 164] }],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "fixpoint reached, no further rule fires; no refutes fact ever derivable by this rule set -> no conflict",
          "state": { "fixpoint": true, "conflict": false },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [110, 122] }],
          "confidence": "determined"
        },
        {
          "step": 5,
          "description": "verdict: Proved. Matches ground truth (HEX genuinely table at use); disclosed gap (no dominance check) not exercised by this instance's facts",
          "state": { "verdict": "Proved" },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Fires correctly for this instance; the ordering/dominance gap is real but latent (not triggered) since use is control-flow-after assignment in this scenario's facts."
    },
    "corpus-3-queue-fifo": {
      "steps": [
        {
          "step": 1,
          "description": "admit facts: single_assignment(FIFO), assigned_kind(FIFO,table), deref_site(FIFO,157) -- identical shape to corpus-2",
          "state": { "store": ["single_assignment(FIFO)", "assigned_kind(FIFO,table)", "deref_site(FIFO,157)"] },
          "codeSpans": [{ "file": "lib/queue/init.lua", "lines": [152, 169] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "never-reassigned-nonnil head-matches identically to corpus-2, same rule, same binding shape (X=FIFO)",
          "state": { "matched_rule": "never-reassigned-nonnil", "bindings": { "X": "FIFO" } },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [77, 88] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "body fires: adds in_arms(FIFO@157,{table})[supports]; fixpoint reached, no conflict (no refutes derivable)",
          "state": { "store_delta": "+in_arms(FIFO@157,{table})[supports]", "fixpoint": true, "conflict": false },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [165, 165] }],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "verdict: Proved, matches ground truth",
          "state": { "verdict": "Proved" },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Identical mechanism to corpus-2; same disclosed-but-unexercised ordering gap."
    },
    "corpus-4-deque-self-x4": {
      "steps": [
        {
          "step": 1,
          "description": "admit facts: def_form(pop_front,colon), receiver_param(pop_front,self), and FOUR separate deref_site facts, one per use line (62,63,64,65)",
          "state": { "store": ["def_form(pop_front,colon)", "receiver_param(pop_front,self)", "deref_site(pop_front,self,62)", "deref_site(pop_front,self,63)", "deref_site(pop_front,self,64)", "deref_site(pop_front,self,65)"] },
          "codeSpans": [{ "file": "lib/deque/init.lua", "lines": [56, 67] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "colon-self-nonnil-v1's heads unify once per distinct deref_site grounding -- 4 separate binding sets (F=pop_front,R=self,site=62/63/64/65) since the design's own §1.5 item 4 explicitly narrates this as 4 separate firings against 4 distinct target ids sharing one rule registration",
          "state": { "matched_rule": "colon-self-nonnil-v1", "firings": 4 },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [166, 170] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "4 bodies fire, adding 4 distinct facts: in_arms(self@62,{Deque})[supports], in_arms(self@63,...), in_arms(self@64,...), in_arms(self@65,...) -- each its own canonical address (subject+site), no shared identity across sites in this monotone (non-merging) reading",
          "state": { "store_delta": "+4x in_arms(self@{62,63,64,65},{Deque})[supports]" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [85, 92] }],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "fixpoint reached; no refutes anywhere -> no conflict at any of the 4 addresses",
          "state": { "fixpoint": true, "conflict": false },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 5,
          "description": "verdict: Proved at all 4 sites independently. Correct by luck (calledOnlyViaColon=true), but the amplification is structural: one wrong rule would have produced 4 false Proveds identically -- blast radius named explicitly in this scenario's own notes",
          "state": { "verdict": "Proved x4" },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "One rule registration fires independently at 4 distinct canonical addresses (no merging in Reading A); all 4 Proved, correct here only because ground truth has no counterexample. Blast-radius amplification is real but not triggered by this instance's facts."
    },
    "corpus-5-bigint-reachable": {
      "steps": [
        {
          "step": 1,
          "description": "admit fact: reachable(bigint,\"then\")@115 (mined branch-reachability fact); claim's unionArms/claimedArms are explicitly null (no value-arm structure for reachability)",
          "state": { "store": ["reachable(bigint,then,115)"] },
          "codeSpans": [{ "file": "lib/bigint/init.lua", "lines": [97, 121] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "pattern-index the 3 producer rule heads against this fact's predicate: colon-self-nonnil-v1 needs def_form/receiver_param/deref_site; never-reassigned-nonnil needs single_assignment/assigned_kind/deref_site; arm-subset-entailment-v1 needs evidence/subset -- none match a bare reachable(...) atom",
          "state": { "matching_rule_heads": [] },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [171, 179] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "no rule fires; F1 = F0, fixpoint reached immediately -- computable by pattern-indexing rule heads against the address without running saturation at all, exactly as the design notes",
          "state": { "fixpoint": true, "new_facts": 0 },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [171, 179] }],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "verdict: neither supports nor refutes ever appears for this address -> Open, per §1.3's third case",
          "state": { "verdict": "Open" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [117, 122] }],
          "confidence": "determined"
        }
      ],
      "verdict": "open",
      "verdictNote": "No rule head unifies with a reachability predicate at all; honestly Open, and the gap is checkable pre-saturation (static pattern-index) rather than only after running the fixpoint."
    },
    "adversarial-subtract-false-proved": {
      "steps": [
        {
          "step": 1,
          "description": "admit facts: def_form(peek,colon), receiver_param(peek,self), deref_site(peek,self,155) -- identical shape to corpus-1; additionally a real counterexample call Cache.peek(nil,key) exists in the world, but no call-site fact for it is ever admitted (harvester scope is definition/deref only, no call-graph harvesting)",
          "state": { "store": ["def_form(peek,colon)", "receiver_param(peek,self)", "deref_site(peek,self,155)"], "world_counterexample": "Cache.peek(nil,key) [not represented as a fact]" },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [152, 159] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "colon-self-nonnil-v1 head-matches identically to corpus-1 (rule cannot distinguish this fact set from corpus-1's -- they are structurally the same 3 atoms)",
          "state": { "matched_rule": "colon-self-nonnil-v1", "bindings": { "F": "peek", "R": "self" } },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [59, 69] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "body fires: adds in_arms(self@peek155,{Cache})[supports]; the counterexample never enters the store as any fact, so no rule can ever produce a refutes for this address in this rule set",
          "state": { "store_delta": "+in_arms(self@peek155,{Cache})[supports]" },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "fixpoint reached; conflict check finds no refutes anywhere -> no conflict",
          "state": { "fixpoint": true, "conflict": false },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 5,
          "description": "verdict: Proved -- FALSE Proved, since ground truth has a real counterexample the rule structurally cannot see. Identical failure to subtract's flagship rule, restated in Datalog form; the shape change (edges->facts) does not touch rule content",
          "state": { "verdict": "Proved (false)" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [147, 157] }],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "False Proved -- rule is definition-site-only, never inspects call sites, so the real counterexample never suppresses the supports fact. Same defect as subtract-attack.md Attack 1, unchanged by the propagation-rule framing."
    },
    "adversarial-saturation-b-identity-merge": {
      "steps": [
        {
          "step": 1,
          "description": "admit factA's atoms: def_form(peek,colon), receiver_param(peek,self), deref_site(peek,self,155); admit factB's atoms: def_form(pop_front,colon), receiver_param(pop_front,self), deref_site(pop_front,self,62..65)",
          "state": { "store": ["def_form(peek,colon)", "receiver_param(peek,self)", "deref_site(peek,self,155)", "def_form(pop_front,colon)", "receiver_param(pop_front,self)", "deref_site(pop_front,self,62..65)"] },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [152, 159] }, { "file": "lib/deque/init.lua", "lines": [56, 67] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "colon-self-nonnil-v1 fires twice, independently, on the two distinct binding sets (F=peek vs F=pop_front) -- these are separate ground atoms in the fact store; Reading A has no merge operation of any kind, so the two firings cannot interact",
          "state": { "matched_rule": "colon-self-nonnil-v1", "firings": 2, "bindings": [{ "F": "peek" }, { "F": "pop_front" }] },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [391, 401] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "bodies add two distinct facts: in_arms(self@peek155,{Cache})[supports] and in_arms(self@pop_front62-65,{Deque})[supports] -- different canonical addresses (different subject/site/type), no shared store entry",
          "state": { "store_delta": "+in_arms(self@peek155,{Cache})[supports]; +in_arms(self@pop_front,{Deque})[supports]" },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "fixpoint reached; neither address ever receives a refutes fact (rule set has no refute-producing rule and no call-site facts exist to trigger one) -> no conflict at either address",
          "state": { "fixpoint": true, "conflict": false },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 5,
          "description": "verdict: A -> Proved (false -- real counterexample exists but is structurally invisible), B -> Proved (true -- genuinely no counterexample). The two verdicts are derived completely independently; nothing in Reading A's monotone-accumulation mechanism lets B's truth leak into A's verdict or vice versa, because facts are never merged, only added",
          "state": { "verdict_A": "Proved (false)", "verdict_B": "Proved (true)" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [392, 401] }],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "A and B each independently mint Proved (A false, B true) with no interaction between them -- Reading A's store only grows, never merges identities, so this scenario's adversarial identity-merge mechanism (the point of the scenario) cannot occur under Reading A at all. Blast radius stays ordinary (one wrong fact, not a merged class)."
    },
    "hand-json-type-guard": {
      "steps": [
        {
          "step": 1,
          "description": "admit fact: evidence(type_guard, establishesArms=[number], span=408-415) for subject val; admit claim val-number-arm (claimedArms=[number])",
          "state": { "store": ["evidence(val,type_guard,[number])", "claim(val-number-arm,[number])"] },
          "codeSpans": [{ "file": "lib/json/init.lua", "lines": [406, 428] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "arm-subset-entailment-v1 head-matches: ev.subject is undefined so the subject-equality guard is vacuously skipped; isSubset([number],[number]) holds -- fires. In this scenario only one evidence fact and one claim exist so the subject-blind guard produces no ambiguity, but the rule's own logic (per producers.js) does not actually verify ev and c denote the same subject when both subject fields aren't both present",
          "state": { "matched_rule": "arm-subset-entailment-v1", "subject_check": "skipped (ev.subject undefined)" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [45, 50] }],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "body fires: adds in_arms(val-number-arm,{number})[supports]; fixpoint reached (no other rule head matches); no refutes possible in this rule set -> no conflict",
          "state": { "store_delta": "+in_arms(val-number-arm,{number})[supports]", "fixpoint": true, "conflict": false },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "verdict: Proved, matches ground truth (val genuinely number on this branch)",
          "state": { "verdict": "Proved" },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Fires correctly; step 2's subject-blind guard is a latent producer-rule gap (not exercised here since only one evidence/claim pair exists in the store)."
    },
    "hand-bigint-err-arm": {
      "steps": [
        {
          "step": 1,
          "description": "admit two evidence facts (guard_return, establishesArms=[nil] and [string]) and two claims (ret1-nil-arm claimedArms=[nil], ret2-string-arm claimedArms=[string])",
          "state": { "store": ["evidence1(guard_return,[nil])", "evidence2(guard_return,[string])", "claim(ret1,[nil])", "claim(ret2,[string])"] },
          "codeSpans": [{ "file": "lib/bigint/init.lua", "lines": [291, 308] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "arm-subset-entailment-v1 tests all 4 (evidence,claim) pairs since subject-equality is vacuously skipped (neither evidence carries a subject field); isSubset([nil],[nil]) and isSubset([string],[string]) hold, isSubset([nil],[string]) and isSubset([string],[nil]) fail -- the arm-sets themselves disambiguate correctly even without a subject check, but this is incidental to this scenario's non-overlapping arm sets, not something the rule verifies structurally",
          "state": { "matched_rule": "arm-subset-entailment-v1", "firings": 2, "cross_pairs_rejected": 2 },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [45, 50] }],
          "confidence": "underdetermined"
        },
        {
          "step": 3,
          "description": "bodies fire: adds in_arms(ret1,{nil})[supports] and in_arms(ret2,{string})[supports]; fixpoint reached; no refutes possible -> no conflict at either address",
          "state": { "store_delta": "+in_arms(ret1,{nil})[supports]; +in_arms(ret2,{string})[supports]", "fixpoint": true, "conflict": false },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "verdict: both Proved, matching ground truth (both arms genuinely established by the guard-return code)",
          "state": { "verdict_ret1": "Proved", "verdict_ret2": "Proved" },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Both claims Proved correctly; the generic entailment rule's subject-blindness (step 2) happens not to matter here because the two arm-sets are disjoint, not because the rule checked subject identity."
    },
    "hand-lru-field-shape": {
      "steps": [
        {
          "step": 1,
          "description": "admit fact for map-table-arm: evidence(field_assign, establishesArms=[table]); admit claim map-table-arm (claimedArms=[table]). Separately, admit claim ttl-number-arm (claimedArms=[number]) with evidence establishesArms=null (opt_expr, establishes nothing)",
          "state": { "store": ["evidence(map,field_assign,[table])", "claim(map-table-arm,[table])", "evidence(ttl,opt_expr,null)", "claim(ttl-number-arm,[number])"] },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [77, 101] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "arm-subset-entailment-v1 fires for map-table-arm (isSubset([table],[table]) true); for ttl-number-arm the guard `Array.isArray(ev.establishesArms)` fails on null -> no-match, rule does not fire",
          "state": { "matched_rule": "arm-subset-entailment-v1 (map only)", "ttl_fired": false },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [45, 50] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "body fires only for map: adds in_arms(map-table-arm,{table})[supports]. No fact of any kind is ever added for ttl-number-arm -- store has neither supports nor refutes at that address",
          "state": { "store_delta": "+in_arms(map-table-arm,{table})[supports]" },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "fixpoint reached for both addresses; conflict check: map has supports/no-refutes -> no conflict; ttl has nothing at all -> trivially no conflict",
          "state": { "fixpoint": true, "conflict_map": false, "conflict_ttl": false },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 5,
          "description": "verdict: map-table-arm -> Proved (matches ground truth). ttl-number-arm -> Open (no rule ever fires for it) -- NOT Refuted, even though ground truth says the claim over-excludes the real nil arm; this rule set has no negative-evidence source that could produce a refutes fact here",
          "state": { "verdict_map": "Proved", "verdict_ttl": "Open" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/candidates/saturation.md", "lines": [117, 122] }],
          "confidence": "determined"
        }
      ],
      "verdict": "open",
      "verdictNote": "Two independent claims in one scenario: map-table-arm Proved correctly; ttl-number-arm Open (design's three-valued semantics gives Open, not Refuted, for a claim with no supporting rule and no negative-evidence mechanism, even when ground truth says the claim overclaims)."
    },
    "hand-lru-closure-upvalue": {
      "steps": [
        {
          "step": 1,
          "description": "admit fact for cache-upvalue-arm: evidence(upvalue_capture, establishesArms=[Cache]); admit claim cache-upvalue-arm (claimedArms=[Cache]). Admit claim node-upvalue-arm (claimedArms=[LruNode]) with evidence establishesArms=null (reassigned in closure, establishes nothing)",
          "state": { "store": ["evidence(cache,upvalue_capture,[Cache])", "claim(cache-upvalue-arm,[Cache])", "evidence(node,upvalue_capture,null)", "claim(node-upvalue-arm,[LruNode])"] },
          "codeSpans": [{ "file": "lib/lru/init.lua", "lines": [248, 264] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "arm-subset-entailment-v1 fires for cache-upvalue-arm (isSubset([Cache],[Cache]) true); for node-upvalue-arm the Array.isArray(null) guard fails -> no-match",
          "state": { "matched_rule": "arm-subset-entailment-v1 (cache only)", "node_fired": false },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [45, 50] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "body fires only for cache: adds in_arms(cache-upvalue-arm,{Cache})[supports]. Nothing added for node-upvalue-arm",
          "state": { "store_delta": "+in_arms(cache-upvalue-arm,{Cache})[supports]" },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "fixpoint reached; no conflict at either address (cache has supports only, node has nothing)",
          "state": { "fixpoint": true, "conflict_cache": false, "conflict_node": false },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 5,
          "description": "verdict: cache-upvalue-arm -> Proved (matches ground truth, cache never reassigned). node-upvalue-arm -> Open, even though ground truth is false (node genuinely reaches the nil arm at list exhaustion) -- same three-valued gap as the ttl scenario, no rule ever produces a refutes fact for a wrongly-narrow claim",
          "state": { "verdict_cache": "Proved", "verdict_node": "Open" },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "open",
      "verdictNote": "cache-upvalue-arm Proved correctly; node-upvalue-arm Open despite being a genuinely false claim -- this rule set has no mechanism to actively refute an overclaiming claim, it can only fail to support it."
    },
    "hand-json-generic-for": {
      "steps": [
        {
          "step": 1,
          "description": "admit fact: evidence(generic_for_protocol, establishesArms=[boolean,number,string,table,function]); admit claim k-nonterminator-arms (claimedArms=[boolean,number,string,table,function])",
          "state": { "store": ["evidence(k,generic_for_protocol,[boolean,number,string,table,function])", "claim(k-nonterminator-arms,[boolean,number,string,table,function])"] },
          "codeSpans": [{ "file": "lib/json/init.lua", "lines": [429, 443] }],
          "confidence": "determined"
        },
        {
          "step": 2,
          "description": "arm-subset-entailment-v1 fires: isSubset(claimedArms,claimedArms) trivially true (evidence establishes exactly the claimed set)",
          "state": { "matched_rule": "arm-subset-entailment-v1" },
          "codeSpans": [{ "file": "docs/artifacts/2026-07-05-typechecker-declarative-core/design-pass-abstract-kernel/hand-eval/producers.js", "lines": [45, 50] }],
          "confidence": "determined"
        },
        {
          "step": 3,
          "description": "body fires: adds in_arms(k-nonterminator-arms,{boolean,number,string,table,function})[supports]; fixpoint reached; no conflict",
          "state": { "store_delta": "+in_arms(k-nonterminator-arms,...)[supports]", "fixpoint": true, "conflict": false },
          "codeSpans": [],
          "confidence": "determined"
        },
        {
          "step": 4,
          "description": "verdict: Proved, matches ground truth (pairs() protocol genuinely excludes nil from the loop body)",
          "state": { "verdict": "Proved" },
          "codeSpans": [],
          "confidence": "determined"
        }
      ],
      "verdict": "proved",
      "verdictNote": "Fires correctly; no gap exercised in this instance."
    }
  }
}
;
