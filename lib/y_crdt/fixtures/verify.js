// lib/y_crdt/fixtures/verify.js
//
// Fuzz-parity oracle: reads a JSON operation script from stdin, applies it
// to a REAL yjs Y.Doc, and writes the resulting full-document update
// (Y.encodeStateAsUpdate) as a hex string on stdout. lib/y_crdt/parity_fuzz.lua
// shells out to this (via bun) once per fuzz iteration, performs the same
// operations against the Lua implementation, and compares the two update
// payloads byte-for-byte.
//
// Input JSON shape: { client_id: number, kind: "text" | "array" | "map", ops: [...] }
//   kind "text":  ops are { op: "insert", index, text } | { op: "delete", index, length } | { op: "format", index, length, key, value }
//   kind "array": ops are { op: "insert", index, values } | { op: "delete", index, length }
//   kind "map":   ops are { op: "set", key, value } | { op: "delete", key }
//
// Output: a single line of lowercase hex on stdout. Any error is reported on
// stderr with a non-zero exit code (the caller treats that as a fuzz-harness
// bug, not a parity mismatch, per lib/test/fuzz.lua's own error/crash split).

import * as Y from "yjs";

function readStdin() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on("data", (c) => chunks.push(c));
    process.stdin.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    process.stdin.on("error", reject);
  });
}

function hex(buf) {
  return Buffer.from(buf).toString("hex");
}

async function main() {
  const input = JSON.parse(await readStdin());
  const doc = new Y.Doc();
  doc.clientID = input.client_id;

  if (input.kind === "text") {
    const t = doc.getText("content");
    for (const op of input.ops) {
      if (op.op === "insert") t.insert(op.index, op.text);
      else if (op.op === "delete") t.delete(op.index, op.length);
      else if (op.op === "format") t.format(op.index, op.length, { [op.key]: op.value });
      else throw new Error("verify.js: unknown text op " + JSON.stringify(op));
    }
  } else if (input.kind === "array") {
    const a = doc.getArray("content");
    for (const op of input.ops) {
      if (op.op === "insert") a.insert(op.index, op.values);
      else if (op.op === "delete") a.delete(op.index, op.length);
      else throw new Error("verify.js: unknown array op " + JSON.stringify(op));
    }
  } else if (input.kind === "map") {
    const m = doc.getMap("content");
    for (const op of input.ops) {
      if (op.op === "set") m.set(op.key, op.value);
      else if (op.op === "delete") m.delete(op.key);
      else throw new Error("verify.js: unknown map op " + JSON.stringify(op));
    }
  } else {
    throw new Error("verify.js: unknown kind " + JSON.stringify(input.kind));
  }

  const update = Y.encodeStateAsUpdate(doc);
  process.stdout.write(hex(update) + "\n");
}

main().catch((err) => {
  process.stderr.write("verify.js error: " + (err && err.stack || err) + "\n");
  process.exit(1);
});
