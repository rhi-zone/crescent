// projections/live_table.js
//
// Streaming projection for
// `{type: "live_table", key: string, columns: [{key,label?,type?}...]}`.
//
// Returns a StreamConsumer. Frame shape is a discriminated union:
//   {op: "upsert", row: {<col>: value, ...}}
//   {op: "delete", key: <keyValue>}
//   {op: "reset"}
//
// `value.key` names the column whose value identifies a row. The projection
// maintains a Map<keyValue, <tr>> as closure-local state so upserts can locate
// the existing row in O(1). Deletes drop the entry from the map and the DOM.
// `reset` (or onGap) wipes both. Unknown ops are logged and skipped.
//
// Errors are logged to the console rather than rendered into the table — a
// structured row grid is the wrong place for free-text error messages, and
// the host already surfaces transport errors elsewhere.

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectLiveTable(value, _ctx) {
  const cols = (value.columns && value.columns.length) ? value.columns : [];
  const keyCol = String(value.key || "id");

  const headerCells = cols.map((c) =>
    dom.th({}, [String(c.label || c.key || "")]),
  );
  const tbody = dom.tbody({}, []);
  const table = dom.table({ class: "prim-live-table" }, [
    dom.thead({}, [dom.tr({}, headerCells)]),
    tbody,
  ]);
  const wrap = dom.div({ class: "prim-live-table-wrap" }, [table]);

  const rows = new Map(); // keyValue -> <tr>

  function buildRow(rowData) {
    const cells = cols.map((c) => {
      const v = (rowData != null && rowData[c.key] != null) ? rowData[c.key] : "";
      return dom.td({}, [String(v)]);
    });
    return dom.tr({}, cells);
  }

  function clearAll() {
    tbody.replaceChildren();
    rows.clear();
  }

  function onFrame(frame) {
    if (frame == null || typeof frame !== "object") return;
    const op = frame.op;
    if (op === "upsert") {
      const row = frame.row;
      if (row == null) return;
      const k = row[keyCol];
      if (k == null) return;
      const next = buildRow(row);
      const existing = rows.get(k);
      if (existing) {
        tbody.replaceChild(next, existing);
      } else {
        tbody.appendChild(next);
      }
      rows.set(k, next);
      return;
    }
    if (op === "delete") {
      const k = frame.key;
      const existing = rows.get(k);
      if (existing) {
        tbody.removeChild(existing);
        rows.delete(k);
      }
      return;
    }
    if (op === "reset") {
      clearAll();
      return;
    }
    // eslint-disable-next-line no-console
    console.warn("live_table: unknown op", op);
  }

  return {
    __stream: true,
    el: wrap,
    onFrame: onFrame,
    onGap: clearAll,
    onError: function (err) {
      // eslint-disable-next-line no-console
      console.warn("live_table: stream error", err);
    },
  };
}

register("live_table", projectLiveTable);
