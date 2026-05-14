// Tests for ../persona.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initPersona } from "../persona.js";

let mock;
let errors;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = [];
});

function makeDeps() {
  return { showError: (m) => errors.push(m) };
}

describe("persona.init", () => {
  test("returns an object exposing reload()", () => {
    const api = initPersona(makeDeps());
    expect(typeof api.reload).toBe("function");
  });

  test("reload() GETs /api/personas and populates #persona-select", async () => {
    mock.respond("/api/personas", () => ({
      status: 200,
      json: {
        personas: [{ name: "Alice", description: "a" }, { name: "Bob", description: "b" }],
        active: "Bob",
      },
    }));
    const api = initPersona(makeDeps());
    await api.reload();
    await flush();
    const sel = document.getElementById("persona-select");
    expect(sel.children.length).toBe(2);
    expect(sel.children[0].value).toBe("Alice");
    expect(sel.children[1].value).toBe("Bob");
    expect(sel.children[1].selected).toBe(true);
  });

  test("clicking #persona-save POSTs name/description to /api/personas/save", async () => {
    mock.respond("/api/personas", () => ({ status: 200, json: { personas: [], active: "" } }));
    mock.respond("/api/personas/save", () => ({ status: 200, json: { ok: true } }));
    mock.respond("/api/personas/activate", () => ({ status: 200, json: { ok: true } }));
    initPersona(makeDeps());
    document.getElementById("persona-name").value = "Carol";
    document.getElementById("persona-description").value = "desc";
    document.getElementById("persona-save").click();
    await flush();
    const saveCall = mock.findCall("POST", "/api/personas/save");
    expect(saveCall).toBeDefined();
    expect(saveCall.body).toEqual({ name: "Carol", description: "desc" });
  });

  test("clicking #persona-delete confirms then POSTs delete", async () => {
    mock.respond("/api/personas/delete", () => ({ status: 200, json: { ok: true } }));
    mock.respond("/api/personas", () => ({ status: 200, json: { personas: [], active: "" } }));
    initPersona(makeDeps());
    // Seed selection.
    const sel = document.getElementById("persona-select");
    const opt = document.createElement("option");
    opt.value = "Dave"; opt.textContent = "Dave";
    sel.appendChild(opt);
    sel.value = "Dave";
    window.confirm = () => true;
    document.getElementById("persona-delete").click();
    await flush();
    const delCall = mock.findCall("POST", "/api/personas/delete");
    expect(delCall).toBeDefined();
    expect(delCall.body).toEqual({ name: "Dave" });
  });

  test("clicking #persona-delete with confirm=false does NOT POST delete", async () => {
    mock.respond("/api/personas/delete", () => ({ status: 200, json: { ok: true } }));
    initPersona(makeDeps());
    const sel = document.getElementById("persona-select");
    const opt = document.createElement("option");
    opt.value = "Dave"; opt.textContent = "Dave";
    sel.appendChild(opt);
    sel.value = "Dave";
    window.confirm = () => false;
    document.getElementById("persona-delete").click();
    await flush();
    expect(mock.findCall("POST", "/api/personas/delete")).toBeUndefined();
  });

  test("clicking #persona-new clears the form", () => {
    initPersona(makeDeps());
    const name = document.getElementById("persona-name");
    const desc = document.getElementById("persona-description");
    name.value = "old"; desc.value = "old desc";
    document.getElementById("persona-new").click();
    expect(name.value).toBe("");
    expect(desc.value).toBe("");
  });
});
