// engine-synthesis.js
//
// Reproduces synthesis.md: subtract's Pool/Edge/acyclicity/close skeleton
// (base, §1) plus the accepted grafts (§3): strength admissibility
// (existential vs universal, graft 2), mandatory three-valued
// "supports"|"refutes"|"unknown" check + proved_witness/proved_claim split
// (graft 3), kernel-assigned provenance restored (graft 8), bounded-DFS
// acyclicity (graft 8), typed premise/target narrowing (graft 8/delta 7).
//
// Per synthesis.md §4.1 and the closure table §6 row 1: the flagship
// colon-self rule's soundness problem is explicitly OPEN, BY DESIGN --
// "rule-honesty is kernel-unverifiable in principle... Delta 2/3 make the
// gap visible in the receipt (a 'universal' claim citing only
// definition-site evidence) instead of silent, but cannot verify the
// rule's logic itself." This engine reproduces exactly that: the rule still
// fires (same content as subtract's), the edge still gets strength =
// "universal" (producer-declared, not derived -- the kernel cannot catch
// the mismatch), and close() still promotes it to proved_claim -- but the
// receipt now visibly states what evidence was actually cited, per
// synthesis.md §4.1's "what discipline/kernel property prevents it, going
// forward" paragraph.

window.runSynthesisEngine = function (scenario) {
  const f = scenario.facts;
  const snaps = [];
  let stepNo = 0;
  function snap(description, state, verdict) {
    stepNo += 1;
    const s = { step: stepNo, description: description, state: state };
    if (verdict) s.verdict = verdict;
    snaps.push(s);
  }

  function runSelfShape(funcName, hasCounterexample, counterexampleCall) {
    const pool = [];
    pool.push({ id: "def", payload: { form: "colon", receiver_param: "self" }, provenance: "mined" });
    pool.push({ id: "deref", payload: { expr: "self", claim: "non-nil" }, provenance: "mined" });
    snap(
      "admit_mined(pool, def-form payload, provenance=mined) and admit_mined(pool, " +
        "presupposition payload, provenance=mined) — provenance is KERNEL-ASSIGNED (graft " +
        "8/delta 4), fixed by which of exactly 3 entrypoints was called, not self-declared.",
      { pool: pool.slice() }
    );
    snap(
      "submit(pool, colon-self-nonnil-v1, premises={def}, target=deref, polarity=supports, " +
        "strength=\"universal\") — 1) type-shape-checks premises/target against declared " +
        "premise_types/target_type (delta 7, narrowing instead of raw `unknown`); 2) bounded " +
        "DFS acyclicity (delta 6, not union-find); 3) strength admissibility: this premise " +
        "(def-form fact) is itself only ever admitted directly (no prior edge), so no prior " +
        "strength conflict is detected — the MISMATCH between the rule's declared " +
        "\"universal\" strength and what its check body actually inspects (a definition-site " +
        "fact) is NOT something the kernel can catch (strength is producer-declared, " +
        "synthesis.md §4.1); 4) kernel re-executes check() sandboxed (delta 5) -> returns " +
        "\"supports\" (three-valued, delta 1/graft 3); 5) edge accepted.",
      { pool: pool.slice(), edges: [{ rule: "colon-self-nonnil-v1", premises: ["def"], target: "deref", polarity: "supports", strength: "universal" }] }
    );
    const closeNote =
      "close(pool): def -> proved_claim (zero-premise axiom-style edge, also declared " +
      "universal). deref's edge cites def at universal strength while def's own accepted " +
      "edge is itself universal (graft 2's admissibility check PASSES here — this is not " +
      "the invert-attack.md Attack 2 hole; that hole is about existential discharge, not " +
      "about rule CONTENT). deref -> proved_claim.";
    snap(closeNote, { pool: pool.slice() });
    const receiptNote =
      "Per synthesis.md §6 row 1 (\"OPEN, by design\") and §4.1: rule-honesty (is the " +
      "content of colon-self-nonnil-v1 actually sound?) is kernel-unverifiable in " +
      "principle — grafts 2/3 cannot verify the rule's LOGIC, only make the citation " +
      "shape visible. The receipt for this claim reads: \"universal claim, evidence " +
      "cited = definition-site fact only, no call-site-completeness certificate\" — " +
      "which is exactly the visible-not-silent gap synthesis.md describes, still citing " +
      "the same unsoundness judgments/subtract-attack.md Attack 1 found." +
      (hasCounterexample ? (" A real counterexample exists here: " + counterexampleCall + ".") : "");
    return { hasCounterexample: hasCounterexample, receiptNote: receiptNote };
  }

  if (f.shape === "colon_self_nonnil") {
    const r = runSelfShape(f.funcName, f.calledOnlyViaColon === false, f.counterexampleCall);
    snap(r.receiptNote, {}, r.hasCounterexample ? "False-Proved-flagged" : "Proved (flagged: receipt shows only definition-site evidence, per synthesis.md §4.1/§6 row 1)");
  } else if (f.shape === "colon_self_nonnil_multi") {
    const r = runSelfShape(f.funcName, false, null);
    snap(r.receiptNote + " Applied identically at all 4 sites (one rule registration).", {}, "Proved (flagged: receipt shows only definition-site evidence)");
  } else if (f.shape === "single_assign_nonnil") {
    const pool = [
      { id: "assign", payload: { assignment_count: f.assignmentCount, initial_value_kind: f.assignKind }, provenance: "mined" },
      { id: "deref", payload: { expr: f.name, claim: f.schema }, provenance: "mined" },
    ];
    snap("admit_mined for assignment fact and deref presupposition, typed per delta 7 (premise_types/target_type narrow the payload at the call boundary, closing the nil/absent conflation bug class from primitive-attack.md Attack 0, contingent on the narrowing mechanism actually being built).", { pool: pool.slice() });
    snap(
      "submit(never-reassigned-nonnil, premises={assign}, target=deref, strength=\"universal\") " +
        "— strength check passes trivially (assign has no prior edge to conflict with); " +
        "check() returns \"supports\".",
      { pool: pool.slice(), edges: [{ rule: "never-reassigned-nonnil", premises: ["assign"], target: "deref", polarity: "supports", strength: "universal" }] }
    );
    snap("close(pool): deref -> proved_claim.", { pool: pool.slice() }, "Proved");
  } else if (f.shape === "branch_reachable") {
    snap(
      "No rule registered connects a branch:then presupposition to any reachability " +
        "evidence — Open, with a receipt naming the missing rule (unchanged from subtract's " +
        "base skeleton, synthesis.md §1 chooses subtract as base specifically because this " +
        "part already worked).",
      {},
      "Open"
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    const a = f.factA, b = f.factB;
    const rA = runSelfShape(a.funcName, a.calledOnlyViaColon === false, a.counterexampleCall);
    snap(rA.receiptNote, {}, undefined);
    const rB = runSelfShape(b.funcName, false, null);
    snap(rB.receiptNote, {}, undefined);
    snap(
      "synthesis.md's base is subtract's Pool/Edge model (§1) — it never adopted any " +
        "term-rewriting/merge mechanism (that's saturation-B's Reading, evaluated in a " +
        "LATER document and not folded into this synthesis). " + a.funcName + "'s claim " +
        "and " + b.funcName + "'s claim keep separate ids/edges throughout — no identity " +
        "merge is structurally possible, so no cross-fact amplification occurs, in " +
        "contrast to saturation-B's engine on this same scenario.",
      {},
      "A=False-Proved-flagged (rule-honesty gap, same as always), B=Proved (genuine) — no amplification"
    );
  }

  return snaps;
};
