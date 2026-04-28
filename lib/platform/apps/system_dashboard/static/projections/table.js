// projections/table.js
//
// Atomic projection for
// `{columns: [{key, label, type, sortable?, align?}], rows: record[],
//   default_sort?, row_actions?}`.
// Renders <table class="prim-table"> with <thead>/<tbody>. Cell value is
// `String(row[col.key])` (or empty string if undefined). Per-cell `align`
// is applied via inline style (`textAlign`) when set on the column —
// `<td align>` is a deprecated HTML attribute and not in dom.js's allowlist.
// `sortable`, `default_sort`, `row_actions` are accepted for schema parity
// but not yet wired (matches the legacy renderPrimitive renderer).

import { dom } from "../dom.js";
import { register } from "./registry.js";

function projectTable(value, _ctx) {
  const cols = value.columns || [];
  const rows = value.rows || [];
  const headCells = [];
  for (let i = 0; i < cols.length; i++) {
    const label = cols[i].label == null ? "" : String(cols[i].label);
    headCells.push(dom.th({}, [label]));
  }
  const bodyRows = [];
  for (let r = 0; r < rows.length; r++) {
    const tds = [];
    for (let c = 0; c < cols.length; c++) {
      const cell = rows[r][cols[c].key];
      const text = cell == null ? "" : String(cell);
      const props = cols[c].align
        ? { style: { textAlign: String(cols[c].align) } }
        : {};
      tds.push(dom.td(props, [text]));
    }
    bodyRows.push(dom.tr({}, tds));
  }
  return dom.table({ class: "prim-table" }, [
    dom.thead({}, [dom.tr({}, headCells)]),
    dom.tbody({}, bodyRows),
  ]);
}

register("table", projectTable);
