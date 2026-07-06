// scenarios.js
//
// The SINGLE source of truth for the underlying real facts every engine is
// run against. Nothing here is engine-specific vocabulary (no "Address"
// terms, no "Claim" records, no "witness" shapes) -- each engine file adapts
// these plain facts into its own candidate's vocabulary itself. This file
// must not be edited to favor one engine's story over another's.
//
// Sources (read in full before writing this file):
//   - execution/first-slice-run.md lines ~411-447 (5 corpus instances)
//   - judgments/subtract-attack.md Attack 1 (false-Proved colon-self rule)
//   - candidates/saturation.md section 4, "Plausible-but-wrong rule earning
//     false Proved -- rewriting is MORE dangerous than checking, under
//     Reading B specifically" (identity-merge amplification)
//
// window.SCENARIOS is an array of { id, label, citation, facts }.

window.SCENARIOS = [
  {
    id: "corpus-1-lru-self",
    label: "Corpus #1: lru self non-nil",
    citation:
      "first-slice-run.md, 5 concrete “obviously decidable” Open " +
      "instances, item 1: “lib/lru/init.lua:155 | deref:self | schema=non-nil”",
    facts: {
      shape: "colon_self_nonnil",
      file: "lib/lru/init.lua",
      defLine: 154,
      useLine: 155,
      funcName: "Cache:peek",
      defForm: "colon",
      receiverParam: "self",
      derefName: "self",
      schema: "non-nil",
      // Ground truth for this scenario: no counterexample call exists in
      // the corpus -- Cache:peek is only ever invoked via `:` syntax.
      calledOnlyViaColon: true,
    },
  },
  {
    id: "corpus-2-json-hex",
    label: "Corpus #2: json HEX non-nil",
    citation:
      "first-slice-run.md, instance 2: “lib/json/init.lua:125 | " +
      "deref:HEX | schema=non-nil”",
    facts: {
      shape: "single_assign_nonnil",
      file: "lib/json/init.lua",
      name: "HEX",
      assignLine: 28,
      assignKind: "table",
      useLine: 125,
      assignmentCount: 1,
      derefName: "HEX",
      schema: "non-nil",
      useIsAfterAssign: true,
    },
  },
  {
    id: "corpus-3-queue-fifo",
    label: "Corpus #3: queue FIFO non-nil",
    citation:
      "first-slice-run.md, instance 3: “lib/queue/init.lua:157 | " +
      "deref:FIFO | schema=non-nil”",
    facts: {
      shape: "single_assign_nonnil",
      file: "lib/queue/init.lua",
      name: "FIFO",
      assignLine: 156,
      assignKind: "table",
      useLine: 157,
      assignmentCount: 1,
      derefName: "FIFO",
      schema: "non-nil",
      useIsAfterAssign: true,
    },
  },
  {
    id: "corpus-4-deque-self-x4",
    label: "Corpus #4: deque self non-nil (x4 sites)",
    citation:
      "first-slice-run.md, instance 4: “lib/deque/init.lua:62-65 | " +
      "deref:self” (four separate Open entries)",
    facts: {
      shape: "colon_self_nonnil_multi",
      file: "lib/deque/init.lua",
      defLine: 61,
      funcName: "Deque:pop_front",
      defForm: "colon",
      receiverParam: "self",
      derefName: "self",
      useLines: [62, 63, 64, 65],
      schema: "non-nil",
      calledOnlyViaColon: true,
    },
  },
  {
    id: "corpus-5-bigint-reachable",
    label: "Corpus #5: bigint branch reachability",
    citation:
      "first-slice-run.md, instance 5: “lib/bigint/init.lua:115 | " +
      "branch:then | schema=reachable”",
    facts: {
      shape: "branch_reachable",
      file: "lib/bigint/init.lua",
      line: 115,
      branch: "then",
      schema: "reachable",
      noRuleAvailable: true,
    },
  },
  {
    id: "adversarial-subtract-false-proved",
    label: "Adversarial (a): plausible-but-wrong colon-self rule",
    citation:
      "judgments/subtract-attack.md, “Attack 1 — the flagship worked " +
      "example is itself an unsound rule (FATAL)”",
    facts: {
      shape: "colon_self_nonnil",
      file: "lib/lru/init.lua",
      defLine: 154,
      useLine: 155,
      funcName: "Cache:peek",
      defForm: "colon",
      receiverParam: "self",
      derefName: "self",
      schema: "non-nil",
      // Ground truth for THIS scenario, unlike corpus-1: a real counterexample
      // call exists. Colon *definition* syntax places no obligation on
      // *callers* -- per the attack: "Nothing stops `Cache.peek(nil, key)`".
      calledOnlyViaColon: false,
      counterexampleCall: "Cache.peek(nil, key)",
    },
  },
  {
    id: "adversarial-saturation-b-identity-merge",
    label: "Adversarial (b): saturation-B identity-merge amplification",
    citation:
      "candidates/saturation.md §4, “Plausible-but-wrong rule earning " +
      "false Proved — rewriting is MORE dangerous than checking, under " +
      "Reading B specifically”",
    facts: {
      shape: "two_self_facts_for_merge",
      // factA: same unsound shape as the subtract-false-proved scenario --
      // a real counterexample exists, so this should NOT be provable
      // universally.
      factA: {
        file: "lib/lru/init.lua",
        funcName: "Cache:peek",
        defForm: "colon",
        derefName: "self",
        calledOnlyViaColon: false,
        counterexampleCall: "Cache.peek(nil, key)",
      },
      // factB: genuinely true, no counterexample.
      factB: {
        file: "lib/deque/init.lua",
        funcName: "Deque:pop_front",
        defForm: "colon",
        derefName: "self",
        calledOnlyViaColon: true,
      },
    },
  },
];
