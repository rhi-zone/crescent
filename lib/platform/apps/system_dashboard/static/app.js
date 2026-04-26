(function () {
  "use strict";

  var searchEl = document.getElementById("search");
  var resultsEl = document.getElementById("results");
  var packInfoEl = document.getElementById("pack-info");
  var execPanelEl = document.getElementById("exec-panel");
  var execCommandEl = document.getElementById("exec-command");
  var execLabelEl = document.getElementById("exec-label");
  var execCopyEl = document.getElementById("exec-copy");

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

  // --- Exec panel ---

  function showExecPanel(command, label) {
    execCommandEl.textContent = command;
    execLabelEl.textContent = label + " — run this in your terminal";
    execCopyEl.textContent = "Copy";
    execCopyEl.classList.remove("copied");
    execPanelEl.style.display = "block";
    execPanelEl.scrollIntoView({ block: "nearest" });
  }

  function hideExecPanel() {
    execPanelEl.style.display = "none";
  }

  function onExecCopy() {
    var command = execCommandEl.textContent;
    if (!command) return;
    navigator.clipboard.writeText(command).then(function () {
      execCopyEl.textContent = "Copied";
      execCopyEl.classList.add("copied");
      setTimeout(function () {
        execCopyEl.textContent = "Copy";
        execCopyEl.classList.remove("copied");
      }, 1500);
    }).catch(function () {
      var ta = document.createElement("textarea");
      ta.value = command;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      document.body.removeChild(ta);
      execCopyEl.textContent = "Copied";
      execCopyEl.classList.add("copied");
      setTimeout(function () {
        execCopyEl.textContent = "Copy";
        execCopyEl.classList.remove("copied");
      }, 1500);
    });
  }

  // --- Rendering ---

  function renderResults(results) {
    currentResults = results;
    selectedIndex = -1;
    hideExecPanel();

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
            ' data-label="' + escapeAttr(a.label) + '"' +
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
    hideExecPanel();
  }

  function clearResults() {
    currentResults = [];
    selectedIndex = -1;
    resultsEl.innerHTML = "";
    hideExecPanel();
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

  // --- Action: two-step execute ---

  function onActionClick(e) {
    var btn = e.currentTarget;
    var aliasId = btn.getAttribute("data-alias-id");
    var actionIndex = parseInt(btn.getAttribute("data-action-index"), 10);
    var label = btn.getAttribute("data-label") || "";
    if (!aliasId) return;

    postExecute(aliasId, actionIndex).then(function (data) {
      if (data && data.ok) {
        showExecPanel(data.command, label);
      } else {
        showExecPanel("(error: " + (data && data.error || "unknown") + ")", label);
      }
    }).catch(function () {
      showExecPanel("(network error)", label);
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
        if (execPanelEl.style.display !== "none") {
          hideExecPanel();
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

  execCopyEl.addEventListener("click", onExecCopy);
  searchEl.addEventListener("input", onSearchInput);
  searchEl.addEventListener("keydown", onKeyDown);
  searchEl.focus();

  // Browse mode: load first batch immediately
  doSearch("");
  loadPackInfo();
})();
