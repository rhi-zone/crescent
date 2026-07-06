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
// window.SCENARIOS is an array of { id, label, provenance, citation, facts,
// source, notes }.
//
// provenance (one word, rendered as a badge):
//   "mined"       -- machine-harvested via lib/declc/harvest.lua
//   "constructed" -- built from a judgments/candidates finding
//   "hand"        -- hand-derived claims over real code (this audit);
//                    admissibility waived by owner, claims need not be
//                    derivable by any real typechecker
//
// -----------------------------------------------------------------------
// Why the MINED corpus is all non-nil / reachability claims (VERIFIED, not
// a sampling artifact of this hand-eval):
//
// Every mined scenario's claim is either "non-nil" (a dereference
// presupposition; encoded below as claimedArms = unionArms minus the nil
// arm) or "reachable" (a branch presupposition). That is not
// this hand-eval picking a convenient subset -- it is a direct, confirmed
// consequence of upstream harvester scope. lib/declc/harvest.lua:21-26
// states, verbatim, that `harvest_mined` implements "EXACTLY the two
// catalogued presupposing forms -- dereference (x.f / x[k] / x:m(...))
// presupposes x non-nil; a guard (if/elseif clause) presupposes both
// branches believed reachable. No other mined forms are added, however
// tempting, per H5's own text." The function body (lib/declc/harvest.lua
// lines 415-582, walked in full) only ever calls `emit_deref`
// (schema="non-nil") or `emit_branch_reachable` (schema="reachable") --
// no third mined-claim shape exists anywhere in that walk. So this
// corpus's 2-schema claim mix is a byproduct of harvest_mined's current
// scope, not a representative sample of every claim shape a real program
// might need a kernel to decide. The "hand" scenarios below exist to
// counter exactly that bias with other claim kinds over real code.
//
// hand_claims fact shape (generic; engines must not branch on scenario
// identity, only on this structure):
//   claims: [{ id, subject, unionArms, claimedArms, site, evidence:
//     { kind, establishesArms|null, span, ...kind-specific detail },
//     groundTruth }]
// A claim asserts subject ∈ claimedArms (a subset of unionArms). nil,
// where present, is an ORDINARY arm of unionArms -- there is no non-nil
// primitive anywhere in this encoding. evidence.establishesArms is the
// arm subset the evidence structurally establishes (null = establishes
// nothing usable).
//
// PLACEMENT: arm-set entailment (subset logic) is PRODUCER content, not
// kernel content. It lives in producers.js as rule definitions whose
// check/entails every engine re-executes opaquely through its generic
// rule mechanism -- no engine kernel loop inspects arms. The corpus
// scenarios' claims (below) use the same claim shape: { subject,
// unionArms, claimedArms }, with claimedArms = unionArms minus the nil
// arm expressing what "schema=non-nil" used to say opaquely. Entailment
// between claims ("x ∈ {string}" entails "x ∈ {string, number}") is now
// derivable by producer rules; the opaque-string encoding could never
// corroborate across claims.
// -----------------------------------------------------------------------

window.SCENARIOS = [
  {
    id: "corpus-1-lru-self",
    label: "Corpus #1: lru self non-nil",
    provenance: "mined",
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
      // "non-nil" re-encoded as ordinary arm-set membership. Union derived
      // from the --: annotation at lib/lru/init.lua:153 (receiver Cache)
      // plus the dot-call possibility that motivates the presupposition.
      claim: { subject: "self", unionArms: ["Cache", "nil"], claimedArms: ["Cache"] },
      // Ground truth for this scenario: no counterexample call exists in
      // the corpus -- Cache:peek is only ever invoked via `:` syntax.
      calledOnlyViaColon: true,
      defSpan: { lineStart: 154, lineEnd: 154 },
      useSpan: { lineStart: 155, lineEnd: 155, colStart: 16, colEnd: 20 },
    },
    source: {
      file: "lib/lru/init.lua",
      excerpts: [
        {
          key: "peek",
          lineStart: 152,
          lineEnd: 159,
          lines: [
            "-- Get without promoting. Returns nil if missing or expired.",
            "--: (Cache, unknown) -> unknown | nil",
            "function Cache:peek(key)",
            "  local node = self._map[key]",
            "  if not node then return nil end",
            "  if _check_expired(self, node) then return nil end",
            "  return node.value",
            "end",
          ],
        },
      ],
    },
    notes: {
      subtract: [
        {
          key: "mechanism",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text:
            "colon-self-nonnil-v1 checks only def.form==\"colon\" && def.receiver_param==target.expr " +
            "&& target.claim==\"non-nil\" -- it never inspects call sites. Colon definition syntax " +
            "only sugars an implicit `self` parameter; it places zero obligation on callers.",
        },
      ],
      primitive: [
        {
          key: "witness-bug",
          citesFinding: "primitive-attack.md#attack-0-the-flagship-demo-does-not-run-as-claimed--fatal",
          text:
            "mined_deref_nonnil.check, pasted verbatim from primitive.md §2.3, has no branch " +
            "returning \"unknown\" for \"no concrete value\" -- Lua cannot distinguish field-absent " +
            "from field-explicitly-nil, so witness.value == nil falls straight to \"reject\".",
        },
        {
          key: "disagreement",
          citesFinding: "primitive-attack.md#attack-0-the-flagship-demo-does-not-run-as-claimed--fatal",
          text:
            "Running the pasted code produces a Refuted finding, not the claimed empty findings " +
            "table -- self is genuinely guaranteed non-nil here; the tool reports a false contradiction.",
        },
      ],
      invert: [
        {
          key: "underspecified",
          citesFinding: "invert-attack.md#1-the-five-witnessproof-walkthroughs-dont-actually-go-through-as-formalized-fatal",
          text:
            "The self-non-nil certificate cites a premise \"is this method defined with `:` syntax?\" " +
            "as a static parse fact, but invert.md's own R-METHODCALL desugaring erases colon-vs-dot " +
            "syntax before any Trace event exists, and Certificate has only two shapes (witness, proof) " +
            "-- no third kind exists to carry a static parse fact.",
        },
      ],
      evidence: [],
      "saturation-a": [
        {
          key: "same-break",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text:
            "Restating the rule in Datalog form (nonnil(F,\"self\") :- def_form(F,colon), " +
            "receiver_param(F,self), deref_site(F,self)) pattern-matches the exact same " +
            "definition-site-only premise as subtract's rule, and is wrong for the identical reason.",
        },
      ],
      "saturation-b": [
        {
          key: "same-break",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text:
            "The rewrite rule canonicalizes def-form(colon) to nonnil_binding(self, F) directly, " +
            "with no call-site check -- same unsound content as subtract's colon-self-nonnil-v1, " +
            "restated as a rewrite instead of an edge.",
        },
      ],
      synthesis: [
        {
          key: "receipt-gap",
          citesFinding: "candidates/synthesis.md §4.1 / §6 row 1",
          text:
            "Rule-honesty (is colon-self-nonnil-v1's logic actually sound?) is kernel-unverifiable " +
            "in principle -- grafts 2/3 make the citation shape visible in the receipt (\"universal " +
            "claim, evidence cited = definition-site fact only\") but cannot verify the rule's logic " +
            "itself. This is a synthesis.md self-assessment; none of the four judgments/*.md attacks " +
            "review synthesis.md directly (they review subtract/primitive/evidence/invert), so no " +
            "judgments/*.md anchor covers this specific claim -- kept as a candidates/*.md citation.",
        },
      ],
    },
  },
  {
    id: "corpus-2-json-hex",
    label: "Corpus #2: json HEX non-nil",
    provenance: "mined",
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
      // Union derived from the code at lib/json/init.lua:28: a local is
      // nil until assigned; the single assignment is a table literal.
      claim: { subject: "HEX", unionArms: ["table", "nil"], claimedArms: ["table"] },
      useIsAfterAssign: true,
      assignSpan: { lineStart: 28, lineEnd: 28 },
      useSpan: { lineStart: 125, lineEnd: 125, colStart: 16, colEnd: 19 },
    },
    source: {
      file: "lib/json/init.lua",
      excerpts: [
        {
          key: "hex-table",
          lineStart: 27,
          lineEnd: 33,
          lines: [
            "-- Lookup table for hex digit values",
            "local HEX = {}",
            "do",
            "\tfor i = 0, 9 do HEX[0x30 + i] = i end          -- '0'-'9'",
            "\tfor i = 0, 5 do HEX[0x41 + i] = 10 + i end     -- 'A'-'F'",
            "\tfor i = 0, 5 do HEX[0x61 + i] = 10 + i end     -- 'a'-'f'",
            "end",
          ],
        },
        {
          key: "use-site",
          lineStart: 101,
          lineEnd: 133,
          lines: [
            "--: (string, integer, integer) -> (string | nil, integer | nil, string | nil)",
            "decode_string = function(s, i, n)",
            "\tlocal parts = {}",
            "\tlocal start = i",
            "\twhile i <= n do",
            "\t\tlocal b = byte(s, i) or 0",
            "\t\tif b == 0x22 then -- closing '\"'",
            "\t\t\tparts[#parts + 1] = sub(s, start, i - 1)",
            "\t\t\treturn concat(parts), i + 1, nil",
            "\t\telseif b == 0x5C then -- '\\'",
            "\t\t\tparts[#parts + 1] = sub(s, start, i - 1)",
            "\t\t\ti = i + 1",
            "\t\t\tif i > n then return nil, nil, \"unexpected end of string escape\" end",
            "\t\t\tlocal e = byte(s, i) or 0",
            "\t\t\tif e == 0x22 then parts[#parts + 1] = \"\\\"\"",
            "\t\t\telseif e == 0x5C then parts[#parts + 1] = \"\\\\\"",
            "\t\t\telseif e == 0x2F then parts[#parts + 1] = \"/\"",
            "\t\t\telseif e == 0x62 then parts[#parts + 1] = \"\\b\"",
            "\t\t\telseif e == 0x66 then parts[#parts + 1] = \"\\f\"",
            "\t\t\telseif e == 0x6E then parts[#parts + 1] = \"\\n\"",
            "\t\t\telseif e == 0x72 then parts[#parts + 1] = \"\\r\"",
            "\t\t\telseif e == 0x74 then parts[#parts + 1] = \"\\t\"",
            "\t\t\telseif e == 0x75 then -- \\uXXXX",
            "\t\t\t\tif i + 4 > n then return nil, nil, \"incomplete \\\\uXXXX escape\" end",
            "\t\t\t\tlocal h1 = HEX[byte(s, i+1)]",
            "\t\t\t\tlocal h2 = HEX[byte(s, i+2)]",
            "\t\t\t\tlocal h3 = HEX[byte(s, i+3)]",
            "\t\t\t\tlocal h4 = HEX[byte(s, i+4)]",
            "\t\t\t\tif not (h1 and h2 and h3 and h4) then",
            "\t\t\t\t\treturn nil, nil, \"invalid hex in \\\\uXXXX escape at position \" .. i",
            "\t\t\t\tend",
            "\t\t\t\tlocal cp = h1 * 4096 + h2 * 256 + h3 * 16 + h4",
            "\t\t\t\t-- Handle surrogate pairs",
          ],
        },
      ],
    },
    notes: {
      subtract: [
        {
          key: "gap",
          citesFinding: "subtract-attack.md#attack-4--re-deriving-the-5-corpus-instances",
          text:
            "never-reassigned-nonnil checks assignment_count==1 and initial_value_kind==\"table\" " +
            "against the deref's name, but never checks the deref is control-flow-after the " +
            "assignment (no dominance/ordering check) -- a disclosed gap, not exercised here since " +
            "HEX's use is after its assignment in this scenario.",
        },
      ],
      primitive: [],
      invert: [
        {
          key: "unsound-induct",
          citesFinding: "invert-attack.md#1-the-five-witnessproof-walkthroughs-dont-actually-go-through-as-formalized-fatal",
          text:
            "induct_trace's inductive step scans ONE replayed trace for absent rebinds of HEX -- " +
            "that proves at most \"in this one witnessed run, HEX was never rebound,\" not the " +
            "universal claim across every input. The trusted code accepts this and mints Proved " +
            "anyway; no finite number of witnessed traces closes that gap.",
        },
      ],
      evidence: [],
      "saturation-a": [
        {
          key: "gap",
          citesFinding: "subtract-attack.md#attack-4--re-deriving-the-5-corpus-instances",
          text:
            "Same partial weakness as subtract's version, restated in Datalog: no ordering/" +
            "dominance check between the assignment and the dereference (not exercised in this " +
            "scenario, since use is control-flow-after assignment).",
        },
      ],
      "saturation-b": [],
      synthesis: [
        {
          key: "narrowing-contingency",
          citesFinding: "primitive-attack.md#attack-0-the-flagship-demo-does-not-run-as-claimed--fatal",
          text:
            "premise_types/target_type narrowing (delta 7) would close the nil/absent conflation " +
            "bug class primitive-attack.md's Attack 0 found, but only contingent on that narrowing " +
            "mechanism actually being built -- it is not exercised by this particular rule shape.",
        },
      ],
    },
  },
  {
    id: "corpus-3-queue-fifo",
    label: "Corpus #3: queue FIFO non-nil",
    provenance: "mined",
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
      // Union derived from the code at lib/queue/init.lua:156: a local is
      // nil until assigned; the single assignment is a table literal.
      claim: { subject: "FIFO", unionArms: ["table", "nil"], claimedArms: ["table"] },
      useIsAfterAssign: true,
      assignSpan: { lineStart: 156, lineEnd: 156 },
      useSpan: { lineStart: 157, lineEnd: 157, colStart: 1, colEnd: 5 },
    },
    source: {
      file: "lib/queue/init.lua",
      excerpts: [
        {
          key: "fifo-def",
          lineStart: 152,
          lineEnd: 169,
          lines: [
            "-- ---------------------------------------------------------------------------",
            "-- FIFO Queue (growable ring buffer, O(1) amortised all ops)",
            "-- ---------------------------------------------------------------------------",
            "",
            "local FIFO = {}",
            "FIFO.__index = FIFO",
            "",
            "local FIFO_INIT_CAP = 8",
            "",
            "--- Enqueue a value at the back (alias: enqueue).",
            "--: (self: FIFOState, v: unknown) -> ()",
            "function FIFO:push(v)",
            "  local size = self._size",
            "  local cap  = self._cap",
            "  if size == cap then",
            "    -- Grow: double capacity, linearise elements",
            "    local newcap = cap * 2",
            "    local buf    = self._buf",
          ],
        },
      ],
    },
    notes: {
      subtract: [
        {
          key: "gap",
          citesFinding: "subtract-attack.md#attack-4--re-deriving-the-5-corpus-instances",
          text:
            "Identical shape to the HEX scenario (#2) -- same disclosed ordering/dominance gap, " +
            "not exercised here.",
        },
      ],
      primitive: [],
      invert: [
        {
          key: "unsound-induct",
          citesFinding: "invert-attack.md#1-the-five-witnessproof-walkthroughs-dont-actually-go-through-as-formalized-fatal",
          text:
            "Same shape as instance 2 (HEX): induct_trace's rebind-scan is over one replayed " +
            "trace, proving a per-run fact, not the universal one -- mints Proved anyway.",
        },
      ],
      evidence: [],
      "saturation-a": [
        {
          key: "gap",
          citesFinding: "subtract-attack.md#attack-4--re-deriving-the-5-corpus-instances",
          text: "Identical shape to HEX (#2) -- same disclosed ordering gap, restated in Datalog.",
        },
      ],
      "saturation-b": [],
      synthesis: [],
    },
  },
  {
    id: "corpus-4-deque-self-x4",
    label: "Corpus #4: deque self non-nil (x4 sites)",
    provenance: "mined",
    citation:
      "first-slice-run.md, instance 4: “lib/deque/init.lua:62-65 | " +
      "deref:self” (four separate Open entries)",
    facts: {
      shape: "colon_self_nonnil_multi",
      file: "lib/deque/init.lua",
      // Corrected: `function Deque:pop_front()` is at line 58, not 61.
      // Line 61 is the closing `end` of the internal `if` guard.
      defLine: 58,
      funcName: "Deque:pop_front",
      defForm: "colon",
      receiverParam: "self",
      derefName: "self",
      useLines: [62, 63, 64, 65],
      // Union derived from the --: annotation at lib/deque/init.lua:57
      // (receiver Deque) plus the dot-call possibility.
      claim: { subject: "self", unionArms: ["Deque", "nil"], claimedArms: ["Deque"] },
      calledOnlyViaColon: true,
      defSpan: { lineStart: 58, lineEnd: 58 },
      useSpans: [
        { lineStart: 62, lineEnd: 62, colStart: 15, colEnd: 19 },
        { lineStart: 63, lineEnd: 63, colStart: 12, colEnd: 16 },
        { lineStart: 64, lineEnd: 64, colStart: 2, colEnd: 6 },
        { lineStart: 65, lineEnd: 65, colStart: 2, colEnd: 6 },
      ],
    },
    source: {
      file: "lib/deque/init.lua",
      excerpts: [
        {
          key: "pop_front",
          lineStart: 56,
          lineEnd: 67,
          lines: [
            "--- Pop a value from the front. Returns nil if empty.",
            "--: (Deque) -> unknown | nil",
            "function Deque:pop_front()",
            "\tif self._head > self._tail then",
            "\t\treturn nil",
            "\tend",
            "\tlocal head = self._head",
            "\tlocal v = self._data[head]",
            "\tself._data[head] = nil",
            "\tself._head = head + 1",
            "\treturn v",
            "end",
          ],
        },
      ],
    },
    notes: {
      subtract: [
        {
          key: "mechanism",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text:
            "Same colon-self-nonnil-v1 rule as corpus #1, one rule registration reused against " +
            "4 different target ids -- \"one rule registration, reused by the kernel's submit " +
            "against as many targets as a producer names.\"",
        },
        {
          key: "blast-radius",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text:
            "\"§3.1 #4 touts that one rule closes 4 sites 'at once' as a virtue... It is equally " +
            "the liability multiplier -- a single wrong rule produces false Proved at every site " +
            "it's ever applied to.\"",
        },
      ],
      primitive: [
        {
          key: "amplification",
          citesFinding: "primitive-attack.md#attack-0-the-flagship-demo-does-not-run-as-claimed--fatal",
          text:
            "The same nil/absent-conflation bug fires identically at all 4 sites -- the design's " +
            "per-producer reuse (\"zero new code\") amplifies the bug exactly as it would have " +
            "amplified correctness.",
        },
      ],
      invert: [
        {
          key: "underspecified",
          citesFinding: "invert-attack.md#1-the-five-witnessproof-walkthroughs-dont-actually-go-through-as-formalized-fatal",
          text:
            "Amortized as \"one universal certificate, 4 site-specific projections\" -- but the " +
            "underlying certificate is the same unconstructible one as corpus #1 (this also " +
            "infects instance #4 identically, per evidence-attack.md Attack 4's own cross-reference).",
        },
      ],
      evidence: [],
      "saturation-a": [
        {
          key: "same-break",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text: "\"Same rule as #1, same break, ×4\" -- the rule fires identically at all 4 sites.",
        },
      ],
      "saturation-b": [
        {
          key: "same-break",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text: "Same rewrite applied to all 4 sites; no merge opportunity exists in isolation (single fact per site).",
        },
      ],
      synthesis: [
        {
          key: "receipt-gap",
          citesFinding: "candidates/synthesis.md §4.1 / §6 row 1",
          text:
            "Same rule-honesty-is-open-by-design receipt as corpus #1, applied identically at all " +
            "4 sites (one rule registration). Candidates/*.md citation -- see corpus #1's note for why.",
        },
      ],
    },
  },
  {
    id: "corpus-5-bigint-reachable",
    label: "Corpus #5: bigint branch reachability",
    provenance: "mined",
    citation:
      "first-slice-run.md, instance 5: “lib/bigint/init.lua:115 | " +
      "branch:then | schema=reachable”",
    facts: {
      shape: "branch_reachable",
      file: "lib/bigint/init.lua",
      line: 115,
      branch: "then",
      // Not a value-arm claim: reachability has no variable whose union
      // could be recovered from code or annotation. Explicit unknown-union
      // marker rather than invented arms -- the H1 middle-layer gap
      // surfacing in the encoding itself.
      claim: { subject: "branch:then@115", kind: "branch_reachable", unionArms: null, claimedArms: null },
      noRuleAvailable: true,
      lineSpan: { lineStart: 115, lineEnd: 117 },
    },
    source: {
      file: "lib/bigint/init.lua",
      excerpts: [
        {
          key: "mul_abs",
          lineStart: 97,
          lineEnd: 121,
          lines: [
            "-- Multiply magnitudes via schoolbook, return new digit array.",
            "--: (a: BigInt, b: BigInt) -> { [integer]: number }",
            "local function mul_abs(a, b)",
            "  local ad, bd = a.d, b.d",
            "  local an, bn = #ad, #bd",
            "  local r = {} --: { [integer]: number }",
            "  for i = 1, an + bn do r[i] = 0 end",
            "  for i = 1, an do",
            "    local ai = ad[i]",
            "    if ai ~= 0 then",
            "      local carry = 0",
            "      for j = 1, bn do",
            "        local pos = i + j - 1",
            "        local prod = ai * (bd[j] or 0) + (r[pos] or 0) + carry",
            "        -- Use floor division to split into chunk + carry.",
            "        carry = floor(prod / BASE)",
            "        r[pos] = prod - carry * BASE",
            "      end",
            "      if carry > 0 then",
            "        r[i + bn] = (r[i + bn] or 0) + carry",
            "      end",
            "    end",
            "  end",
            "  return r",
            "end",
          ],
        },
      ],
    },
    notes: {
      subtract: [],
      primitive: [],
      invert: [],
      evidence: [],
      "saturation-a": [],
      "saturation-b": [],
      synthesis: [],
    },
  },
  {
    id: "adversarial-subtract-false-proved",
    label: "Adversarial (a): plausible-but-wrong colon-self rule",
    provenance: "constructed",
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
      // Same arm-set re-encoding as corpus-1 (same code, same annotation).
      claim: { subject: "self", unionArms: ["Cache", "nil"], claimedArms: ["Cache"] },
      // Ground truth for THIS scenario, unlike corpus-1: a real counterexample
      // call exists. Colon *definition* syntax places no obligation on
      // *callers* -- per the attack: "Nothing stops `Cache.peek(nil, key)`".
      calledOnlyViaColon: false,
      counterexampleCall: "Cache.peek(nil, key)",
      defSpan: { lineStart: 154, lineEnd: 154 },
      useSpan: { lineStart: 155, lineEnd: 155, colStart: 16, colEnd: 20 },
    },
    source: {
      file: "lib/lru/init.lua",
      excerpts: [
        {
          key: "peek",
          lineStart: 152,
          lineEnd: 159,
          lines: [
            "-- Get without promoting. Returns nil if missing or expired.",
            "--: (Cache, unknown) -> unknown | nil",
            "function Cache:peek(key)",
            "  local node = self._map[key]",
            "  if not node then return nil end",
            "  if _check_expired(self, node) then return nil end",
            "  return node.value",
            "end",
          ],
        },
      ],
    },
    notes: {
      subtract: [
        {
          key: "mechanism",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text:
            "kernel re-executes colon-self-nonnil-v1(premises, target) itself: def.form==\"colon\" " +
            "&& def.receiver_param==target.expr && target.claim==\"non-nil\" -- this NEVER inspects " +
            "any call site.",
        },
        {
          key: "counterexample",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text:
            "A real counterexample call exists in this scenario (Cache.peek(nil, key)), but the " +
            "rule as written cannot see it: \"Colon *definition* syntax... only sugars an implicit " +
            "`self` parameter -- it places zero obligation on *callers*. Nothing stops " +
            "`Cache.peek(nil, key)`... The kernel re-executes this exact `check` faithfully, gets " +
            "`true`, and mints Proved.\"",
        },
        {
          key: "verdict",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text:
            "FALSE PROVED: the rule establishes only \"this function was defined with colon " +
            "sugar,\" a different, weaker fact than \"self is non-nil at this dereference,\" yet " +
            "the kernel mints Proved anyway.",
        },
      ],
      primitive: [
        {
          key: "witness-bug",
          citesFinding: "primitive-attack.md#attack-0-the-flagship-demo-does-not-run-as-claimed--fatal",
          text:
            "mined_deref_nonnil.check has no \"unknown\" branch for absent data; witness.value == " +
            "nil falls straight to \"reject\".",
        },
        {
          key: "disagreement",
          citesFinding: "primitive-attack.md#attack-0-the-flagship-demo-does-not-run-as-claimed--fatal",
          text:
            "Refutes for the WRONG reason: via the nil/absent conflation bug, not by detecting the " +
            "real counterexample call (Cache.peek(nil, key)) that also exists here. The design " +
            "never actually reaches that fact.",
        },
      ],
      invert: [
        {
          key: "underspecified",
          citesFinding: "invert-attack.md#1-the-five-witnessproof-walkthroughs-dont-actually-go-through-as-formalized-fatal",
          text:
            "Same unconstructible certificate as corpus #1 -- the static-parse-fact premise has " +
            "no certificate kind to carry it, independent of whether a counterexample call exists.",
        },
      ],
      evidence: [
        {
          key: "escape-blind",
          citesFinding: "evidence-attack.md#attack-4--re-deriving-instance-1-colon-method-self-non-nil-the-invariant-as-sketched-is-not-actually-inductive-over-the-real-execution-set",
          text:
            "oracle.entries(Cache:peek) is a static enumeration of colon-call sites; a first-class " +
            "escape or dot-call counterexample (Cache.peek(nil, key)) is invisible to that " +
            "enumeration. check_box walks only what it enumerated, finds the invariant holds " +
            "everywhere it looked, and mints Proved.",
        },
      ],
      "saturation-a": [
        {
          key: "same-break",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text:
            "Restated in Datalog, the rule pattern-matches the exact same definition-site-only " +
            "premise as subtract's rule -- wrong for the identical reason, real counterexample or not.",
        },
      ],
      "saturation-b": [
        {
          key: "same-break",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text: "Same unsound rewrite content as subtract's rule; no merge opportunity with only one fact in the store.",
        },
      ],
      synthesis: [
        {
          key: "receipt-gap",
          citesFinding: "candidates/synthesis.md §4.1 / §6 row 1",
          text:
            "Rule-honesty is kernel-unverifiable in principle; the receipt now visibly states " +
            "\"universal claim, evidence cited = definition-site fact only, no call-site-" +
            "completeness certificate\" -- still citing the same unsoundness subtract-attack.md " +
            "Attack 1 found. Candidates/*.md citation (see corpus #1's note for why no " +
            "judgments/*.md anchor applies).",
        },
      ],
    },
  },
  {
    id: "adversarial-saturation-b-identity-merge",
    label: "Adversarial (b): saturation-B identity-merge amplification",
    provenance: "constructed",
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
        defLine: 154,
        useLine: 155,
        defSpan: { lineStart: 154, lineEnd: 154 },
        useSpan: { lineStart: 155, lineEnd: 155, colStart: 16, colEnd: 20 },
        source: {
          file: "lib/lru/init.lua",
          excerpts: [
            {
              key: "peek",
              lineStart: 152,
              lineEnd: 159,
              lines: [
                "-- Get without promoting. Returns nil if missing or expired.",
                "--: (Cache, unknown) -> unknown | nil",
                "function Cache:peek(key)",
                "  local node = self._map[key]",
                "  if not node then return nil end",
                "  if _check_expired(self, node) then return nil end",
                "  return node.value",
                "end",
              ],
            },
          ],
        },
      },
      // factB: genuinely true, no counterexample.
      factB: {
        file: "lib/deque/init.lua",
        funcName: "Deque:pop_front",
        defForm: "colon",
        derefName: "self",
        calledOnlyViaColon: true,
        defLine: 58,
        useLines: [62, 63, 64, 65],
        defSpan: { lineStart: 58, lineEnd: 58 },
        useSpans: [
          { lineStart: 62, lineEnd: 62, colStart: 15, colEnd: 19 },
          { lineStart: 63, lineEnd: 63, colStart: 12, colEnd: 16 },
          { lineStart: 64, lineEnd: 64, colStart: 2, colEnd: 6 },
          { lineStart: 65, lineEnd: 65, colStart: 2, colEnd: 6 },
        ],
        source: {
          file: "lib/deque/init.lua",
          excerpts: [
            {
              key: "pop_front",
              lineStart: 56,
              lineEnd: 67,
              lines: [
                "--- Pop a value from the front. Returns nil if empty.",
                "--: (Deque) -> unknown | nil",
                "function Deque:pop_front()",
                "\tif self._head > self._tail then",
                "\t\treturn nil",
                "\tend",
                "\tlocal head = self._head",
                "\tlocal v = self._data[head]",
                "\tself._data[head] = nil",
                "\tself._head = head + 1",
                "\treturn v",
                "end",
              ],
            },
          ],
        },
      },
    },
    notes: {
      subtract: [
        {
          key: "contrast",
          citesFinding: "subtract-attack.md#attack-1--the-flagship-worked-example-is-itself-an-unsound-rule-fatal",
          text:
            "subtract's Pool/Edge model never merges or rewrites pool entries -- Cache:peek's " +
            "claim and Deque:pop_front's claim each carry their own edges, keeping separate ids. " +
            "No identity-merge amplification is possible in this kernel shape at all.",
        },
      ],
      primitive: [
        {
          key: "independent-bug",
          citesFinding: "primitive-attack.md#attack-0-the-flagship-demo-does-not-run-as-claimed--fatal",
          text:
            "primitive has no merge/rewrite mechanism either -- pool entries are independent claim " +
            "closures, never unioned. Both A and B happen to hit the SAME nil/absent-conflation bug " +
            "independently, not via any shared amplification path.",
        },
      ],
      invert: [
        {
          key: "independent-underspec",
          citesFinding: "invert-attack.md#1-the-five-witnessproof-walkthroughs-dont-actually-go-through-as-formalized-fatal",
          text:
            "invert's pool is a dependency graph over certificate ids, never a rewrite/merge " +
            "system -- no equivalence classes exist to collapse. Both A and B independently hit " +
            "the same unconstructible-certificate problem, as two separate, non-interacting entries.",
        },
      ],
      evidence: [
        {
          key: "no-shared-amplification",
          citesFinding: "evidence-attack.md#attack-4--re-deriving-instance-1-colon-method-self-non-nil-the-invariant-as-sketched-is-not-actually-inductive-over-the-real-execution-set",
          text:
            "evidence's citation graph never merges/unifies pool entries into a shared identity -- " +
            "`unify` only ever reconciles term variables at citation time, never collapses two " +
            "different claims' truth values into one. Same underlying oracle.entries() blind spot " +
            "hits A independently of B.",
        },
      ],
      "saturation-a": [
        {
          key: "blast-radius",
          citesFinding: "subtract-attack.md#attack-2--fuel-bounded-re-execution-buys-reproducibility-not-soundness-serious",
          text:
            "Reading A never merges or deletes ground atoms -- the store only grows. A wrong rule " +
            "adds one wrong fact to the store, exactly as a wrong incumbent rule adds one wrong " +
            "edge -- the blast radius is the same: \"one wrong mined fact poisons every claim " +
            "reachable from it\" applies verbatim, unchanged. No amplification beyond that " +
            "ordinary blast radius.",
        },
      ],
      "saturation-b": [
        {
          key: "merge-mechanism",
          citesFinding: "subtract-attack.md#attack-2--fuel-bounded-re-execution-buys-reproducibility-not-soundness-serious",
          text:
            "The plausible-but-wrong rewrite rule (this engine's mandatory adversarial case): " +
            "canonicalize any nonnil_binding(self, _) term to ONE shared equivalence class keyed " +
            "only on the receiver name \"self\", discarding which method it came from -- a real, " +
            "irreversible egraph-style merge, not an added fact. This is the identity-merge " +
            "amplification failure named in candidates/saturation.md §4; it is the same underlying " +
            "mechanism as subtract-attack.md Attack 2's \"one wrong mined fact poisons every claim " +
            "reachable from it,\" but sharper under rewriting because the poisoned fact and the " +
            "genuine one become the SAME store entry, not merely reachable from each other.",
        },
        {
          key: "amplification",
          citesFinding: "subtract-attack.md#attack-2--fuel-bounded-re-execution-buys-reproducibility-not-soundness-serious",
          text:
            "B's derivation (genuinely true) supplies `supports` for the merged canonical " +
            "representative. Because A and B are now the same identity in the term store, that " +
            "`supports` verdict is read back for A too -- even though A has a real counterexample " +
            "that should have kept it at Open or Refuted. \"A wrong rewrite rewrites the world.\"",
        },
      ],
      synthesis: [
        {
          key: "no-merge-mechanism",
          citesFinding: "candidates/synthesis.md §1",
          text:
            "synthesis's base is subtract's Pool/Edge model -- it never adopted any term-rewriting/" +
            "merge mechanism (that's saturation-B's Reading, evaluated in a later document and not " +
            "folded into this synthesis). A's claim and B's claim keep separate ids/edges " +
            "throughout, in contrast to saturation-B's engine on this same scenario. Candidates/*.md " +
            "citation: this is a synthesis.md self-scoping statement, not something any of the " +
            "four judgments/*.md attacks (which review subtract/primitive/evidence/invert, not " +
            "synthesis) directly discuss.",
        },
      ],
    },
  },

  // -----------------------------------------------------------------------
  // Hand-derived scenarios (provenance "hand"). Real code, real line
  // numbers; claims hand-derived by reading the code. Generic union-arm
  // membership encoding throughout -- nil is an ordinary arm.
  // -----------------------------------------------------------------------
  {
    id: "hand-json-type-guard",
    label: "Hand #1: json type() guard — number arm (nil not the interesting arm)",
    provenance: "hand",
    citation: "hand-derived; code: lib/json/init.lua:407-428",
    facts: {
      shape: "hand_claims",
      file: "lib/json/init.lua",
      claims: [
        {
          id: "val-number-arm",
          subject: "val",
          unionArms: ["nil", "boolean", "number", "string", "table", "function", "userdata", "thread"],
          claimedArms: ["number"],
          site: { lineStart: 416, lineEnd: 416, colStart: 16, colEnd: 18 },
          evidence: {
            // subject derived from boundFrom "type(val)" at lib/json/init.lua:408
            // (`local t = type(val)`) -- the guarded variable is `val`, matching
            // claim.subject exactly.
            subject: "val",
            kind: "type_guard",
            guardVar: "t",
            boundFrom: "type(val)",
            guardLine: 415,
            establishesArms: ["number"],
            span: { lineStart: 408, lineEnd: 415 },
          },
          groundTruth: true,
        },
      ],
    },
    source: {
      file: "lib/json/init.lua",
      excerpts: [
        {
          key: "encode_value",
          lineStart: 406,
          lineEnd: 428,
          lines: [
            "--: (unknown, { indent: number | nil, sort_keys: boolean | nil } | nil, integer) -> (string | nil, string | nil)",
            "encode_value = function(val, opts, depth)",
            "\tlocal t = type(val)",
            "\tif val == M.null then",
            "\t\treturn \"null\", nil",
            "\telseif t == \"nil\" then",
            "\t\treturn \"null\", nil",
            "\telseif t == \"boolean\" then",
            "\t\treturn val and \"true\" or \"false\", nil",
            "\telseif t == \"number\" then",
            "\t\tlocal nval = val --[[:! number]]",
            "\t\tif nval ~= nval then return nil, \"json.encode: NaN is not allowed\" end",
            "\t\tif nval == huge or nval == -huge then return nil, \"json.encode: Infinity is not allowed\" end",
            "\t\t-- Represent integers without decimal point; handle negative zero as 0",
            "\t\tif nval == floor(nval) and nval >= -1e15 and nval <= 1e15 then",
            "\t\t\tif nval == 0 then return \"0\", nil end",
            "\t\t\treturn format(\"%.0f\", nval), nil",
            "\t\tend",
            "\t\t-- Use shortest representation",
            "\t\tlocal s = format(\"%.17g\", nval)",
            "\t\treturn s, nil",
            "\telseif t == \"string\" then",
            "\t\treturn encode_string(val --[[:! string]]), nil",
          ],
        },
      ],
    },
    notes: {
      subtract: [], primitive: [], invert: [], evidence: [],
      "saturation-a": [], "saturation-b": [], synthesis: [],
    },
  },
  {
    id: "hand-bigint-err-arm",
    label: "Hand #2: bigint (nil, errmsg) error-path arms",
    provenance: "hand",
    citation: "hand-derived; code: lib/bigint/init.lua:291-308",
    facts: {
      shape: "hand_claims",
      file: "lib/bigint/init.lua",
      claims: [
        {
          id: "ret1-nil-arm",
          subject: "M.new return#1 (type-error path)",
          unionArms: ["BigInt", "nil"],
          claimedArms: ["nil"],
          site: { lineStart: 305, lineEnd: 305, colStart: 12, colEnd: 14 },
          evidence: {
            // subject derived from lib/bigint/init.lua:305's first return value
            // (`return nil, ...`) -- matches claim.subject exactly, the
            // type-error path's first return slot.
            subject: "M.new return#1 (type-error path)",
            kind: "guard_return",
            guardLine: 304,
            returnedForm: "nil_literal",
            establishesArms: ["nil"],
            span: { lineStart: 304, lineEnd: 306 },
          },
          groundTruth: true,
        },
        {
          id: "ret2-string-arm",
          subject: "M.new return#2 (type-error path)",
          unionArms: ["string", "nil"],
          claimedArms: ["string"],
          site: { lineStart: 305, lineEnd: 305, colStart: 17, colEnd: 66 },
          evidence: {
            // subject derived from lib/bigint/init.lua:305's second return value
            // (the `.. type(v)` string-concat expression) -- matches
            // claim.subject exactly, the type-error path's second return slot.
            subject: "M.new return#2 (type-error path)",
            kind: "guard_return",
            guardLine: 304,
            returnedForm: "string_concat_literal",
            establishesArms: ["string"],
            span: { lineStart: 304, lineEnd: 306 },
          },
          groundTruth: true,
        },
      ],
    },
    source: {
      file: "lib/bigint/init.lua",
      excerpts: [
        {
          key: "new",
          lineStart: 291,
          lineEnd: 308,
          lines: [
            "-- Create a bigint from a string or number.",
            "--: (v: unknown) -> (BigInt | nil, string | nil)",
            "function M.new(v)",
            "  if type(v) == \"table\" and getmetatable(v) == mt then",
            "    -- Clone",
            "    local v_ = v --[[:! BigInt]]",
            "    local d = {}",
            "    for i = 1, #v_.d do d[i] = v_.d[i] end",
            "    return from_raw(d, v_.s)",
            "  end",
            "  if type(v) == \"number\" then",
            "    v = (\"%.0f\"):format(v)",
            "  end",
            "  if type(v) ~= \"string\" then",
            "    return nil, \"bigint.new: expected string or number, got \" .. type(v)",
            "  end",
            "  local s = v:match(\"^%s*(.-)%s*$\") -- trim",
            "  if s == \"\" then return nil, \"bigint.new: empty string\" end",
          ],
        },
      ],
    },
    notes: {
      subtract: [], primitive: [], invert: [], evidence: [],
      "saturation-a": [], "saturation-b": [], synthesis: [],
    },
  },
  {
    id: "hand-lru-field-shape",
    label: "Hand #3: lru constructor table shape — field arms",
    provenance: "hand",
    citation: "hand-derived; code: lib/lru/init.lua:77-101",
    facts: {
      shape: "hand_claims",
      file: "lib/lru/init.lua",
      claims: [
        {
          id: "map-table-arm",
          subject: "Cache._map",
          unionArms: ["table", "nil"],
          claimedArms: ["table"],
          site: { lineStart: 91, lineEnd: 91 },
          evidence: {
            // subject derived from lib/lru/init.lua:91 (`_map = {}`) -- the
            // assigned field is `_map` on the constructed Cache, matching
            // claim.subject exactly.
            subject: "Cache._map",
            kind: "field_assign",
            valueForm: "table_literal",
            establishesArms: ["table"],
            span: { lineStart: 91, lineEnd: 91 },
          },
          groundTruth: true,
        },
        {
          id: "ttl-number-arm",
          subject: "Cache._ttl",
          unionArms: ["number", "nil"],
          claimedArms: ["number"],
          site: { lineStart: 94, lineEnd: 94 },
          evidence: {
            // subject derived from lib/lru/init.lua:94 (`_ttl = o.ttl`) -- the
            // assigned field is `_ttl` on the constructed Cache, matching
            // claim.subject exactly.
            subject: "Cache._ttl",
            kind: "field_assign",
            valueForm: "opt_expr", // o.ttl -- optional, may be nil
            establishesArms: null,
            span: { lineStart: 94, lineEnd: 94 },
          },
          // opts.ttl is documented optional; the nil arm is real.
          groundTruth: false,
        },
      ],
    },
    source: {
      file: "lib/lru/init.lua",
      excerpts: [
        {
          key: "new",
          lineStart: 77,
          lineEnd: 101,
          lines: [
            "-- Create a new LRU cache with the given maximum capacity.",
            "-- opts.ttl: default TTL in seconds (optional)",
            "-- opts.on_evict: callback(key, value) on eviction (optional)",
            "-- opts.clock: injectable clock (required for TTL)",
            "--: (number, LruOpts | nil) -> Cache | (nil, string)",
            "function M.new(capacity, opts)",
            "  if type(capacity) ~= \"number\" or capacity < 1 then",
            "    return nil, \"capacity must be a positive number\"",
            "  end",
            "  local cap = math.floor(capacity --[[:! number]])",
            "  local o = opts or {} --[[:! LruOpts]]",
            "  return setmetatable({",
            "    _cap       = cap,",
            "    _size      = 0,",
            "    _map       = {},",
            "    _head      = nil,",
            "    _tail      = nil,",
            "    _ttl       = o.ttl,",
            "    _on_evict  = o.on_evict,",
            "    _clock     = o.clock,",
            "    _hits      = 0,",
            "    _misses    = 0,",
            "    _evictions = 0,",
            "  }, Cache) --[[:! Cache]]",
            "end",
          ],
        },
      ],
    },
    notes: {
      subtract: [], primitive: [], invert: [], evidence: [],
      "saturation-a": [], "saturation-b": [], synthesis: [],
    },
  },
  {
    id: "hand-lru-closure-upvalue",
    label: "Hand #4: lru iterator closure — captured upvalue arms",
    provenance: "hand",
    citation: "hand-derived; code: lib/lru/init.lua:248-264",
    facts: {
      shape: "hand_claims",
      file: "lib/lru/init.lua",
      claims: [
        {
          id: "cache-upvalue-arm",
          subject: "upvalue cache",
          unionArms: ["Cache", "nil"],
          claimedArms: ["Cache"],
          site: { lineStart: 252, lineEnd: 252, colStart: 9, colEnd: 13 },
          evidence: {
            // subject derived from lib/lru/init.lua:252 (`local cache = self`)
            // -- the captured local is named `cache`, matching claim.subject
            // exactly.
            subject: "upvalue cache",
            kind: "upvalue_capture",
            capturedFrom: "self",
            reassignedInClosure: false,
            establishesArms: ["Cache"],
            span: { lineStart: 252, lineEnd: 252 },
          },
          groundTruth: true,
        },
        {
          id: "node-upvalue-arm",
          subject: "upvalue node",
          unionArms: ["LruNode", "nil"],
          claimedArms: ["LruNode"],
          site: { lineStart: 253, lineEnd: 253, colStart: 9, colEnd: 12 },
          evidence: {
            // subject derived from lib/lru/init.lua:253 (`local node =
            // self._head`), reassigned at :257 (`node = node.next`) -- the
            // captured/reassigned local is named `node`, matching
            // claim.subject exactly.
            subject: "upvalue node",
            kind: "upvalue_capture",
            capturedFrom: "self._head",
            reassignedInClosure: true, // node = node.next at 257
            establishesArms: null,
            span: { lineStart: 253, lineEnd: 257 },
          },
          // node reaches the nil arm at exhaustion (line 257 walks off the
          // list); nil is an ordinary arm this claim wrongly excludes.
          groundTruth: false,
        },
      ],
    },
    source: {
      file: "lib/lru/init.lua",
      excerpts: [
        {
          key: "iter",
          lineStart: 248,
          lineEnd: 264,
          lines: [
            "-- Iterator over (key, value) pairs, most recently used first.",
            "-- Expired entries are lazily removed during iteration.",
            "--: (Cache) -> (() -> (unknown, unknown) | nil)",
            "function Cache:iter()",
            "  local cache = self --[[:! Cache]]",
            "  local node = self._head",
            "  return function()",
            "    while node do",
            "      local current = node --[[:! LruNode]]",
            "      node = node.next",
            "      if not _check_expired(cache, current) then",
            "        return current.key, current.value",
            "      end",
            "    end",
            "    return nil",
            "  end",
            "end",
          ],
        },
      ],
    },
    notes: {
      subtract: [], primitive: [], invert: [], evidence: [],
      "saturation-a": [], "saturation-b": [], synthesis: [],
    },
  },
  {
    id: "hand-json-generic-for",
    label: "Hand #5: json generic-for — pairs() control var excludes nil arm",
    provenance: "hand",
    citation: "hand-derived; code: lib/json/init.lua:429-443",
    facts: {
      shape: "hand_claims",
      file: "lib/json/init.lua",
      claims: [
        {
          id: "k-nonterminator-arms",
          subject: "k",
          unionArms: ["nil", "boolean", "number", "string", "table", "function"],
          // Everything except nil -- expressed as an ordinary arm subset,
          // not a non-nil primitive. pairs()'s protocol: nil is the
          // termination signal, so the loop body never sees the nil arm.
          claimedArms: ["boolean", "number", "string", "table", "function"],
          site: { lineStart: 437, lineEnd: 437, colStart: 7, colEnd: 7 },
          evidence: {
            // subject derived from lib/json/init.lua:437 (`for k in
            // pairs(tval) do`) -- the loop control variable is `k`, matching
            // claim.subject exactly.
            subject: "k",
            kind: "generic_for_protocol",
            iterator: "pairs",
            establishesArms: ["boolean", "number", "string", "table", "function"],
            span: { lineStart: 437, lineEnd: 443 },
          },
          groundTruth: true,
        },
      ],
    },
    source: {
      file: "lib/json/init.lua",
      excerpts: [
        {
          key: "is-array-scan",
          lineStart: 429,
          lineEnd: 443,
          lines: [
            "\telseif t == \"table\" then",
            "\t\t-- Determine array vs object: array if sequential integer keys from 1",
            "\t\t-- An empty table with no keys encodes as array []",
            "\t\tlocal tval = val --[[:! { [integer]: unknown }]]",
            "\t\tlocal n = #tval",
            "\t\tlocal is_array = true",
            "\t\t-- Check that table has no non-integer or out-of-range keys",
            "\t\tlocal count = 0",
            "\t\tfor k in pairs(tval) do",
            "\t\t\tcount = count + 1",
            "\t\t\tif type(k) ~= \"number\" or floor(k --[[:! number]]) ~= k or (k --[[:! number]]) < 1 or (k --[[:! number]]) > n then",
            "\t\t\t\tis_array = false",
            "\t\t\t\tbreak",
            "\t\t\tend",
            "\t\tend",
          ],
        },
      ],
    },
    notes: {
      subtract: [], primitive: [], invert: [], evidence: [],
      "saturation-a": [], "saturation-b": [], synthesis: [],
    },
  },
];
