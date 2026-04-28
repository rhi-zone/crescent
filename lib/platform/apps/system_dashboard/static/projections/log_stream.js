// projections/log_stream.js
//
// Streaming projection for
// `{type: "log_stream", columns?: [{key,label?,type?}...], max_rows?: number}`.
//
// Returns a StreamConsumer rather than a plain Element. The host SSE consumer
// reads `__stream === true` and drives the projection imperatively via
// onFrame / onGap / onError / onEnd / dispose. The projection captures
// references to the tbody and scrollable wrapper as closure locals and mutates
// them in place — there is no virtual DOM diff.
//
// Visual: a scrollable wrapper containing a <table class="prim-log-stream">
// with <thead> derived from `columns` (defaults to time/level/message) and a
// <tbody> capped at `max_rows` (default 1000). New rows append to the bottom;
// the wrapper auto-scrolls to follow the tail UNLESS the user has scrolled up,
// in which case scroll position is preserved.

import { dom } from "../dom.js";
import { register } from "./registry.js";

const DEFAULT_COLUMNS = [
  { key: "time",    label: "Time",    type: "timestamp" },
  { key: "level",   label: "Level",   type: "string" },
  { key: "message", label: "Message", type: "string" },
];

function projectLogStream(value, _ctx) {
  const cols = (value.columns && value.columns.length) ? value.columns : DEFAULT_COLUMNS;
  const maxRows = (typeof value.max_rows === "number" && value.max_rows > 0)
    ? value.max_rows : 1000;

  const headerCells = cols.map((c) =>
    dom.th({}, [String(c.label || c.key || "")]),
  );
  const tbody = dom.tbody({}, []);
  const table = dom.table({ class: "prim-log-stream" }, [
    dom.thead({}, [dom.tr({}, headerCells)]),
    tbody,
  ]);
  const wrap = dom.div({ class: "prim-log-stream-wrap" }, [table]);

  let rowCount = 0;

  function appendRow(frame) {
    const atBottom = (wrap.scrollTop + wrap.clientHeight + 4 >= wrap.scrollHeight);
    const cells = cols.map((c) => {
      const v = (frame != null && frame[c.key] != null) ? frame[c.key] : "";
      return dom.td({}, [String(v)]);
    });
    tbody.appendChild(dom.tr({}, cells));
    rowCount++;
    while (rowCount > maxRows) {
      tbody.removeChild(tbody.firstChild);
      rowCount--;
    }
    if (atBottom) wrap.scrollTop = wrap.scrollHeight;
  }

  function appendErrorRow(err) {
    // Best-effort: paint the error into the message column if present, else
    // fall back to a single concatenated cell spanning the row visually via
    // the first cell. We don't use colspan because dom.js doesn't allowlist
    // it; the error text just lands in whichever column is named "message"
    // (default columns) or in the first cell otherwise.
    const errStr = String(err);
    const synthetic = {};
    let placed = false;
    for (let i = 0; i < cols.length; i++) {
      if (cols[i].key === "message") {
        synthetic.message = "[error] " + errStr;
        placed = true;
      } else if (cols[i].key === "level") {
        synthetic.level = "error";
      }
    }
    if (!placed && cols.length > 0) {
      synthetic[cols[0].key] = "[error] " + errStr;
    }
    appendRow(synthetic);
  }

  return {
    __stream: true,
    el: wrap,
    onFrame: appendRow,
    onGap: function () {
      tbody.replaceChildren();
      rowCount = 0;
    },
    onError: appendErrorRow,
  };
}

register("log_stream", projectLogStream);
