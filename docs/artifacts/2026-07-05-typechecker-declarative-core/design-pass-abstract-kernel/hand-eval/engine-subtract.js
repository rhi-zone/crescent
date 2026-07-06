// engine-subtract.js
//
// Reproduces candidates/subtract.md: Pool (opaque ids + opaque payload),
// Edge (rule, premises, target, polarity) with kernel re-execution of
// rule.check, an acyclicity check at edge-admission time, and close() as a
// monotone least-fixpoint over supports/refutes edges.
//
// Faithfully reproduces the design's OWN flagship bug: `colon-self-nonnil-v1`
// (candidates/subtract.md §2.2) checks only the *definition* site
// (`def.form == "colon"`) and never inspects call sites. All narrative
// commentary about WHY that is a bug (citations, quotes, judgment findings)
// lives in scenario.notes[<engineId>] as data -- this file only computes
// structural step descriptions and looks up the matching note by key.
//
// This file is a PRODUCER/adapter over the shared scenario facts, not kernel
// code -- it plays the role of "producer B/C" in subtract.md §2.2. The
// kernel loop itself (admit/submit/close, acyclicity, fixpoint) is real and
// generic; it is not special-cased per scenario.

window.runSubtractEngine = function (scenario) {
  const f = scenario.facts;
  const notes = (scenario.notes && scenario.notes.subtract) || [];
  function note(key) {
    return notes.find((n) => n.key === key);
  }
  const snaps = [];
  let stepNo = 0;
  function snap(description, state, verdict, spans) {
    stepNo += 1;
    const s = { step: stepNo, description: description, state: state };
    if (verdict) s.verdict = verdict;
    if (spans) s.spans = spans;
    snaps.push(s);
  }
  function spanOf(fileFacts, span) {
    if (!span) return null;
    return Object.assign({ file: fileFacts }, span);
  }

  // --- generic kernel state ---------------------------------------------
  const pool = []; // { id, payload, provenance }
  const edges = []; // { id, rule, premises: [ids], target: id, polarity }
  let nextId = 1;
  function admit(payload, provenance) {
    const id = "p" + nextId++;
    pool.push({ id: id, payload: payload, provenance: provenance || "mined" });
    return id;
  }
  function poolState() {
    return { pool: pool.map((p) => ({ id: p.id, payload: p.payload, provenance: p.provenance })) };
  }
  // Acyclicity: bounded DFS from target through premises (subtract.md's own
  // prose description, not the "union-find" claim judgments/subtract-attack.md
  // Attack 6 found incorrect -- this engine implements the DFS version).
  function wouldCycle(target, premises) {
    const seen = {};
    const stack = premises.slice();
    while (stack.length) {
      const cur = stack.pop();
      if (cur === target) return true;
      if (seen[cur]) continue;
      seen[cur] = true;
      for (const e of edges) {
        if (e.target === cur) stack.push.apply(stack, e.premises);
      }
    }
    return false;
  }
  // submit: re-executes rule.check itself (kernel.submit, subtract.md §2.1).
  function submit(ruleId, checkFn, premises, target, polarity) {
    if (wouldCycle(target, premises)) {
      return { ok: false, reason: "would create a cycle" };
    }
    const premisePayloads = premises.map((id) => pool.find((p) => p.id === id).payload);
    const targetPayload = pool.find((p) => p.id === target).payload;
    const result = checkFn(premisePayloads, targetPayload); // kernel's own re-execution
    if (result !== true) return { ok: false, reason: "rule.check returned false" };
    const id = "e" + (edges.length + 1);
    edges.push({ id: id, rule: ruleId, premises: premises, target: target, polarity: polarity });
    return { ok: true, id: id };
  }
  // close(): monotone least fixpoint, refute-dominant.
  function close() {
    const verdict = {};
    for (const p of pool) verdict[p.id] = "open";
    let changed = true;
    while (changed) {
      changed = false;
      for (const e of edges) {
        const allProved = e.premises.every((id) => verdict[id] === "proved");
        if (allProved) {
          const want = e.polarity === "refutes" ? "refuted" : "proved";
          // refute dominates
          if (verdict[e.target] !== "refuted" && verdict[e.target] !== want) {
            verdict[e.target] = want;
            changed = true;
          }
        }
      }
    }
    return verdict;
  }
  function graphState(extraNote) {
    const st = poolState();
    st.edges = edges.map((e) => ({ id: e.id, rule: e.rule, premises: e.premises, target: e.target, polarity: e.polarity }));
    if (extraNote) st.note = extraNote;
    return st;
  }

  // --- the "colon-self-nonnil-v1" rule, verbatim in spirit --------------
  // subtract.md §2.2: `check = function(premises, target) return
  // def.form == "colon" and def.receiver_param == target.expr and
  // target.claim == "non-nil" end`. It never reads anything about call
  // sites -- that IS the bug this rule reproduces.
  function colonSelfNonnilV1Check(premises, target) {
    const def = premises[0];
    return def.form === "colon" && def.receiver_param === target.expr && target.claim === "non-nil";
  }

  function runColonSelfShape(fileName, derefName, funcName, defForm, defLine, useLine, receiverParam, schema, hasCounterexample, defSpan, useSpan) {
    const defId = admit(
      { form: defForm, def_line: defLine, receiver_param: receiverParam, kind: "def-form", file: fileName },
      "mined"
    );
    snap(
      "admit(pool, def-form payload) for " + funcName + " at " + fileName + ":" + defLine,
      graphState(),
      undefined,
      defSpan ? [spanOf(fileName, defSpan)] : undefined
    );
    const derefId = admit(
      { expr: derefName, claim: schema, kind: "presupposition", file: fileName, line: useLine },
      "mined"
    );
    snap(
      "admit(pool, presupposition payload) for deref:" + derefName + " at " + fileName + ":" + useLine,
      graphState(),
      undefined,
      useSpan ? [spanOf(fileName, useSpan)] : undefined
    );

    // Zero-premise axiom-style rule for the def-form fact itself (subtract.md
    // §2.2: "a producer submits a zero-premise edge for it").
    submit("def-form-read-from-parse-v1", () => true, [], defId, "supports");
    snap(
      "submit(pool, def-form-read-from-parse-v1, premises={}, target=" + defId + ", supports) — axiom-style, zero premises",
      graphState()
    );

    submit("colon-self-nonnil-v1", colonSelfNonnilV1Check, [defId], derefId, "supports");
    const mechanismNote = note("mechanism");
    const counterexampleNote = hasCounterexample ? note("counterexample") : null;
    const submitNotes = [mechanismNote, counterexampleNote].filter(Boolean);
    snap(
      "submit(pool, colon-self-nonnil-v1, premises={" + defId + "}, target=" + derefId + ", supports)",
      graphState(submitNotes.length ? submitNotes.map((n) => n.text + " [" + n.citesFinding + "]").join(" ") : undefined),
      undefined,
      defSpan && useSpan ? [spanOf(fileName, defSpan), spanOf(fileName, useSpan)] : undefined
    );

    const verdicts = close();
    let finalVerdict = verdicts[derefId] === "proved" ? "Proved" : verdicts[derefId] === "refuted" ? "Disproved" : "Open";
    let flagged = false;
    if (hasCounterexample && finalVerdict === "Proved") {
      flagged = true;
      finalVerdict = "False-Proved-flagged";
    }
    const verdictNote = flagged ? note("verdict") : null;
    snap(
      "close(pool) — monotone fixpoint. Verdict for deref:" + derefName + " = " + finalVerdict,
      graphState(verdictNote ? verdictNote.text + " [" + verdictNote.citesFinding + "]" : undefined),
      finalVerdict,
      useSpan ? [spanOf(fileName, useSpan)] : undefined
    );
    return { derefId, finalVerdict };
  }

  if (f.shape === "colon_self_nonnil") {
    runColonSelfShape(
      f.file, f.derefName, f.funcName, f.defForm, f.defLine, f.useLine, f.receiverParam, f.schema,
      f.calledOnlyViaColon === false, f.defSpan, f.useSpan
    );
  } else if (f.shape === "colon_self_nonnil_multi") {
    // "H1's payoff is per-rule, not per-claim" -- subtract.md §3.1 instance 4:
    // one rule registration, reused against 4 different target ids, no kernel
    // change needed.
    const defId = admit(
      { form: f.defForm, def_line: f.defLine, receiver_param: f.receiverParam, kind: "def-form", file: f.file },
      "mined"
    );
    snap(
      "admit(pool, def-form payload) for " + f.funcName,
      graphState(),
      undefined,
      f.defSpan ? [spanOf(f.file, f.defSpan)] : undefined
    );
    submit("def-form-read-from-parse-v1", () => true, [], defId, "supports");
    const mechanismNote = note("mechanism");
    snap(
      "submit axiom edge for def-form fact (zero premises)",
      graphState(mechanismNote ? mechanismNote.text + " [" + mechanismNote.citesFinding + "]" : undefined)
    );

    let lastVerdict = "Open";
    f.useLines.forEach((useLine, idx) => {
      const derefId = admit(
        { expr: f.derefName, claim: f.schema, kind: "presupposition", file: f.file, line: useLine },
        "mined"
      );
      submit("colon-self-nonnil-v1", colonSelfNonnilV1Check, [defId], derefId, "supports");
      const useSpan = f.useSpans && f.useSpans[idx];
      snap(
        "submit(colon-self-nonnil-v1, premises={" + defId + "}, target=deref@" + useLine + ")",
        graphState(),
        undefined,
        useSpan ? [spanOf(f.file, useSpan)] : undefined
      );
      const verdicts = close();
      lastVerdict = verdicts[derefId] === "proved" ? "Proved" : "Open";
    });
    const blastNote = note("blast-radius");
    snap(
      "close(pool) after all 4 sites — every site: " + lastVerdict,
      graphState(blastNote ? blastNote.text + " [" + blastNote.citesFinding + "]" : undefined),
      "False-Proved-flagged",
      f.useSpans ? f.useSpans.map((s) => spanOf(f.file, s)) : undefined
    );
  } else if (f.shape === "single_assign_nonnil") {
    const assignId = admit(
      { assignment_count: f.assignmentCount, initial_value_kind: f.assignKind, name: f.name, file: f.file, line: f.assignLine, kind: "def-use" },
      "mined"
    );
    snap(
      "admit(pool, def-use payload) for " + f.name + " assignment at " + f.file + ":" + f.assignLine,
      graphState(),
      undefined,
      f.assignSpan ? [spanOf(f.file, f.assignSpan)] : undefined
    );
    const derefId = admit(
      { expr: f.name, claim: f.schema, kind: "presupposition", file: f.file, line: f.useLine },
      "mined"
    );
    snap(
      "admit(pool, presupposition payload) for deref:" + f.name + " at " + f.file + ":" + f.useLine,
      graphState(),
      undefined,
      f.useSpan ? [spanOf(f.file, f.useSpan)] : undefined
    );

    submit("assign-fact-read-from-parse-v1", () => true, [], assignId, "supports");
    snap("submit axiom edge for the assignment fact (zero premises)", graphState());

    function neverReassignedNonnilCheck(premises, target) {
      const def = premises[0];
      return def.assignment_count === 1 && def.initial_value_kind === "table" && def.name === target.expr;
    }
    submit("never-reassigned-nonnil", neverReassignedNonnilCheck, [assignId], derefId, "supports");
    const gapNote = note("gap");
    snap(
      "submit(never-reassigned-nonnil, premises={" + assignId + "}, target=" + derefId + ", supports)",
      graphState(gapNote ? gapNote.text + " [" + gapNote.citesFinding + "]" : undefined),
      undefined,
      f.assignSpan && f.useSpan ? [spanOf(f.file, f.assignSpan), spanOf(f.file, f.useSpan)] : undefined
    );
    const verdicts = close();
    const finalVerdict = verdicts[derefId] === "proved" ? "Proved" : "Open";
    snap("close(pool) — verdict = " + finalVerdict, graphState(), finalVerdict, f.useSpan ? [spanOf(f.file, f.useSpan)] : undefined);
  } else if (f.shape === "branch_reachable") {
    admit({ kind: "presupposition", claim: f.schema, file: f.file, line: f.line, branch: f.branch }, "mined");
    snap(
      "admit(pool, branch reachability presupposition) — no producer registered a rule for it",
      graphState(),
      undefined,
      f.lineSpan ? [spanOf(f.file, f.lineSpan)] : undefined
    );
    snap(
      "close(pool) — Open. No registered rule connects a branch:then presupposition payload to any reachability-evidence payload.",
      graphState(),
      "Open",
      f.lineSpan ? [spanOf(f.file, f.lineSpan)] : undefined
    );
  } else if (f.shape === "two_self_facts_for_merge") {
    // subtract's edge model has NO merge/rewrite mechanism at all -- premises
    // are always cited by explicit id. This scenario exists to CONTRAST
    // against saturation-B: subtract cannot amplify one fact's error into
    // another's, because there is no shared "canonical representative" two
    // distinct ids could ever be folded into.
    const a = f.factA, b = f.factB;
    const rA = runColonSelfShape(a.file, "self", a.funcName, a.defForm, a.defLine, a.useLine, "self", "non-nil",
      a.calledOnlyViaColon === false, a.defSpan, a.useSpan);
    const rB = runColonSelfShape(b.file, "self", b.funcName, b.defForm, b.defLine, (b.useLines && b.useLines[0]), "self", "non-nil",
      b.calledOnlyViaColon === false, b.defSpan, b.useSpans && b.useSpans[0]);
    const contrastNote = note("contrast");
    snap(
      a.funcName + " = " + rA.finalVerdict + ", " + b.funcName + " = " + rB.finalVerdict + " (no identity-merge mechanism exists in this kernel shape)",
      graphState(contrastNote ? contrastNote.text + " [" + contrastNote.citesFinding + "]" : undefined),
      "A=" + rA.finalVerdict + ", B=" + rB.finalVerdict + " (no amplification)"
    );
  }

  return snaps;
};
