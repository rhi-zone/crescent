// app.js
//
// PURE RENDERER over pre-computed trace data (traces/*.trace.js, loaded as
// window.TRACES['<design>'] = {design, provenance, scenarios: {...}}) and
// real-source scenario data (scenarios.js, window.SCENARIOS). No evaluation
// logic executes here -- this file only reads trace/scenario data and paints
// it. producers.js is loaded for reference only (its rule text is cited by
// codeSpans in some traces); nothing here calls its `entails` functions.

(function () {
  var DESIGNS = [
    { id: "subtract", label: "subtract" },
    { id: "primitive", label: "primitive" },
    { id: "invert", label: "invert" },
    { id: "evidence", label: "evidence" },
    { id: "saturation-a", label: "saturation (Reading A: monotone accumulation)" },
    { id: "saturation-b", label: "saturation (Reading B: term rewriting)" },
    { id: "synthesis", label: "synthesis (composite proposal)" },
  ];

  var CONFIDENCE_ORDER = ["determined", "underdetermined", "unsure"];

  var designSelect = document.getElementById("design-select");
  var scenarioSelect = document.getElementById("scenario-select");
  var scenarioCitationEl = document.getElementById("scenario-citation");
  var scenarioProvenanceEl = document.getElementById("scenario-provenance");
  var traceProvenanceEl = document.getElementById("trace-provenance");
  var stepsListEl = document.getElementById("steps-list");
  var sourcePaneEl = document.getElementById("source-pane");
  var verdictRowEl = document.getElementById("verdict-row");
  var summaryTableEl = document.getElementById("summary-table");

  DESIGNS.forEach(function (d) {
    var opt = document.createElement("option");
    opt.value = d.id;
    opt.textContent = d.label;
    designSelect.appendChild(opt);
  });
  window.SCENARIOS.forEach(function (s) {
    var opt = document.createElement("option");
    opt.value = s.id;
    opt.textContent = s.label;
    scenarioSelect.appendChild(opt);
  });

  function findDesign(id) {
    for (var i = 0; i < DESIGNS.length; i++) if (DESIGNS[i].id === id) return DESIGNS[i];
    return null;
  }
  function findScenario(id) {
    for (var i = 0; i < window.SCENARIOS.length; i++) if (window.SCENARIOS[i].id === id) return window.SCENARIOS[i];
    return null;
  }
  function traceFor(designId, scenarioId) {
    var t = window.TRACES && window.TRACES[designId];
    if (!t || !t.scenarios) return null;
    return t.scenarios[scenarioId] || null;
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  // Verdict string -> CSS class. Verdicts are free-text per-design ("proved",
  // "Proved", "proved x4", "Proved (false)", "halt", ...) so this matches
  // case-insensitively on substrings actually observed in traces/*.json;
  // it never invents a taxonomy the data doesn't already contain.
  function verdictClass(v) {
    if (!v) return "v-none";
    var s = String(v).toLowerCase();
    if (s.indexOf("halt") !== -1) return "v-halt";
    if (s.indexOf("false") !== -1) return "v-flagged";
    if (s.indexOf("refuted") !== -1 || s.indexOf("disproved") !== -1) return "v-refuted";
    if (s.indexOf("proved") !== -1) return "v-proved";
    if (s.indexOf("open") !== -1) return "v-open";
    return "v-none";
  }

  function confidenceLabel(c) {
    return c || "(unspecified)";
  }
  function confidenceClass(c) {
    if (c === "determined") return "c-determined";
    if (c === "underdetermined") return "c-underdetermined";
    if (c === "unsure") return "c-unsure";
    return "c-none";
  }
  function confidenceIcon(c) {
    if (c === "determined") return "●"; // filled circle
    if (c === "underdetermined") return "◐"; // half circle
    if (c === "unsure") return "○"; // open circle
    return "?";
  }

  // ---------------------------------------------------------------------
  // Generic state renderer: state is a free-form flat key -> value bag,
  // shape varies per design (pool/edges/verdicts/store/witness/...). Render
  // every key as a labeled row; arrays/objects get compact JSON, not a
  // sprawling pretty-printed dump.
  // ---------------------------------------------------------------------
  function renderState(state) {
    var out = document.createElement("div");
    if (!state || typeof state !== "object") return out;
    var keys = Object.keys(state);
    if (!keys.length) return out;
    var table = document.createElement("table");
    table.className = "state-table";
    keys.forEach(function (k) {
      var tr = document.createElement("tr");
      var th = document.createElement("td");
      th.className = "state-key";
      th.textContent = k;
      var td = document.createElement("td");
      td.className = "state-val";
      var v = state[k];
      var text;
      if (v === null) text = "null";
      else if (typeof v === "string") text = v;
      else text = JSON.stringify(v);
      var pre = document.createElement("pre");
      pre.textContent = text;
      td.appendChild(pre);
      tr.appendChild(th);
      tr.appendChild(td);
      table.appendChild(tr);
    });
    out.appendChild(table);
    return out;
  }

  // ---------------------------------------------------------------------
  // Source pane: real Lua excerpt(s) for the current scenario, real line
  // numbers, bidirectional highlight between steps and source lines.
  //
  // scenario.source = { file, excerpts: [{ key, lineStart, lineEnd, lines }] }
  // OR (two_self_facts_for_merge scenarios) scenario.facts.factA.source /
  // scenario.facts.factB.source, same shape, each its own file.
  //
  // Trace codeSpans are { file, lines: [start, end] } and cite a mix of real
  // lib/*.lua source, design-doc .md files, and this harness's own
  // producers.js/scenarios.js -- only spans whose file matches a file
  // actually rendered in the source pane are highlightable; the rest are
  // shown as plain citation text.
  // ---------------------------------------------------------------------
  var sourceLineIndex = {}; // "file:line" -> row element
  var stepRefIndex = {}; // "file:line" -> [step numbers]
  var currentSteps = [];

  function getSourceSets(scenario) {
    if (scenario.source) {
      return [{ label: null, file: scenario.source.file, excerpts: scenario.source.excerpts }];
    }
    var sets = [];
    var f = scenario.facts;
    if (f && f.factA && f.factA.source) sets.push({ label: "A (" + f.factA.funcName + ")", file: f.factA.source.file, excerpts: f.factA.source.excerpts });
    if (f && f.factB && f.factB.source) sets.push({ label: "B (" + f.factB.funcName + ")", file: f.factB.source.file, excerpts: f.factB.source.excerpts });
    return sets;
  }

  function normalizeCodeSpans(step) {
    // step.codeSpans: [{ file, lines: [start, end] }] -> [{ file, lineStart, lineEnd }]
    return (step.codeSpans || []).map(function (cs) {
      return { file: cs.file, lineStart: cs.lines[0], lineEnd: cs.lines[1] };
    });
  }

  function buildStepRefIndex(sourceFiles) {
    stepRefIndex = {};
    currentSteps.forEach(function (step) {
      normalizeCodeSpans(step).forEach(function (span) {
        if (sourceFiles.indexOf(span.file) === -1) return;
        for (var line = span.lineStart; line <= span.lineEnd; line++) {
          var key = span.file + ":" + line;
          if (!stepRefIndex[key]) stepRefIndex[key] = [];
          if (stepRefIndex[key].indexOf(step.step) === -1) stepRefIndex[key].push(step.step);
        }
      });
    });
  }

  function renderSourcePane(scenario) {
    sourceLineIndex = {};
    sourcePaneEl.innerHTML = "";
    var sets = getSourceSets(scenario);
    if (!sets.length) {
      sourcePaneEl.textContent = "(no source excerpt recorded for this scenario)";
      return [];
    }
    var files = [];
    sets.forEach(function (set) {
      if (files.indexOf(set.file) === -1) files.push(set.file);
      var block = document.createElement("div");
      block.className = "source-block";
      var label = document.createElement("div");
      label.className = "source-label";
      label.textContent = (set.label ? set.label + " — " : "") + set.file;
      block.appendChild(label);
      var fileBox = document.createElement("div");
      fileBox.className = "source-file";
      (set.excerpts || []).forEach(function (ex) {
        ex.lines.forEach(function (text, idx) {
          var lineNo = ex.lineStart + idx;
          var row = document.createElement("div");
          row.className = "source-line";
          row.dataset.file = set.file;
          row.dataset.line = String(lineNo);
          var lnSpan = document.createElement("span");
          lnSpan.className = "ln";
          lnSpan.textContent = String(lineNo);
          var codeSpan = document.createElement("span");
          codeSpan.className = "code";
          codeSpan.textContent = text;
          codeSpan.dataset.raw = text;
          var refsSpan = document.createElement("span");
          refsSpan.className = "step-refs";
          row.appendChild(lnSpan);
          row.appendChild(codeSpan);
          row.appendChild(refsSpan);
          row.addEventListener("mouseenter", function () { onHoverSourceLine(set.file, lineNo, true); });
          row.addEventListener("mouseleave", function () { onHoverSourceLine(set.file, lineNo, false); });
          fileBox.appendChild(row);
          sourceLineIndex[set.file + ":" + lineNo] = row;
        });
      });
      block.appendChild(fileBox);
      sourcePaneEl.appendChild(block);
    });
    return files;
  }

  function clearSourceHighlight(cls) {
    for (var key in sourceLineIndex) {
      sourceLineIndex[key].classList.remove(cls);
    }
  }

  function highlightSpans(spans, cls) {
    clearSourceHighlight(cls);
    (spans || []).forEach(function (span) {
      if (!span || !span.file) return;
      for (var line = span.lineStart; line <= span.lineEnd; line++) {
        var row = sourceLineIndex[span.file + ":" + line];
        if (row) row.classList.add(cls);
      }
    });
  }

  function onHoverSourceLine(file, line, entering) {
    var key = file + ":" + line;
    var row = sourceLineIndex[key];
    if (!row) return;
    var refsSpan = row.querySelector(".step-refs");
    if (entering) {
      row.classList.add("hl-hover");
      var refs = stepRefIndex[key] || [];
      refsSpan.textContent = refs.length ? "← step " + refs.join(", ") : "";
      refs.forEach(function (n) {
        var stepEl = document.getElementById("step-" + n);
        if (stepEl) stepEl.classList.add("hl-hover");
      });
    } else {
      row.classList.remove("hl-hover");
      refsSpan.textContent = "";
      var refs2 = stepRefIndex[key] || [];
      refs2.forEach(function (n) {
        var stepEl = document.getElementById("step-" + n);
        if (stepEl) stepEl.classList.remove("hl-hover");
      });
    }
  }

  function wireStepHover(stepEl, step, sourceFiles) {
    stepEl.addEventListener("mouseenter", function () {
      var spans = normalizeCodeSpans(step).filter(function (s) { return sourceFiles.indexOf(s.file) !== -1; });
      highlightSpans(spans, "hl-hover");
    });
    stepEl.addEventListener("mouseleave", function () {
      clearSourceHighlight("hl-hover");
    });
  }

  // ---------------------------------------------------------------------
  // Steps list.
  // ---------------------------------------------------------------------
  function renderCodeSpanChips(step, sourceFiles) {
    var wrap = document.createElement("div");
    wrap.className = "code-spans";
    normalizeCodeSpans(step).forEach(function (span) {
      var chip = document.createElement("span");
      var isLive = sourceFiles.indexOf(span.file) !== -1;
      chip.className = "span-chip" + (isLive ? " live" : "");
      chip.textContent = span.file + ":" + span.lineStart + (span.lineEnd !== span.lineStart ? "-" + span.lineEnd : "");
      wrap.appendChild(chip);
    });
    return wrap;
  }

  function renderSteps(trace, sourceFiles) {
    stepsListEl.innerHTML = "";
    currentSteps = (trace && trace.steps) || [];
    if (!currentSteps.length) {
      stepsListEl.textContent = "(no steps recorded)";
      return;
    }
    currentSteps.forEach(function (step) {
      var card = document.createElement("div");
      card.className = "step-card";
      card.id = "step-" + step.step;

      var head = document.createElement("div");
      head.className = "step-head";
      var stepNo = document.createElement("span");
      stepNo.className = "step-no";
      stepNo.textContent = "Step " + step.step;
      var badge = document.createElement("span");
      badge.className = "badge conf-badge " + confidenceClass(step.confidence);
      badge.title = "confidence: " + confidenceLabel(step.confidence);
      badge.innerHTML = '<span class="conf-icon">' + confidenceIcon(step.confidence) + "</span> " + escapeHtml(confidenceLabel(step.confidence));
      head.appendChild(stepNo);
      head.appendChild(badge);
      card.appendChild(head);

      var desc = document.createElement("div");
      desc.className = "step-desc";
      desc.textContent = step.description || "";
      card.appendChild(desc);

      card.appendChild(renderState(step.state));
      card.appendChild(renderCodeSpanChips(step, sourceFiles));

      stepsListEl.appendChild(card);
      wireStepHover(card, step, sourceFiles);
    });
  }

  // ---------------------------------------------------------------------
  // Verdict row: compare all 7 designs' verdict for the current scenario.
  // ---------------------------------------------------------------------
  function renderVerdictRow(scenarioId) {
    verdictRowEl.innerHTML = "";
    var table = document.createElement("table");
    table.className = "verdict-table";
    var thead = document.createElement("tr");
    thead.innerHTML = "<th>Design</th><th>Verdict</th><th>Verdict note</th>";
    table.appendChild(thead);
    DESIGNS.forEach(function (d) {
      var t = traceFor(d.id, scenarioId);
      var tr = document.createElement("tr");
      var td1 = document.createElement("td");
      td1.textContent = d.label;
      var td2 = document.createElement("td");
      if (t) {
        var b = document.createElement("span");
        b.className = "badge " + verdictClass(t.verdict);
        b.textContent = t.verdict || "(none)";
        td2.appendChild(b);
      } else {
        td2.textContent = "(no trace)";
      }
      var td3 = document.createElement("td");
      td3.className = "verdict-note";
      td3.textContent = t ? t.verdictNote || "" : "";
      tr.appendChild(td1);
      tr.appendChild(td2);
      tr.appendChild(td3);
      table.appendChild(tr);
    });
    verdictRowEl.appendChild(table);
  }

  // ---------------------------------------------------------------------
  // Determinacy summary: per-design totals of determined/underdetermined/
  // unsure steps across all scenarios, plus halt counts (verdict === "halt",
  // case-sensitive per the data -- every occurrence observed in
  // traces/*.json is lowercase "halt").
  // ---------------------------------------------------------------------
  function renderSummaryTable() {
    summaryTableEl.innerHTML = "";
    var table = document.createElement("table");
    table.className = "summary-table";
    var thead = document.createElement("tr");
    thead.innerHTML = "<th>Design</th><th>Determined</th><th>Underdetermined</th><th>Unsure</th><th>Halts</th><th>Scenarios</th>";
    table.appendChild(thead);
    DESIGNS.forEach(function (d) {
      var counts = { determined: 0, underdetermined: 0, unsure: 0, other: 0 };
      var halts = 0;
      var scenarioCount = 0;
      var t = window.TRACES && window.TRACES[d.id];
      if (t && t.scenarios) {
        for (var sid in t.scenarios) {
          scenarioCount++;
          var sc = t.scenarios[sid];
          if (sc.verdict === "halt") halts++;
          (sc.steps || []).forEach(function (step) {
            if (CONFIDENCE_ORDER.indexOf(step.confidence) !== -1) counts[step.confidence]++;
            else counts.other++;
          });
        }
      }
      var tr = document.createElement("tr");
      tr.innerHTML =
        "<td>" + escapeHtml(d.label) + "</td>" +
        "<td>" + counts.determined + "</td>" +
        "<td>" + counts.underdetermined + "</td>" +
        "<td>" + counts.unsure + "</td>" +
        "<td>" + halts + "</td>" +
        "<td>" + scenarioCount + "</td>";
      table.appendChild(tr);
    });
    summaryTableEl.appendChild(table);
  }

  function shortScenarioCitation(cite) {
    var idx = cite.indexOf(",");
    return idx === -1 ? cite : cite.slice(0, idx);
  }

  function loadCurrent() {
    var design = findDesign(designSelect.value);
    var scenario = findScenario(scenarioSelect.value);
    var trace = traceFor(design.id, scenario.id);

    scenarioCitationEl.textContent = shortScenarioCitation(scenario.citation);
    scenarioCitationEl.title = scenario.citation;

    scenarioProvenanceEl.innerHTML = "";
    if (scenario.provenance) {
      var pb = document.createElement("span");
      pb.className = "prov-badge";
      pb.textContent = scenario.provenance;
      scenarioProvenanceEl.appendChild(pb);
    }

    traceProvenanceEl.innerHTML = "";
    if (trace && trace.provenance) {
      var tb = document.createElement("span");
      tb.className = "prov-badge prov-llm";
      tb.textContent = trace.provenance;
      tb.title = "trace provenance: " + trace.provenance;
      traceProvenanceEl.appendChild(tb);
    }

    var sourceFiles = renderSourcePane(scenario);
    renderSteps(trace, sourceFiles);
    buildStepRefIndex(sourceFiles);
    renderVerdictRow(scenario.id);
  }

  designSelect.addEventListener("change", loadCurrent);
  scenarioSelect.addEventListener("change", loadCurrent);

  loadCurrent();
  renderSummaryTable();
})();
