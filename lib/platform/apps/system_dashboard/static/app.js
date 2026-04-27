(function () {
  "use strict";

  var searchEl = document.getElementById("search");
  var resultsEl = document.getElementById("results");
  var packInfoEl = document.getElementById("pack-info");
  var outputPanelEl = document.getElementById("output-panel");
  var outputLabelEl = document.getElementById("output-label");
  var outputBodyEl = document.getElementById("output-body");
  var outputCiteEl = document.getElementById("output-cite");
  var modalEl = document.getElementById("confirm-modal");
  var modalTitleEl = document.getElementById("modal-title");
  var modalCommandEl = document.getElementById("modal-command");
  var modalCapsEl = document.getElementById("modal-caps");
  var modalCapsListEl = document.getElementById("modal-caps-list");
  var modalCancelEl = document.getElementById("modal-cancel");
  var modalExecuteEl = document.getElementById("modal-execute");

  var debounceTimer = null;
  var selectedIndex = -1;
  var currentResults = [];

  // --- Fetch helpers ---

  async function fetchCapInfo(aliasId, actionIndex) {
    var url = "/api/cap_info?alias=" + encodeURIComponent(aliasId) + "&action=" + actionIndex;
    var res = await fetch(url);
    if (!res.ok) throw new Error("HTTP " + res.status);
    return res.json();
  }

  async function fetchResults(query) {
    var url = "/api/search?q=" + encodeURIComponent(query);
    var res = await fetch(url);
    if (!res.ok) throw new Error("HTTP " + res.status);
    return res.json();
  }

  async function fetchPacks() {
    var res = await fetch("/api/packs");
    if (!res.ok) throw new Error("HTTP " + res.status);
    return res.json();
  }

  async function postExecute(aliasId, actionIndex) {
    var res = await fetch("/api/execute", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ alias_id: aliasId, action_index: actionIndex }),
    });
    return res.json();
  }

  // --- Output panel ---

  // Render a primitive table to an HTMLElement. Pack-supplied strings are set
  // via textContent / element children — never innerHTML — to avoid XSS.
  function renderPrimitive(p) {
    if (!p || typeof p !== "object") {
      var fallback = document.createElement("pre");
      fallback.className = "prim-text";
      fallback.textContent = JSON.stringify(p);
      return fallback;
    }
    switch (p.type) {
      case "text": {
        var wrap = document.createElement("div");
        wrap.className = "prim-text";
        var pre = document.createElement("pre");
        pre.textContent = p.text == null ? "" : String(p.text);
        if (p.style) pre.classList.add("style-" + p.style);
        wrap.appendChild(pre);
        return wrap;
      }
      case "code": {
        var c = document.createElement("pre");
        c.className = "prim-code";
        if (p.lang) c.setAttribute("data-lang", String(p.lang));
        c.textContent = p.text == null ? "" : String(p.text);
        return c;
      }
      case "key_value": {
        var dl = document.createElement("dl");
        dl.className = "prim-kv";
        var pairs = p.pairs || [];
        for (var i = 0; i < pairs.length; i++) {
          var dt = document.createElement("dt");
          dt.textContent = pairs[i].key == null ? "" : String(pairs[i].key);
          var dd = document.createElement("dd");
          dd.appendChild(renderPrimitive(pairs[i].value));
          dl.appendChild(dt);
          dl.appendChild(dd);
        }
        return dl;
      }
      case "table": {
        var t = document.createElement("table");
        t.className = "prim-table";
        var thead = document.createElement("thead");
        var thr = document.createElement("tr");
        var cols = p.columns || [];
        for (var ci = 0; ci < cols.length; ci++) {
          var th = document.createElement("th");
          th.textContent = cols[ci].label == null ? "" : String(cols[ci].label);
          thr.appendChild(th);
        }
        thead.appendChild(thr);
        t.appendChild(thead);
        var tbody = document.createElement("tbody");
        var rows = p.rows || [];
        for (var ri = 0; ri < rows.length; ri++) {
          var tr = document.createElement("tr");
          for (var ck = 0; ck < cols.length; ck++) {
            var td = document.createElement("td");
            var cell = rows[ri][cols[ck].key];
            td.textContent = cell == null ? "" : String(cell);
            tr.appendChild(td);
          }
          tbody.appendChild(tr);
        }
        t.appendChild(tbody);
        return t;
      }
      case "status_badge": {
        var s = document.createElement("span");
        s.className = "prim-badge state-" + (p.state || "unknown");
        s.textContent = p.label == null ? "" : String(p.label);
        return s;
      }
      default: {
        var raw = document.createElement("pre");
        raw.className = "prim-unknown";
        raw.textContent = JSON.stringify(p, null, 2);
        return raw;
      }
    }
  }

  function renderCite(citeArr) {
    outputCiteEl.textContent = "";
    if (!citeArr || !citeArr.length) return;
    var ul = document.createElement("ul");
    ul.className = "cite-list";
    for (var i = 0; i < citeArr.length; i++) {
      var entry = citeArr[i];
      var li = document.createElement("li");
      var kindSpan = document.createElement("span");
      kindSpan.className = "cite-kind";
      kindSpan.textContent = entry.kind || "?";
      li.appendChild(kindSpan);
      var detail = "";
      if (entry.path) detail = entry.path;
      else if (entry.url) detail = (entry.method ? entry.method + " " : "") + entry.url;
      else if (entry.href) detail = entry.href;
      else if (entry.argv) detail = (entry.argv || []).join(" ");
      else if (entry.query) detail = entry.query;
      else if (entry.name) detail = entry.name;
      else if (entry.text) detail = entry.text;
      if (detail) {
        var detailSpan = document.createElement("span");
        detailSpan.className = "cite-detail";
        detailSpan.textContent = " " + detail;
        li.appendChild(detailSpan);
      }
      ul.appendChild(li);
    }
    outputCiteEl.appendChild(ul);
  }

  function renderEnvelope(label, env) {
    outputLabelEl.textContent = label;
    var isError = !env || env.ok === false;
    outputLabelEl.className = "output-label" + (isError ? " output-error" : "");
    // Clear previous body content
    outputBodyEl.textContent = "";
    if (env && env.body) {
      outputBodyEl.appendChild(renderPrimitive(env.body));
    } else if (env && env.error) {
      var errEl = document.createElement("div");
      errEl.className = "prim-text style-error";
      var errPre = document.createElement("pre");
      errPre.textContent = String(env.error);
      errEl.appendChild(errPre);
      outputBodyEl.appendChild(errEl);
    } else {
      var emptyEl = document.createElement("div");
      emptyEl.className = "prim-text style-muted";
      emptyEl.textContent = "(no output)";
      outputBodyEl.appendChild(emptyEl);
    }
    renderCite(env && env.cite);
    outputPanelEl.style.display = "block";
    outputPanelEl.scrollIntoView({ block: "nearest" });
  }

  function hideOutput() {
    outputPanelEl.style.display = "none";
    outputBodyEl.textContent = "";
    outputCiteEl.textContent = "";
  }

  // --- Rendering ---

  function renderResults(results) {
    currentResults = results;
    selectedIndex = -1;
    hideOutput();

    if (results.length === 0) {
      resultsEl.innerHTML = '<div class="result-error">No results found.</div>';
      return;
    }

    var html = "";
    for (var i = 0; i < results.length; i++) {
      var r = results[i];
      html += '<div class="result" data-index="' + i + '" data-id="' + escapeAttr(r.id) + '">';
      html += '<div class="result-title">' + escapeHtml(r.title) + "</div>";
      if (r.description) {
        html += '<div class="result-desc">' + escapeHtml(r.description) + "</div>";
      }
      if (r.actions && r.actions.length > 0) {
        html += '<div class="result-actions">';
        for (var j = 0; j < r.actions.length; j++) {
          var a = r.actions[j];
          html +=
            '<button class="action-btn"' +
            ' data-alias-id="' + escapeAttr(r.id) + '"' +
            ' data-action-index="' + j + '"' +
            ' data-command="' + escapeAttr(a.command) + '"' +
            ' data-label="' + escapeAttr(a.label) + '"' +
            (a.cap ? ' data-cap="' + escapeAttr(a.cap) + '"' : '') +
            ">" +
            escapeHtml(a.label) +
            "</button>";
        }
        html += "</div>";
      }
      if (r.tags && r.tags.length > 0) {
        html += '<div class="result-tags">';
        for (var k = 0; k < r.tags.length; k++) {
          html += '<span class="tag">' + escapeHtml(r.tags[k]) + "</span>";
        }
        html += "</div>";
      }
      html += "</div>";
    }

    resultsEl.innerHTML = html;

    // Attach action button listeners
    var btns = resultsEl.querySelectorAll(".action-btn");
    for (var b = 0; b < btns.length; b++) {
      btns[b].addEventListener("click", onActionClick);
    }
  }

  function showError(msg) {
    currentResults = [];
    selectedIndex = -1;
    resultsEl.innerHTML = '<div class="result-error">' + escapeHtml(msg) + "</div>";
    hideOutput();
  }

  function clearResults() {
    currentResults = [];
    selectedIndex = -1;
    resultsEl.innerHTML = "";
    hideOutput();
  }

  // --- Selection ---

  function setSelected(index) {
    var items = resultsEl.querySelectorAll(".result");
    if (selectedIndex >= 0 && selectedIndex < items.length) {
      items[selectedIndex].classList.remove("selected");
    }
    selectedIndex = index;
    if (selectedIndex >= 0 && selectedIndex < items.length) {
      items[selectedIndex].classList.add("selected");
      items[selectedIndex].scrollIntoView({ block: "nearest" });
    }
  }

  function moveSelection(delta) {
    var items = resultsEl.querySelectorAll(".result");
    if (items.length === 0) return;
    var next = selectedIndex + delta;
    if (next < 0) next = 0;
    if (next >= items.length) next = items.length - 1;
    setSelected(next);
  }

  function activateSelected() {
    if (selectedIndex < 0) return;
    var items = resultsEl.querySelectorAll(".result");
    if (selectedIndex >= items.length) return;
    var firstBtn = items[selectedIndex].querySelector(".action-btn");
    if (firstBtn) firstBtn.click();
  }

  // --- Confirmation modal ---

  var pendingAction = null;

  function renderCapCard(cap) {
    var severity = (cap.risk && cap.risk.severity) || "";
    var cardClass = "cap-card" + (severity ? " severity-" + escapeAttr(severity) : "");
    var html = '<div class="' + cardClass + '">';
    html += '<div class="cap-card-header">' + escapeHtml(cap.name);
    if (cap.type && cap.type !== cap.name) {
      html += '<span class="cap-card-type">' + escapeHtml(cap.type) + '</span>';
    }
    html += '</div>';
    if (cap.reason) {
      html += '<div class="cap-reason">' + escapeHtml(cap.reason) + ' <span style="color:#555;font-style:normal;">(stated by pack)</span></div>';
    }
    if (cap.risk && cap.risk.text) {
      var riskClass = "cap-risk" + (severity ? " severity-" + escapeAttr(severity) : "");
      html += '<div class="' + riskClass + '">' + escapeHtml(cap.risk.text) + '</div>';
    }
    html += '</div>';
    return html;
  }

  function showModal(label, command, capInfo) {
    modalTitleEl.textContent = label;
    modalCommandEl.textContent = command;
    if (capInfo && capInfo.caps && capInfo.caps.length > 0) {
      var html = "";
      for (var i = 0; i < capInfo.caps.length; i++) {
        html += renderCapCard(capInfo.caps[i]);
      }
      modalCapsListEl.innerHTML = html;
      modalCapsEl.style.display = "";
    } else {
      modalCapsEl.style.display = "none";
      modalCapsListEl.innerHTML = "";
    }
    modalEl.style.display = "flex";
    modalCancelEl.focus();
  }

  function hideModal() {
    modalEl.style.display = "none";
    pendingAction = null;
  }

  modalCancelEl.addEventListener("click", hideModal);
  modalEl.addEventListener("click", function (e) {
    if (e.target === modalEl) hideModal();
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && modalEl.style.display !== "none") {
      e.stopPropagation();
      hideModal();
    }
  }, true);

  modalExecuteEl.addEventListener("click", function () {
    if (!pendingAction) return;
    var action = pendingAction;
    hideModal();
    postExecute(action.aliasId, action.actionIndex).then(function (env) {
      var label = action.label + (env && env.ok === false ? " — error" : " — output");
      renderEnvelope(label, env);
    }).catch(function (err) {
      renderEnvelope(action.label + " — error",
        { ok: false, error: "request failed: " + (err && err.message ? err.message : "network error") });
    });
  });

  // --- Action: show confirmation modal for shell commands ---

  function onActionClick(e) {
    var btn = e.currentTarget;
    var aliasId = btn.getAttribute("data-alias-id");
    var actionIndex = parseInt(btn.getAttribute("data-action-index"), 10);
    var command = btn.getAttribute("data-command") || "";
    var label = btn.getAttribute("data-label") || "";
    if (!aliasId) return;

    pendingAction = { aliasId: aliasId, actionIndex: actionIndex, command: command, label: label, btn: btn };

    // Fetch cap details, then show modal (degrade gracefully on failure)
    fetchCapInfo(aliasId, actionIndex).then(function (capInfo) {
      // Use exec_args from capInfo as the canonical command if present
      var displayCommand = (capInfo && capInfo.exec_args) ? capInfo.exec_args : command;
      showModal(label, displayCommand, capInfo);
    }).catch(function () {
      showModal(label, command, null);
    });
  }

  // --- Search ---

  async function doSearch(query) {
    try {
      var results = await fetchResults(query);
      renderResults(results);
    } catch (err) {
      showError("Search unavailable");
    }
  }

  function onSearchInput() {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(function () {
      doSearch(searchEl.value);
    }, 150);
  }

  // --- Keyboard navigation ---

  function onKeyDown(e) {
    switch (e.key) {
      case "ArrowDown":
        e.preventDefault();
        moveSelection(1);
        break;
      case "ArrowUp":
        e.preventDefault();
        moveSelection(-1);
        break;
      case "Enter":
        e.preventDefault();
        activateSelected();
        break;
      case "Escape":
        e.preventDefault();
        if (outputPanelEl.style.display !== "none") {
          hideOutput();
        } else {
          searchEl.value = "";
          clearResults();
        }
        break;
    }
  }

  // --- Pack info ---

  async function loadPackInfo() {
    try {
      var packs = await fetchPacks();
      if (!packs || packs.length === 0) return;
      var total = 0;
      for (var i = 0; i < packs.length; i++) {
        total += packs[i].alias_count || 0;
      }
      packInfoEl.textContent =
        total + " aliases from " + packs.length + " pack" + (packs.length === 1 ? "" : "s");
    } catch (err) {
      // Footer is non-critical; silently ignore
    }
  }

  // --- Escape helpers ---

  function escapeHtml(str) {
    if (str == null) return "";
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function escapeAttr(str) {
    if (str == null) return "";
    return String(str).replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  // --- Init ---

  searchEl.addEventListener("input", onSearchInput);
  searchEl.addEventListener("keydown", onKeyDown);
  searchEl.focus();

  // Browse mode: load first batch immediately
  doSearch("");
  loadPackInfo();
})();
