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
// colon-self rule's soundness problem is explicitly OPEN, BY DESIGN. This
// engine reproduces exactly that: the rule still fires (same content as
// subtract's), the edge still gets strength = "universal" (producer-
// declared, not derived), and close() still promotes it to proved_claim --
// but the receipt now visibly states what evidence was actually cited. All
// narrative commentary lives in scenario.notes.synthesis as data.

window.runSynthesisEngine = function (scenario) {
  const f = scenario.facts;
  const notes = (scenario.notes && scenario.notes.synthesis) || [];
  function note(key) {
    return notes.find((n) => n.key === key);
  }
  const snaps = [];
  let stepNo = 0;
  function snap(description, state, verdict, spans) {
    stepNo += 1;
    // Strip any top-level key on `state` whose value is JS `undefined`
    // (e.g. a conditional `note` that resolved to no note) -- an explicit
    // undefined value is the same disease as a missing `id` field: it
    // surfaces as the literal string "undefined" wherever a generic
    // renderer reads it. Source-level fix, not a display-time fallback.
    if (state && typeof state === "object") {
      for (const k in state) {
        if (Object.prototype.hasOwnProperty.call(state, k) && state[k] === undefined) delete state[k];
      }
    }
    const s = { step: stepNo, description: description, state: state };
    if (verdict) s.verdict = verdict;
    if (spans) s.spans = spans;
    snaps.push(s);
  }
  function spanOf(fileFacts, span) {
    if (!span) return null;
    return Object.assign({ file: fileFacts }, span);
  }

  function runSelfShape(funcName, hasCounterexample, counterexampleCall, fileName, defSpan, useSpan) {
    const pool = [];
    pool.push({ id: "def", payload: { form: "colon", receiver_param: "self" }, provenance: "mined" });
    pool.push({ id: "deref", payload: { expr: "self", claim: "non-nil" }, provenance: "mined" });
    snap(
      "admit_mined(pool, def-form payload, provenance=mined) and admit_mined(pool, presupposition payload, provenance=mined) — provenance is kernel-assigned, fixed by which of exactly 3 entrypoints was called.",
      { pool: pool.slice() },
      undefined,
      defSpan ? [spanOf(fileName, defSpan)] : undefined
    );
    snap(
      "submit(pool, colon-self-nonnil-v1, premises={def}, target=deref, polarity=supports, strength=\"universal\") — type-shape-checks premises/target, bounded-DFS acyclicity, strength admissibility (no prior edge conflict), kernel re-executes check() sandboxed -> \"supports\", edge accepted.",
      { pool: pool.slice(), edges: [{ rule: "colon-self-nonnil-v1", premises: ["def"], target: "deref", polarity: "supports", strength: "universal" }] },
      undefined,
      useSpan ? [spanOf(fileName, useSpan)] : undefined
    );
    snap(
      "close(pool): def -> proved_claim (zero-premise axiom-style edge, also declared universal). deref -> proved_claim.",
      { pool: pool.slice() }
    );
    const receiptNote = note("receipt-gap");
    const receiptText = receiptNote
      ? receiptNote.text + " [" + receiptNote.citesFinding + "]" +
        (hasCounterexample ? (" A real counterexample exists here: " + counterexampleCall + ".") : "")
      : "receipt for " + funcName + ": universal claim, evidence cited = definition-site fact only.";
    return { hasCounterexample: hasCounterexample, receiptNote: receiptText };
  }

  if (f.shape === "colon_self_nonnil") {
    const r = runSelfShape(f.funcName, f.calledOnlyViaColon === false, f.counterexampleCall, f.file, f.defSpan, f.useSpan);
    snap(r.receiptNote, {}, r.hasCounterexample ? "False-Proved-flagged" : "Proved (flagged: receipt shows only definition-site evidence)", f.useSpan ? [spanOf(f.file, f.useSpan)] : undefined);
  } else if (f.shape === "colon_self_nonnil_multi") {
    const r = runSelfShape(f.funcName, false, null, f.file, f.defSpan, f.useSpans && f.useSpans[0]);
    snap(r.receiptNote + " Applied identically at all 4 sites (one rule registration).", {}, "Proved (flagged: receipt shows only definition-site evidence)", f.useSpans ? f.useSpans.map((s) => spanOf(f.file, s)) : undefined);
  } else if (f.shape === "single_assign_nonnil") {
    const pool = [
      { id: "assign", payload: { assignment_count: f.assignmentCount, initial_value_kind: f.assignKind }, provenance: "mined" },
      { id: "deref", payload: { expr: f.name, subject: f.claim.subject, unionArms: f.claim.unionArms, claimedArms: f.claim.claimedArms }, provenance: "mined" },
    ];
    const narrowingNote = note("narrowing-contingency");
    snap(
      "admit_mined for assignment fact and deref presupposition, typed per delta 7 (premise_types/target_type narrow the payload at the call boundary).",
      { pool: pool.slice(), note: narrowingNote ? narrowingNote.text + " [" + narrowingNote.citesFinding + "]" : undefined },
      undefined,
      f.assignSpan ? [spanOf(f.file, f.assignSpan)] : undefined
    );
    snap(
      "submit(never-reassigned-nonnil, premises={assign}, target=deref, strength=\"universal\") — strength check passes trivially; check() returns \"supports\".",
      { pool: pool.slice(), edges: [{ rule: "never-reassigned-nonnil", premises: ["assign"], target: "deref", polarity: "supports", strength: "universal" }] },
      undefined,
      f.useSpan ? [spanOf(f.file, f.useSpan)] : undefined
    );
    snap("close(pool): deref -> proved_claim.", { pool: pool.slice() }, "Proved");
  } else if (f.shape === "branch_reachable") {
    snap(
      "No rule registered connects a branch:then presupposition to any reachability evidence — Open, with a receipt naming the missing rule (unchanged from subtract's base skeleton).",
      {},
      "Open",
      f.lineSpan ? [spanOf(f.file, f.lineSpan)] : undefined
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    const a = f.factA, b = f.factB;
    const rA = runSelfShape(a.funcName, a.calledOnlyViaColon === false, a.counterexampleCall, a.file, a.defSpan, a.useSpan);
    snap(rA.receiptNote, {}, undefined, a.useSpan ? [spanOf(a.file, a.useSpan)] : undefined);
    const rB = runSelfShape(b.funcName, false, null, b.file, b.defSpan, b.useSpans && b.useSpans[0]);
    snap(rB.receiptNote, {}, undefined, b.useSpans && b.useSpans[0] ? [spanOf(b.file, b.useSpans[0])] : undefined);
    const noMergeNote = note("no-merge-mechanism");
    snap(
      a.funcName + "'s claim and " + b.funcName + "'s claim keep separate ids/edges throughout — no identity merge is structurally possible.",
      { note: noMergeNote ? noMergeNote.text + " [" + noMergeNote.citesFinding + "]" : undefined },
      "A=False-Proved-flagged (rule-honesty gap, same as always), B=Proved (genuine) — no amplification"
    );
  } else if (f.shape === "hand_claims") {
    // Generic claim-kind shape: same Pool/Edge skeleton as subtract's base,
    // plus synthesis's strength field -- these claims are direct, locally-
    // grounded evidence (not the universal/existential distinction graft 2
    // targets), so strength is recorded honestly as "direct-evidence"
    // rather than forced into "universal". Pure set-inclusion check,
    // generic over every claim kind.
    // PLACEMENT: arm-subset entailment is producers.js content, re-executed
    // by this kernel like any other rule.check.
    const armsRule = (window.PRODUCER_RULES || []).filter((r) => r.id === "arm-subset-entailment-v1")[0];
    function armsCoverCheck(ev, target) {
      return armsRule ? armsRule.entails(ev, target) === "supports" : false;
    }
    const results = [];
    f.claims.forEach((claim) => {
      const pool = [
        { id: "ev:" + claim.id, payload: { evidence_kind: claim.evidence.kind, establishesArms: claim.evidence.establishesArms, subject: claim.subject }, provenance: "hand" },
        { id: "claim:" + claim.id, payload: { subject: claim.subject, unionArms: claim.unionArms, claimedArms: claim.claimedArms }, provenance: "hand" },
      ];
      snap(
        "admit_mined(pool, evidence payload, provenance=hand) and admit_mined(pool, claim payload, provenance=hand) for " + claim.subject,
        { pool: pool.slice() },
        undefined,
        claim.evidence.span ? [spanOf(f.file, claim.evidence.span)] : undefined
      );
      const holds = armsCoverCheck(pool[0].payload, pool[1].payload);
      snap(
        "submit(pool, arms-cover-v1, premises={ev:" + claim.id + "}, target=claim:" + claim.id + ", strength=\"direct-evidence\") — check() returns " +
          (holds ? "\"supports\"" : "false") + " (generic set-inclusion: claimedArms ⊆ evidence.establishesArms).",
        { pool: pool.slice(), edges: holds ? [{ rule: "arms-cover-v1", premises: ["ev:" + claim.id], target: "claim:" + claim.id, polarity: "supports", strength: "direct-evidence" }] : [] },
        undefined,
        claim.site ? [spanOf(f.file, claim.site)] : undefined
      );
      const v = holds ? "Proved" : "Open";
      snap("close(pool): claim:" + claim.id + " -> " + (holds ? "proved_claim" : "stays open (no edge admitted)"), { pool: pool.slice() }, v, claim.site ? [spanOf(f.file, claim.site)] : undefined);
      results.push(claim.id + "=" + v);
    });
    snap("All claims evaluated: " + results.join(", "), {}, results.join(", "));
  }

  return snaps;
};
