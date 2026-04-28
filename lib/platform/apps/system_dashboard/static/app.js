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

  // --- SSE streaming consumer ---
  //
  // postExecuteWithStream(aliasId, actionIndex, lastEventId?) -> Promise that
  // resolves with one of:
  //   { kind: "json",   env: <envelope> }       — server returned JSON envelope
  //   { kind: "stream", reader, abort }        — text/event-stream; caller
  //     pumps frames via consumeStream(reader, handlers).
  //
  // The Last-Event-ID header is plumbed through for resume-on-reconnect.
  async function postExecuteWithStream(aliasId, actionIndex, lastEventId) {
    var ac = new AbortController();
    var headers = { "Content-Type": "application/json" };
    if (lastEventId != null) headers["Last-Event-ID"] = String(lastEventId);
    var res = await fetch("/api/execute", {
      method: "POST",
      headers: headers,
      body: JSON.stringify({ alias_id: aliasId, action_index: actionIndex }),
      signal: ac.signal,
    });
    var ct = (res.headers.get("Content-Type") || "").toLowerCase();
    if (ct.indexOf("text/event-stream") === 0) {
      return { kind: "stream", reader: res.body.getReader(), abort: function () { ac.abort(); } };
    }
    var env = await res.json();
    return { kind: "json", env: env };
  }

  // Parse a buffer of SSE frames, calling handlers per event. Returns the
  // remainder buffer that did not yet form a complete frame.
  function parseSseFrames(buf, handlers) {
    var idx;
    while ((idx = buf.indexOf("\n\n")) >= 0) {
      var raw = buf.slice(0, idx);
      buf = buf.slice(idx + 2);
      var ev = "message", id = null, data = "";
      var lines = raw.split("\n");
      for (var li = 0; li < lines.length; li++) {
        var line = lines[li];
        if (line.indexOf("event:") === 0)      ev   = line.slice(6).trim();
        else if (line.indexOf("id:") === 0)    id   = line.slice(3).trim();
        else if (line.indexOf("data:") === 0)  data = line.slice(5).trim();
      }
      handlers.onFrame(ev, id, data);
    }
    return buf;
  }

  // Consume a ReadableStream of SSE bytes. handlers = { onFrame(ev,id,data),
  // onDone(), onError(err) }. Resolves when the stream ends; rejects only on
  // unrecoverable read errors.
  async function consumeStream(reader, handlers) {
    var dec = new TextDecoder("utf-8");
    var buf = "";
    while (true) {
      var step = await reader.read();
      if (step.done) {
        if (buf.length > 0) buf = parseSseFrames(buf + "\n\n", handlers);
        handlers.onDone();
        return;
      }
      buf += dec.decode(step.value, { stream: true });
      buf = parseSseFrames(buf, handlers);
    }
  }

  // --- Output panel ---

  // Series color palette used by line/bar/area/heatmap charts. 6 entries.
  var SERIES_COLORS = ["#80a8d0", "#80d080", "#ffd070", "#ff8080", "#c080d0", "#80d0c0"];

  // Execute an alias by id. Reused by `button`, `confirm`, `action_menu`,
  // and `panel.actions`. The current /api/execute endpoint ignores `args`
  // (TODO: thread through once backend accepts them). On any failure, an
  // err envelope is synthesized so the caller can render uniformly.
  function executeAlias(aliasId, args, onEnvelope) {
    fetch("/api/execute", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ alias_id: aliasId, action_index: 0, args: args || null }),
    }).then(function (res) { return res.json(); })
      .then(function (env) { onEnvelope(env); })
      .catch(function (err) {
        onEnvelope({ ok: false,
          error: "request failed: " + (err && err.message ? err.message : "network error") });
      });
  }

  // Render an action button referenced from `panel.actions` (an alias id only).
  // The label is the alias id (no title/cap-detail fetch); clicking executes.
  function renderActionButton(aliasId) {
    var btn = document.createElement("button");
    btn.className = "prim-btn style-default";
    btn.textContent = String(aliasId);
    var resultSlot = null;
    btn.addEventListener("click", function () {
      if (!resultSlot) {
        resultSlot = document.createElement("div");
        resultSlot.className = "btn-result";
        btn.parentNode.insertBefore(resultSlot, btn.nextSibling);
      }
      resultSlot.textContent = "";
      executeAlias(aliasId, null, function (env) {
        resultSlot.textContent = "";
        if (env && env.body) {
          resultSlot.appendChild(renderPrimitive(env.body));
        } else if (env && env.error) {
          var e = document.createElement("div");
          e.className = "prim-text style-error";
          var pre = document.createElement("pre");
          pre.textContent = String(env.error);
          e.appendChild(pre);
          resultSlot.appendChild(e);
        }
      });
    });
    return btn;
  }

  // --- Chart helpers (inline SVG, no library) ---

  var SVG_NS = "http://www.w3.org/2000/svg";
  var CHART_W = 240, CHART_H = 80, CHART_PAD = 4;

  function svgEl(name, attrs) {
    var el = document.createElementNS(SVG_NS, name);
    if (attrs) {
      for (var k in attrs) {
        if (Object.prototype.hasOwnProperty.call(attrs, k)) {
          el.setAttribute(k, String(attrs[k]));
        }
      }
    }
    return el;
  }

  // Compute the y-extent over a list of series, stacking optional.
  function seriesYExtent(series, stacked) {
    var min = Infinity, max = -Infinity;
    if (stacked) {
      // Sum per-x across series. Build map t -> sum.
      var sums = {};
      for (var s = 0; s < series.length; s++) {
        var pts = series[s].points || [];
        for (var i = 0; i < pts.length; i++) {
          var key = String(pts[i].t);
          sums[key] = (sums[key] || 0) + (pts[i].v || 0);
        }
      }
      for (var k in sums) {
        if (Object.prototype.hasOwnProperty.call(sums, k)) {
          if (sums[k] < min) min = sums[k];
          if (sums[k] > max) max = sums[k];
        }
      }
    } else {
      for (var s2 = 0; s2 < series.length; s2++) {
        var pts2 = series[s2].points || [];
        for (var i2 = 0; i2 < pts2.length; i2++) {
          var v = pts2[i2].v;
          if (typeof v !== "number") continue;
          if (v < min) min = v;
          if (v > max) max = v;
        }
      }
    }
    if (!isFinite(min) || !isFinite(max)) { min = 0; max = 1; }
    if (min === max) { max = min + 1; }
    return { min: min, max: max };
  }

  function seriesTExtent(series) {
    var min = Infinity, max = -Infinity;
    for (var s = 0; s < series.length; s++) {
      var pts = series[s].points || [];
      for (var i = 0; i < pts.length; i++) {
        var t = pts[i].t;
        if (typeof t !== "number") continue;
        if (t < min) min = t;
        if (t > max) max = t;
      }
    }
    if (!isFinite(min) || !isFinite(max)) { min = 0; max = 1; }
    if (min === max) { max = min + 1; }
    return { min: min, max: max };
  }

  function renderXYChart(p, filled) {
    var svg = svgEl("svg", {
      "class": "prim-chart",
      width: CHART_W, height: CHART_H,
      viewBox: "0 0 " + CHART_W + " " + CHART_H,
    });
    var series = p.series || [];
    var tExt = seriesTExtent(series);
    var stacked = !!p.stacked;
    var yExt = seriesYExtent(series, filled && stacked);
    if (typeof p.y_min === "number") yExt.min = p.y_min;
    if (typeof p.y_max === "number") yExt.max = p.y_max;
    if (yExt.min === yExt.max) yExt.max = yExt.min + 1;
    var w = CHART_W - CHART_PAD * 2;
    var h = CHART_H - CHART_PAD * 2;
    function xOf(t) {
      return CHART_PAD + ((t - tExt.min) / (tExt.max - tExt.min)) * w;
    }
    function yOf(v) {
      return CHART_PAD + h - ((v - yExt.min) / (yExt.max - yExt.min)) * h;
    }

    if (filled && stacked) {
      // Build a stack: walk x values in sorted order across the union of
      // each series' point t values; emit polygons per series.
      var xKeys = {};
      for (var sx = 0; sx < series.length; sx++) {
        var sp = series[sx].points || [];
        for (var spi = 0; spi < sp.length; spi++) xKeys[sp[spi].t] = true;
      }
      var xs = [];
      for (var xk in xKeys) {
        if (Object.prototype.hasOwnProperty.call(xKeys, xk)) xs.push(parseFloat(xk));
      }
      xs.sort(function (a, b) { return a - b; });
      var bottom = new Array(xs.length);
      for (var bi = 0; bi < xs.length; bi++) bottom[bi] = 0;
      for (var si = 0; si < series.length; si++) {
        var ptsBy = {};
        var spi2 = series[si].points || [];
        for (var spk = 0; spk < spi2.length; spk++) ptsBy[spi2[spk].t] = spi2[spk].v;
        var top = new Array(xs.length);
        for (var ti2 = 0; ti2 < xs.length; ti2++) {
          var vv = ptsBy[xs[ti2]];
          top[ti2] = bottom[ti2] + (typeof vv === "number" ? vv : 0);
        }
        var pts = [];
        for (var fi = 0; fi < xs.length; fi++) {
          pts.push(xOf(xs[fi]) + "," + yOf(top[fi]));
        }
        for (var ri = xs.length - 1; ri >= 0; ri--) {
          pts.push(xOf(xs[ri]) + "," + yOf(bottom[ri]));
        }
        var poly = svgEl("polygon", {
          points: pts.join(" "),
          fill: SERIES_COLORS[si % SERIES_COLORS.length],
          "fill-opacity": "0.5",
          stroke: SERIES_COLORS[si % SERIES_COLORS.length],
          "stroke-width": "1",
        });
        svg.appendChild(poly);
        bottom = top;
      }
    } else {
      for (var snn = 0; snn < series.length; snn++) {
        var ptsn = series[snn].points || [];
        if (!ptsn.length) continue;
        var coordsArr = [];
        for (var ci2 = 0; ci2 < ptsn.length; ci2++) {
          coordsArr.push(xOf(ptsn[ci2].t) + "," + yOf(ptsn[ci2].v));
        }
        var color = SERIES_COLORS[snn % SERIES_COLORS.length];
        if (filled) {
          var areaPts = coordsArr.slice();
          areaPts.push(xOf(ptsn[ptsn.length - 1].t) + "," + (CHART_PAD + h));
          areaPts.push(xOf(ptsn[0].t) + "," + (CHART_PAD + h));
          svg.appendChild(svgEl("polygon", {
            points: areaPts.join(" "),
            fill: color, "fill-opacity": "0.3",
            stroke: "none",
          }));
        }
        svg.appendChild(svgEl("polyline", {
          points: coordsArr.join(" "),
          fill: "none", stroke: color, "stroke-width": "1.2",
        }));
      }
    }

    if (p.unit != null) {
      var lbl = svgEl("text", {
        x: CHART_W - CHART_PAD, y: CHART_PAD + 9,
        "text-anchor": "end", "class": "chart-unit",
      });
      lbl.textContent = String(p.unit);
      svg.appendChild(lbl);
    }
    return svg;
  }

  function renderBarChart(p) {
    var svg = svgEl("svg", {
      "class": "prim-chart",
      width: CHART_W, height: CHART_H,
      viewBox: "0 0 " + CHART_W + " " + CHART_H,
    });
    var series = p.series || [];
    var stacked = !!p.stacked;
    // Categorical t axis: union of all distinct t values from all series.
    var tSet = {};
    for (var s = 0; s < series.length; s++) {
      var pts = series[s].points || [];
      for (var i = 0; i < pts.length; i++) tSet[pts[i].t] = true;
    }
    var tKeys = [];
    for (var k in tSet) {
      if (Object.prototype.hasOwnProperty.call(tSet, k)) tKeys.push(k);
    }
    tKeys.sort(function (a, b) {
      var na = parseFloat(a), nb = parseFloat(b);
      if (!isNaN(na) && !isNaN(nb)) return na - nb;
      return a < b ? -1 : a > b ? 1 : 0;
    });

    var yExt = seriesYExtent(series, stacked);
    if (yExt.min > 0) yExt.min = 0;
    var w = CHART_W - CHART_PAD * 2;
    var h = CHART_H - CHART_PAD * 2;
    var nCats = tKeys.length || 1;
    var slot = w / nCats;
    function yOf(v) {
      return CHART_PAD + h - ((v - yExt.min) / (yExt.max - yExt.min)) * h;
    }

    if (stacked) {
      for (var ci = 0; ci < tKeys.length; ci++) {
        var x0 = CHART_PAD + slot * ci + slot * 0.1;
        var bw = slot * 0.8;
        var stack = 0;
        for (var sj = 0; sj < series.length; sj++) {
          var ptsj = series[sj].points || [];
          var v = 0;
          for (var pi = 0; pi < ptsj.length; pi++) {
            if (String(ptsj[pi].t) === tKeys[ci]) { v = ptsj[pi].v || 0; break; }
          }
          var yTop = yOf(stack + v);
          var yBot = yOf(stack);
          svg.appendChild(svgEl("rect", {
            x: x0.toFixed(2), y: yTop.toFixed(2),
            width: bw.toFixed(2), height: Math.max(0, yBot - yTop).toFixed(2),
            fill: SERIES_COLORS[sj % SERIES_COLORS.length],
          }));
          stack += v;
        }
      }
    } else {
      var nSer = series.length || 1;
      for (var ci2 = 0; ci2 < tKeys.length; ci2++) {
        var groupX = CHART_PAD + slot * ci2 + slot * 0.1;
        var groupW = slot * 0.8;
        var bw2 = groupW / nSer;
        for (var sk = 0; sk < series.length; sk++) {
          var ptsk = series[sk].points || [];
          var v2 = 0;
          for (var pi2 = 0; pi2 < ptsk.length; pi2++) {
            if (String(ptsk[pi2].t) === tKeys[ci2]) { v2 = ptsk[pi2].v || 0; break; }
          }
          var yT = yOf(v2);
          var yB = yOf(0);
          svg.appendChild(svgEl("rect", {
            x: (groupX + bw2 * sk).toFixed(2),
            y: Math.min(yT, yB).toFixed(2),
            width: bw2.toFixed(2),
            height: Math.abs(yB - yT).toFixed(2),
            fill: SERIES_COLORS[sk % SERIES_COLORS.length],
          }));
        }
      }
    }

    if (p.unit != null) {
      var lbl2 = svgEl("text", {
        x: CHART_W - CHART_PAD, y: CHART_PAD + 9,
        "text-anchor": "end", "class": "chart-unit",
      });
      lbl2.textContent = String(p.unit);
      svg.appendChild(lbl2);
    }
    return svg;
  }

  function renderHeatmap(p) {
    var xb = typeof p.x_bins === "number" && p.x_bins > 0 ? p.x_bins : 1;
    var yb = typeof p.y_bins === "number" && p.y_bins > 0 ? p.y_bins : 1;
    var cell = 12;
    var W = xb * cell, H = yb * cell;
    var svg = svgEl("svg", {
      "class": "prim-heatmap",
      width: W, height: H,
      viewBox: "0 0 " + W + " " + H,
    });
    var values = p.values || [];
    // Find max for normalization
    var maxV = 0;
    for (var y = 0; y < yb; y++) {
      var row = values[y] || [];
      for (var x = 0; x < xb; x++) {
        var v = typeof row[x] === "number" ? row[x] : 0;
        if (v > maxV) maxV = v;
      }
    }
    if (maxV <= 0) maxV = 1;
    for (var yy = 0; yy < yb; yy++) {
      var rrow = values[yy] || [];
      for (var xx = 0; xx < xb; xx++) {
        var vv = typeof rrow[xx] === "number" ? rrow[xx] : 0;
        var op = vv / maxV;
        if (op < 0) op = 0; if (op > 1) op = 1;
        svg.appendChild(svgEl("rect", {
          x: xx * cell, y: yy * cell,
          width: cell, height: cell,
          fill: SERIES_COLORS[0],
          "fill-opacity": op.toFixed(3),
        }));
      }
    }
    return svg;
  }

  // --- Tree / JSON helpers ---

  function renderTreeNode(node, isRoot) {
    if (!node || typeof node !== "object") {
      var leaf = document.createElement("div");
      leaf.className = "tree-leaf";
      leaf.textContent = String(node);
      return leaf;
    }
    var label = node.label == null ? "" : String(node.label);
    var children = node.children;
    if (!children || !children.length) {
      var leafEl = document.createElement("div");
      leafEl.className = "tree-leaf";
      var leafText = label;
      if (node.value !== undefined && node.value !== null) {
        leafText += ": " + String(node.value);
      }
      // icon optional, text fallback
      if (node.icon != null) {
        var icSpan = document.createElement("span");
        icSpan.className = "tree-icon";
        icSpan.textContent = String(node.icon) + " ";
        leafEl.appendChild(icSpan);
      }
      leafEl.appendChild(document.createTextNode(leafText));
      return leafEl;
    }
    var det = document.createElement("details");
    if (isRoot) det.open = true;
    var sum = document.createElement("summary");
    if (node.icon != null) {
      var icSp = document.createElement("span");
      icSp.className = "tree-icon";
      icSp.textContent = String(node.icon) + " ";
      sum.appendChild(icSp);
    }
    sum.appendChild(document.createTextNode(label));
    det.appendChild(sum);
    for (var ci = 0; ci < children.length; ci++) {
      det.appendChild(renderTreeNode(children[ci], false));
    }
    return det;
  }

  function renderJsonNode(value, depth, expandDepth) {
    if (value === null) {
      var nu = document.createElement("span");
      nu.className = "json-null";
      nu.textContent = "null";
      return nu;
    }
    var tt = typeof value;
    if (tt === "string") {
      var sp = document.createElement("span");
      sp.className = "json-string";
      sp.textContent = JSON.stringify(value);
      return sp;
    }
    if (tt === "number") {
      var spn = document.createElement("span");
      spn.className = "json-number";
      spn.textContent = String(value);
      return spn;
    }
    if (tt === "boolean") {
      var spb = document.createElement("span");
      spb.className = "json-boolean";
      spb.textContent = value ? "true" : "false";
      return spb;
    }
    if (tt === "object") {
      var isArr = Array.isArray(value);
      var det = document.createElement("details");
      if (depth < expandDepth) det.open = true;
      var sum = document.createElement("summary");
      sum.className = "json-summary";
      var count = isArr ? value.length : Object.keys(value).length;
      sum.textContent = (isArr ? "[" : "{") + " " + count + " " + (isArr ? "items" : "keys") + " " + (isArr ? "]" : "}");
      det.appendChild(sum);
      if (isArr) {
        for (var ai = 0; ai < value.length; ai++) {
          var row = document.createElement("div");
          row.className = "json-row";
          var idx = document.createElement("span");
          idx.className = "json-key";
          idx.textContent = String(ai) + ": ";
          row.appendChild(idx);
          row.appendChild(renderJsonNode(value[ai], depth + 1, expandDepth));
          det.appendChild(row);
        }
      } else {
        var keys = Object.keys(value);
        for (var ki = 0; ki < keys.length; ki++) {
          var rrow = document.createElement("div");
          rrow.className = "json-row";
          var ks = document.createElement("span");
          ks.className = "json-key";
          ks.textContent = keys[ki] + ": ";
          rrow.appendChild(ks);
          rrow.appendChild(renderJsonNode(value[keys[ki]], depth + 1, expandDepth));
          det.appendChild(rrow);
        }
      }
      return det;
    }
    var fb = document.createElement("span");
    fb.className = "json-unknown";
    fb.textContent = String(value);
    return fb;
  }

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
      case "markdown": {
        // TODO render via lib/markdown once it exists
        var md = document.createElement("pre");
        md.className = "prim-markdown";
        md.textContent = p.text == null ? "" : String(p.text);
        return md;
      }
      case "link": {
        var a = document.createElement("a");
        a.className = "prim-link";
        var href = p.href == null ? "" : String(p.href);
        a.href = href;
        a.rel = "noopener noreferrer";
        a.target = "_blank";
        a.textContent = p.label == null ? href : String(p.label);
        return a;
      }
      case "icon": {
        // TODO swap text fallback for a vendored icon set
        var ic = document.createElement("span");
        ic.className = "prim-icon";
        var iname = p.name == null ? "" : String(p.name);
        ic.setAttribute("data-icon", iname);
        if (p.tone != null) ic.setAttribute("data-tone", String(p.tone));
        ic.textContent = iname;
        return ic;
      }
      case "kbd": {
        var kbdWrap = document.createElement("span");
        kbdWrap.className = "prim-kbd";
        var keys = p.keys || [];
        for (var ki = 0; ki < keys.length; ki++) {
          if (ki > 0) kbdWrap.appendChild(document.createTextNode("+"));
          var k = document.createElement("kbd");
          k.textContent = String(keys[ki]);
          kbdWrap.appendChild(k);
        }
        return kbdWrap;
      }
      case "single_stat": {
        var stat = document.createElement("div");
        stat.className = "prim-stat";
        var valDiv = document.createElement("div");
        valDiv.className = "stat-value";
        var valText = p.value == null ? "" : String(p.value);
        if (p.unit != null) valText += String(p.unit);
        valDiv.textContent = valText;
        stat.appendChild(valDiv);
        if (p.label != null) {
          var lblDiv = document.createElement("div");
          lblDiv.className = "stat-label";
          lblDiv.textContent = String(p.label);
          stat.appendChild(lblDiv);
        }
        if (p.delta != null) {
          var deltaDiv = document.createElement("div");
          deltaDiv.className = "stat-delta" + (p.state ? " state-" + String(p.state) : "");
          deltaDiv.textContent = String(p.delta);
          stat.appendChild(deltaDiv);
        }
        return stat;
      }
      case "gauge": {
        var gauge = document.createElement("div");
        gauge.className = "prim-gauge";
        var gMin = typeof p.min === "number" ? p.min : 0;
        var gMax = typeof p.max === "number" ? p.max : 100;
        var gVal = typeof p.value === "number" ? p.value : 0;
        var span = gMax - gMin;
        var pct = span > 0 ? ((gVal - gMin) / span) * 100 : 0;
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        var fill = document.createElement("div");
        fill.className = "gauge-fill";
        // Pick threshold with highest `at` <= value
        if (p.thresholds && p.thresholds.length) {
          var bestState = null;
          var bestAt = -Infinity;
          for (var ti = 0; ti < p.thresholds.length; ti++) {
            var th = p.thresholds[ti];
            if (typeof th.at === "number" && th.at <= gVal && th.at >= bestAt) {
              bestAt = th.at;
              bestState = th.state;
            }
          }
          if (bestState) fill.classList.add("state-" + String(bestState));
        }
        fill.style.width = pct + "%";
        gauge.appendChild(fill);
        var gOverlay = document.createElement("span");
        gOverlay.className = "gauge-overlay";
        gOverlay.textContent = String(gVal) + (p.unit != null ? String(p.unit) : "");
        gauge.appendChild(gOverlay);
        return gauge;
      }
      case "progress_bar": {
        var prog = document.createElement("div");
        prog.className = "prim-progress";
        if (p.label != null) {
          var pLbl = document.createElement("div");
          pLbl.className = "progress-label";
          pLbl.textContent = String(p.label);
          prog.appendChild(pLbl);
        }
        var bar = document.createElement("div");
        bar.className = "prim-gauge";
        var barFill = document.createElement("div");
        barFill.className = "gauge-fill";
        if (p.indeterminate) {
          barFill.classList.add("indeterminate");
        } else {
          var pMax = typeof p.max === "number" && p.max > 0 ? p.max : 1;
          var pVal = typeof p.value === "number" ? p.value : 0;
          var pPct = (pVal / pMax) * 100;
          if (pPct < 0) pPct = 0;
          if (pPct > 100) pPct = 100;
          barFill.style.width = pPct + "%";
        }
        bar.appendChild(barFill);
        prog.appendChild(bar);
        return prog;
      }
      case "sparkline": {
        var SVG_NS = "http://www.w3.org/2000/svg";
        var W = 120, H = 24;
        var svg = document.createElementNS(SVG_NS, "svg");
        svg.setAttribute("class", "prim-sparkline");
        svg.setAttribute("width", String(W));
        svg.setAttribute("height", String(H));
        svg.setAttribute("viewBox", "0 0 " + W + " " + H);
        var pts = p.points || [];
        if (pts.length === 1) {
          var dot = document.createElementNS(SVG_NS, "circle");
          dot.setAttribute("cx", String(W / 2));
          dot.setAttribute("cy", String(H / 2));
          dot.setAttribute("r", "2");
          dot.setAttribute("fill", "currentColor");
          svg.appendChild(dot);
        } else if (pts.length > 1) {
          var sMin = pts[0], sMax = pts[0];
          for (var si = 1; si < pts.length; si++) {
            if (pts[si] < sMin) sMin = pts[si];
            if (pts[si] > sMax) sMax = pts[si];
          }
          var sSpan = sMax - sMin;
          var coords = [];
          for (var sj = 0; sj < pts.length; sj++) {
            var x = (sj / (pts.length - 1)) * W;
            var y = sSpan > 0 ? H - ((pts[sj] - sMin) / sSpan) * H : H / 2;
            coords.push(x.toFixed(2) + "," + y.toFixed(2));
          }
          var poly = document.createElementNS(SVG_NS, "polyline");
          poly.setAttribute("points", coords.join(" "));
          poly.setAttribute("fill", "none");
          poly.setAttribute("stroke", "currentColor");
          poly.setAttribute("stroke-width", "1");
          svg.appendChild(poly);
        }
        return svg;
      }
      case "list": {
        // TODO render `icon` and wire `action` aliases once action dispatch is plumbed
        var ul = document.createElement("ul");
        ul.className = "prim-list";
        var items = p.items || [];
        for (var li = 0; li < items.length; li++) {
          var item = items[li];
          var liEl = document.createElement("li");
          var titleDiv = document.createElement("div");
          titleDiv.className = "list-title";
          titleDiv.textContent = item.title == null ? "" : String(item.title);
          liEl.appendChild(titleDiv);
          if (item.subtitle != null) {
            var subDiv = document.createElement("div");
            subDiv.className = "list-subtitle";
            subDiv.textContent = String(item.subtitle);
            liEl.appendChild(subDiv);
          }
          if (item.trailing != null) {
            var trailSpan = document.createElement("span");
            trailSpan.className = "list-trailing";
            trailSpan.textContent = String(item.trailing);
            liEl.appendChild(trailSpan);
          }
          ul.appendChild(liEl);
        }
        return ul;
      }
      case "card": {
        var card = document.createElement("div");
        card.className = "prim-card";
        if (p.title != null) {
          var cTitle = document.createElement("div");
          cTitle.className = "card-title";
          cTitle.textContent = String(p.title);
          card.appendChild(cTitle);
        }
        if (p.subtitle != null) {
          var cSub = document.createElement("div");
          cSub.className = "card-subtitle";
          cSub.textContent = String(p.subtitle);
          card.appendChild(cSub);
        }
        var cBody = document.createElement("div");
        cBody.className = "card-body";
        if (p.body) cBody.appendChild(renderPrimitive(p.body));
        card.appendChild(cBody);
        if (p.footer) {
          var cFoot = document.createElement("div");
          cFoot.className = "card-footer";
          cFoot.appendChild(renderPrimitive(p.footer));
          card.appendChild(cFoot);
        }
        return card;
      }
      case "grid": {
        var grid = document.createElement("div");
        grid.className = "prim-grid";
        var gcols = typeof p.columns === "number" && p.columns > 0 ? p.columns : 2;
        grid.style.gridTemplateColumns = "repeat(" + gcols + ", 1fr)";
        var gcells = p.cells || [];
        for (var gi = 0; gi < gcells.length; gi++) {
          var cell = document.createElement("div");
          cell.className = "grid-cell";
          cell.appendChild(renderPrimitive(gcells[gi]));
          grid.appendChild(cell);
        }
        return grid;
      }
      case "panel": {
        var panel = document.createElement("div");
        panel.className = "prim-panel";
        var pTitle = document.createElement("div");
        pTitle.className = "panel-title";
        pTitle.textContent = p.title == null ? "" : String(p.title);
        panel.appendChild(pTitle);
        var pBody = document.createElement("div");
        pBody.className = "panel-body";
        if (p.body) pBody.appendChild(renderPrimitive(p.body));
        panel.appendChild(pBody);
        if (p.actions && p.actions.length) {
          var pActs = document.createElement("div");
          pActs.className = "panel-actions";
          for (var pai = 0; pai < p.actions.length; pai++) {
            pActs.appendChild(renderActionButton(p.actions[pai]));
          }
          panel.appendChild(pActs);
        }
        return panel;
      }
      case "tabs": {
        var tabsEl = document.createElement("div");
        tabsEl.className = "prim-tabs";
        var tabsHdr = document.createElement("div");
        tabsHdr.className = "tabs-header";
        var tabsBody = document.createElement("div");
        tabsBody.className = "tabs-body";
        var tarr = p.tabs || [];
        var tabBtns = [];
        function showTab(idx) {
          tabsBody.textContent = "";
          if (tarr[idx] && tarr[idx].body) {
            tabsBody.appendChild(renderPrimitive(tarr[idx].body));
          }
          for (var bi = 0; bi < tabBtns.length; bi++) {
            tabBtns[bi].classList.toggle("active", bi === idx);
          }
        }
        for (var ti = 0; ti < tarr.length; ti++) {
          (function (idx) {
            var b = document.createElement("button");
            b.className = "tab-btn";
            b.textContent = tarr[idx].label == null ? "" : String(tarr[idx].label);
            b.addEventListener("click", function () { showTab(idx); });
            tabBtns.push(b);
            tabsHdr.appendChild(b);
          })(ti);
        }
        tabsEl.appendChild(tabsHdr);
        tabsEl.appendChild(tabsBody);
        if (tarr.length) showTab(0);
        return tabsEl;
      }
      case "split": {
        var dir = p.direction === "col" ? "col" : "row";
        var splitEl = document.createElement("div");
        splitEl.className = "prim-split split-" + dir;
        var sparts = p.parts || [];
        for (var spi = 0; spi < sparts.length; spi++) {
          var part = document.createElement("div");
          part.className = "split-part";
          part.appendChild(renderPrimitive(sparts[spi]));
          splitEl.appendChild(part);
        }
        return splitEl;
      }
      case "line_chart":
      case "area_chart": {
        return renderXYChart(p, p.type === "area_chart");
      }
      case "bar_chart": {
        return renderBarChart(p);
      }
      case "heatmap": {
        return renderHeatmap(p);
      }
      case "top_list": {
        var ul2 = document.createElement("ul");
        ul2.className = "prim-toplist";
        var titems = p.items || [];
        var maxV = typeof p.max === "number" ? p.max : 0;
        if (!maxV) {
          for (var mi = 0; mi < titems.length; mi++) {
            var v = typeof titems[mi].value === "number" ? titems[mi].value : 0;
            if (v > maxV) maxV = v;
          }
        }
        if (maxV <= 0) maxV = 1;
        for (var tli = 0; tli < titems.length; tli++) {
          var ti2 = titems[tli];
          var liE = document.createElement("li");
          var lblE = document.createElement("span");
          lblE.className = "toplist-label";
          lblE.textContent = ti2.label == null ? "" : String(ti2.label);
          liE.appendChild(lblE);
          var trk = document.createElement("span");
          trk.className = "toplist-track";
          var brF = document.createElement("span");
          brF.className = "toplist-fill";
          var vNum = typeof ti2.value === "number" ? ti2.value : 0;
          var pctv = (vNum / maxV) * 100;
          if (pctv < 0) pctv = 0; if (pctv > 100) pctv = 100;
          brF.style.width = pctv + "%";
          trk.appendChild(brF);
          liE.appendChild(trk);
          var valE = document.createElement("span");
          valE.className = "toplist-value";
          valE.textContent = String(vNum) + (ti2.unit != null ? String(ti2.unit) : "");
          liE.appendChild(valE);
          ul2.appendChild(liE);
        }
        return ul2;
      }
      case "tree": {
        var troot = document.createElement("div");
        troot.className = "prim-tree";
        if (p.root) troot.appendChild(renderTreeNode(p.root, true));
        return troot;
      }
      case "json_view": {
        var jv = document.createElement("div");
        jv.className = "prim-jsonview";
        var depth = typeof p.expand_depth === "number" ? p.expand_depth : 1;
        jv.appendChild(renderJsonNode(p.value, 0, depth));
        return jv;
      }
      case "diff": {
        // TODO: a real LCS would produce minimal diffs. v1: line-by-line zip
        // and tag mismatches as del-then-add (naive but readable).
        var dpre = document.createElement("pre");
        dpre.className = "prim-diff";
        var beforeS = p.before == null ? "" : String(p.before);
        var afterS  = p.after  == null ? "" : String(p.after);
        var bl = beforeS.split("\n");
        var al = afterS.split("\n");
        var dn = Math.max(bl.length, al.length);
        for (var di = 0; di < dn; di++) {
          var b = di < bl.length ? bl[di] : null;
          var a = di < al.length ? al[di] : null;
          if (b !== null && a !== null && b === a) {
            var sEq = document.createElement("span");
            sEq.className = "diff-eq";
            sEq.textContent = "  " + b + "\n";
            dpre.appendChild(sEq);
          } else {
            if (b !== null) {
              var sDel = document.createElement("span");
              sDel.className = "diff-del";
              sDel.textContent = "- " + b + "\n";
              dpre.appendChild(sDel);
            }
            if (a !== null) {
              var sAdd = document.createElement("span");
              sAdd.className = "diff-add";
              sAdd.textContent = "+ " + a + "\n";
              dpre.appendChild(sAdd);
            }
          }
        }
        return dpre;
      }
      case "button": {
        var pbtn = document.createElement("button");
        pbtn.className = "prim-btn style-" + (p.style ? String(p.style) : "default");
        pbtn.textContent = p.label == null ? "" : String(p.label);
        var btnSlot = null;
        function ensureSlot() {
          if (!btnSlot) {
            btnSlot = document.createElement("div");
            btnSlot.className = "btn-result";
            pbtn.parentNode.insertBefore(btnSlot, pbtn.nextSibling);
          }
          btnSlot.textContent = "";
          return btnSlot;
        }
        function renderResultEnvelope(env) {
          var slot = ensureSlot();
          if (env && env.body) {
            slot.appendChild(renderPrimitive(env.body));
          } else if (env && env.error) {
            var er = document.createElement("div");
            er.className = "prim-text style-error";
            var ep = document.createElement("pre");
            ep.textContent = String(env.error);
            er.appendChild(ep);
            slot.appendChild(er);
          }
        }
        pbtn.addEventListener("click", function () {
          var aliasId = p.alias == null ? "" : String(p.alias);
          if (!aliasId) return;
          if (p.confirm) {
            // Reuse the existing confirmation modal flow. action_index = 0
            // for primitive-emitted buttons (no action list to disambiguate).
            pendingAction = {
              aliasId: aliasId, actionIndex: 0,
              command: aliasId, label: p.label == null ? aliasId : String(p.label),
              btn: pbtn,
              // Override the post-modal handler: render into our slot
              // instead of the global output panel.
              inlineRender: renderResultEnvelope,
            };
            fetchCapInfo(aliasId, 0).then(function (capInfo) {
              var displayCommand = (capInfo && capInfo.exec_args) ? capInfo.exec_args : aliasId;
              showModal(pendingAction.label, displayCommand, capInfo);
            }).catch(function () {
              showModal(pendingAction.label, aliasId, null);
            });
          } else {
            executeAlias(aliasId, p.args, renderResultEnvelope);
          }
        });
        return pbtn;
      }
      case "confirm": {
        var conf = document.createElement("div");
        conf.className = "prim-confirm" + (p.danger ? " danger" : "");
        var promptEl = document.createElement("div");
        promptEl.className = "confirm-prompt";
        promptEl.textContent = p.prompt == null ? "" : String(p.prompt);
        conf.appendChild(promptEl);
        var btnsEl = document.createElement("div");
        btnsEl.className = "confirm-buttons";
        var cBtn = document.createElement("button");
        cBtn.className = "prim-btn style-" + (p.danger ? "danger" : "primary");
        cBtn.textContent = "Confirm";
        var xBtn = document.createElement("button");
        xBtn.className = "prim-btn style-default";
        xBtn.textContent = "Cancel";
        btnsEl.appendChild(cBtn);
        btnsEl.appendChild(xBtn);
        conf.appendChild(btnsEl);
        var confSlot = null;
        cBtn.addEventListener("click", function () {
          var aliasId = p.alias == null ? "" : String(p.alias);
          if (!aliasId) return;
          if (!confSlot) {
            confSlot = document.createElement("div");
            confSlot.className = "btn-result";
            conf.appendChild(confSlot);
          }
          confSlot.textContent = "";
          executeAlias(aliasId, p.args, function (env) {
            confSlot.textContent = "";
            if (env && env.body) {
              confSlot.appendChild(renderPrimitive(env.body));
            } else if (env && env.error) {
              var er2 = document.createElement("div");
              er2.className = "prim-text style-error";
              var ep2 = document.createElement("pre");
              ep2.textContent = String(env.error);
              er2.appendChild(ep2);
              confSlot.appendChild(er2);
            }
          });
        });
        xBtn.addEventListener("click", function () {
          if (confSlot) { confSlot.textContent = ""; }
        });
        return conf;
      }
      case "action_menu": {
        var amWrap = document.createElement("div");
        amWrap.className = "prim-action-menu";
        var amItems = p.items || [];
        var amSlot = null;
        for (var ami = 0; ami < amItems.length; ami++) {
          (function (item) {
            var ab = document.createElement("button");
            ab.className = "prim-btn style-default";
            ab.textContent = item.label == null ? "" : String(item.label);
            ab.addEventListener("click", function () {
              var aliasId = item.alias == null ? "" : String(item.alias);
              if (!aliasId) return;
              if (!amSlot) {
                amSlot = document.createElement("div");
                amSlot.className = "btn-result";
                amWrap.appendChild(amSlot);
              }
              amSlot.textContent = "";
              executeAlias(aliasId, item.args, function (env) {
                amSlot.textContent = "";
                if (env && env.body) {
                  amSlot.appendChild(renderPrimitive(env.body));
                } else if (env && env.error) {
                  var er3 = document.createElement("div");
                  er3.className = "prim-text style-error";
                  var ep3 = document.createElement("pre");
                  ep3.textContent = String(env.error);
                  er3.appendChild(ep3);
                  amSlot.appendChild(er3);
                }
              });
            });
            amWrap.appendChild(ab);
          })(amItems[ami]);
        }
        return amWrap;
      }
      case "form": {
        // TODO: real form rendering needs field-type widgets, validation, and
        // submit semantics. The renderer stub keeps this primitive out of the
        // unknown-type fallback while the design is sorted.
        var fEl = document.createElement("div");
        fEl.className = "prim-form-placeholder";
        var lbl = p.submit_label != null ? String(p.submit_label)
                : (p.submit_alias != null ? String(p.submit_alias) : "");
        fEl.textContent = "Form: " + lbl + " (renderer TODO)";
        return fEl;
      }
      case "log_stream": {
        // Render a table skeleton from the column declaration. The returned
        // node carries `__stream` with append(frame)/reset() for the SSE
        // consumer to call as frames arrive.
        var cols = (p.columns && p.columns.length) ? p.columns : [
          { key: "time",    label: "Time",    type: "timestamp" },
          { key: "level",   label: "Level",   type: "string" },
          { key: "message", label: "Message", type: "string" },
        ];
        var lsTable = document.createElement("table");
        lsTable.className = "prim-log-stream";
        var lsThead = document.createElement("thead");
        var lsHr = document.createElement("tr");
        for (var lci = 0; lci < cols.length; lci++) {
          var lth = document.createElement("th");
          lth.textContent = String(cols[lci].label || cols[lci].key || "");
          lsHr.appendChild(lth);
        }
        lsThead.appendChild(lsHr);
        lsTable.appendChild(lsThead);
        var lsTbody = document.createElement("tbody");
        lsTable.appendChild(lsTbody);
        var lsWrap = document.createElement("div");
        lsWrap.className = "prim-log-stream-wrap";
        lsWrap.appendChild(lsTable);
        var MAX_ROWS = 1000;
        lsWrap.__stream = {
          append: function (frame) {
            var atBottom = (lsWrap.scrollTop + lsWrap.clientHeight + 4 >= lsWrap.scrollHeight);
            var tr = document.createElement("tr");
            for (var ci = 0; ci < cols.length; ci++) {
              var td = document.createElement("td");
              var k = cols[ci].key;
              var v = (frame && frame[k] != null) ? frame[k] : "";
              td.textContent = String(v);
              tr.appendChild(td);
            }
            lsTbody.appendChild(tr);
            while (lsTbody.childNodes.length > MAX_ROWS) {
              lsTbody.removeChild(lsTbody.firstChild);
            }
            if (atBottom) lsWrap.scrollTop = lsWrap.scrollHeight;
          },
          reset: function () {
            while (lsTbody.firstChild) lsTbody.removeChild(lsTbody.firstChild);
          },
        };
        return lsWrap;
      }
      case "live_table":
      case "event_stream": {
        // TODO(streaming-phase-2): live_table and event_stream renderers.
        var sEl = document.createElement("div");
        sEl.className = "prim-stream-placeholder";
        sEl.textContent = "Streaming: " + String(p.type) + " (renderer TODO)";
        return sEl;
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

  // Track an in-flight stream so the user can stop it / so the next execute
  // aborts the previous one. There is at most one active stream — opening a
  // new one supersedes the previous.
  var activeStream = null;

  function abortActiveStream() {
    if (activeStream && activeStream.abort) {
      try { activeStream.abort(); } catch (e) {}
    }
    activeStream = null;
  }

  // RECONNECT_DELAYS_MS: client-side reconnect schedule when the SSE stream
  // closes mid-flight (network blip, server reload, etc). The user may
  // explicitly stop, which clears activeStream and breaks the loop.
  var RECONNECT_DELAYS_MS = [250, 500, 1000, 2000, 5000];

  // Drive an SSE-mode response into the result panel. lastEventId is the
  // resume id; for the first call it is null.
  function pumpStreamingExecute(action, lastEventId, attempt) {
    postExecuteWithStream(action.aliasId, action.actionIndex, lastEventId)
      .then(function (resp) {
        if (resp.kind === "json") {
          var label = action.label + (resp.env && resp.env.ok === false ? " — error" : " — output");
          renderEnvelope(label, resp.env);
          return;
        }
        // Streaming: register active and consume.
        var streamCtx = { abort: resp.abort, lastId: lastEventId, stopped: false };
        activeStream = streamCtx;
        var streamNode = null; // set after schema event
        consumeStream(resp.reader, {
          onFrame: function (ev, id, data) {
            if (streamCtx.stopped) return;
            if (id != null) streamCtx.lastId = id;
            if (ev === "schema") {
              var schemaEnv;
              try { schemaEnv = JSON.parse(data); } catch (e) { schemaEnv = null; }
              if (!schemaEnv) return;
              renderEnvelope(action.label + " — streaming", schemaEnv);
              streamNode = outputBodyEl.firstChild;
              ensureStopButton(streamCtx);
            } else if (ev === "end") {
              streamCtx.stopped = true;
              clearStopButton();
            } else if (ev === "error") {
              var errEnv;
              try { errEnv = JSON.parse(data); } catch (e) { errEnv = null; }
              if (errEnv) renderEnvelope(action.label + " — error", errEnv);
              streamCtx.stopped = true;
              clearStopButton();
            } else if (ev === "gap") {
              if (streamNode && streamNode.__stream) streamNode.__stream.reset();
            } else {
              // default "message": frame
              if (!streamNode || !streamNode.__stream) return;
              var payload;
              try { payload = JSON.parse(data); } catch (e) { return; }
              if (payload && payload.type === "frame" && payload.frame) {
                streamNode.__stream.append(payload.frame);
              }
            }
          },
          onDone: function () {
            // Stream closed by server. If user did not stop and we did not
            // see end/error, attempt reconnect with backoff.
            if (streamCtx.stopped) { activeStream = null; return; }
            if (activeStream !== streamCtx) return; // superseded
            var delay = RECONNECT_DELAYS_MS[Math.min(attempt || 0, RECONNECT_DELAYS_MS.length - 1)];
            setTimeout(function () {
              if (activeStream !== streamCtx) return;
              pumpStreamingExecute(action, streamCtx.lastId, (attempt || 0) + 1);
            }, delay);
          },
          onError: function (err) {
            var errEnv = { ok: false, error: "stream error: " + (err && err.message ? err.message : String(err)) };
            renderEnvelope(action.label + " — error", errEnv);
            streamCtx.stopped = true;
            activeStream = null;
            clearStopButton();
          },
        }).catch(function (err) {
          if (streamCtx.stopped) return;
          var delay = RECONNECT_DELAYS_MS[Math.min(attempt || 0, RECONNECT_DELAYS_MS.length - 1)];
          setTimeout(function () {
            if (activeStream !== streamCtx) return;
            pumpStreamingExecute(action, streamCtx.lastId, (attempt || 0) + 1);
          }, delay);
        });
      })
      .catch(function (err) {
        var errEnv = { ok: false,
          error: "request failed: " + (err && err.message ? err.message : "network error") };
        renderEnvelope(action.label + " — error", errEnv);
      });
  }

  // Inject a stop button into the output panel header. Removed via
  // clearStopButton when the stream ends or another stream replaces this one.
  var stopBtnEl = null;
  function ensureStopButton(streamCtx) {
    clearStopButton();
    stopBtnEl = document.createElement("button");
    stopBtnEl.className = "prim-btn style-default stream-stop";
    stopBtnEl.textContent = "Stop";
    stopBtnEl.addEventListener("click", function () {
      streamCtx.stopped = true;
      try { streamCtx.abort(); } catch (e) {}
      activeStream = null;
      clearStopButton();
    });
    if (outputLabelEl && outputLabelEl.parentNode) {
      outputLabelEl.parentNode.appendChild(stopBtnEl);
    }
  }
  function clearStopButton() {
    if (stopBtnEl && stopBtnEl.parentNode) stopBtnEl.parentNode.removeChild(stopBtnEl);
    stopBtnEl = null;
  }

  modalExecuteEl.addEventListener("click", function () {
    if (!pendingAction) return;
    var action = pendingAction;
    hideModal();
    abortActiveStream();
    if (action.inlineRender) {
      // Inline render path is used by row buttons / panels; non-streaming.
      postExecute(action.aliasId, action.actionIndex).then(function (env) {
        action.inlineRender(env);
      }).catch(function (err) {
        action.inlineRender({ ok: false,
          error: "request failed: " + (err && err.message ? err.message : "network error") });
      });
      return;
    }
    pumpStreamingExecute(action, null, 0);
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
