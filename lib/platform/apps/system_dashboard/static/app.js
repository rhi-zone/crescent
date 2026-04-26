(function () {
  "use strict";

  var searchEl = document.getElementById("search");
  var resultsEl = document.getElementById("results");
  var packInfoEl = document.getElementById("pack-info");
  var outputPanelEl = document.getElementById("output-panel");
  var outputLabelEl = document.getElementById("output-label");
  var outputBodyEl = document.getElementById("output-body");
  var modalEl = document.getElementById("confirm-modal");
  var modalTitleEl = document.getElementById("modal-title");
  var modalCommandEl = document.getElementById("modal-command");
  var modalCapsEl = document.getElementById("modal-caps");
  var modalCancelEl = document.getElementById("modal-cancel");
  var modalExecuteEl = document.getElementById("modal-execute");

  var debounceTimer = null;
  var selectedIndex = -1;
  var currentResults = [];

  // --- Fetch helpers ---

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

  function showOutput(label, text, isError) {
    outputLabelEl.textContent = label;
    outputLabelEl.className = "output-label" + (isError ? " output-error" : "");
    outputBodyEl.textContent = text;
    outputPanelEl.style.display = "block";
    outputPanelEl.scrollIntoView({ block: "nearest" });
  }

  function hideOutput() {
    outputPanelEl.style.display = "none";
  }

  // --- Clipboard copy ---

  function copyToClipboard(text, btn) {
    var original = btn.textContent;
    var done = function () {
      btn.textContent = "✓ Copied";
      btn.classList.add("copied");
      setTimeout(function () {
        btn.textContent = original;
        btn.classList.remove("copied");
      }, 1500);
    };
    navigator.clipboard.writeText(text).then(done).catch(function () {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      document.body.removeChild(ta);
      done();
    });
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
            (a.caps && a.caps.length > 0 ? ' data-caps="' + escapeAttr(a.caps.join(",")) + '"' : '') +
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

  function showModal(label, command, caps) {
    modalTitleEl.textContent = label;
    modalCommandEl.textContent = command;
    if (caps) {
      modalCapsEl.textContent = "Requires caps: " + caps;
      modalCapsEl.style.display = "";
    } else {
      modalCapsEl.style.display = "none";
    }
    modalEl.style.display = "flex";
    modalExecuteEl.focus();
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
    postExecute(action.aliasId, action.actionIndex).then(function (data) {
      if (data && data.ok) {
        var output = data.output || "";
        showOutput(action.label + " — output", output || "(no output)", false);
      } else if (data && data.error === "exec cap not available") {
        copyToClipboard(action.command, action.btn);
      } else {
        var msg = (data && data.error) || "unknown error";
        showOutput(action.label + " — error", msg, true);
      }
    }).catch(function () {
      copyToClipboard(action.command, action.btn);
    });
  });

  // --- Action: show confirmation modal for shell commands ---

  function onActionClick(e) {
    var btn = e.currentTarget;
    var aliasId = btn.getAttribute("data-alias-id");
    var actionIndex = parseInt(btn.getAttribute("data-action-index"), 10);
    var command = btn.getAttribute("data-command") || "";
    var label = btn.getAttribute("data-label") || "";
    var caps = btn.getAttribute("data-caps") || null;
    if (!aliasId) return;

    pendingAction = { aliasId: aliasId, actionIndex: actionIndex, command: command, label: label, btn: btn };
    showModal(label, command, caps);
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
