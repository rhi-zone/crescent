// Tests for ../regex.js init().

import { describe, test, expect, beforeEach } from "bun:test";
import { loadIndexHtml, flush, escAttr } from "./helpers.js";
import { installFetchMock } from "./mock-fetch.js";
import { init as initRegex } from "../regex.js";

let mock, errors;
beforeEach(() => {
  loadIndexHtml();
  mock = installFetchMock();
  errors = [];
});

function makeDeps() {
  return { showError: (m) => errors.push(m), escAttr };
}

describe("regex.init", () => {
  test("returns { reload }", () => {
    const api = initRegex(makeDeps());
    expect(typeof api.reload).toBe("function");
  });

  test("reload() fetches /api/regex and renders into #regex-list", async () => {
    mock.respond("/api/regex", () => ({
      status: 200,
      json: { scripts: [
        { name: "S1", find: "a", replace: "b", enabled: true, scope: "ai_output", order: 0 },
      ] },
    }));
    const api = initRegex(makeDeps());
    await api.reload();
    await flush();
    const list = document.getElementById("regex-list");
    const entries = list.querySelectorAll(".regex-entry");
    expect(entries.length).toBe(1);
    const name = entries[0].querySelector(".regex-entry__name");
    expect(name.textContent).toBe("S1");
  });

  test("HTML in script name is escaped on render", async () => {
    const xss = '<script>alert(1)</script>';
    mock.respond("/api/regex", () => ({
      status: 200,
      json: { scripts: [
        { name: xss, find: "a", replace: "b", enabled: true, scope: "display", order: 0 },
      ] },
    }));
    const api = initRegex(makeDeps());
    await api.reload();
    await flush();
    const list = document.getElementById("regex-list");
    // The header name is set via textContent → safe by construction.
    const headerName = list.querySelector(".regex-entry__name");
    expect(headerName.textContent).toBe(xss);
    // The body input renders the name via innerHTML + escAttr — verify no
    // raw <script> tag leaked into the DOM as an element.
    const body = list.querySelector(".regex-entry__body");
    const leaked = body.querySelector("script");
    expect(leaked).toBeNull();
  });

  test("test button POSTs to /api/regex/test and renders output", async () => {
    mock.respond("/api/regex/test", () => ({ status: 200, json: { output: "RESULT" } }));
    initRegex(makeDeps());
    document.getElementById("regex-test-find").value = "foo";
    document.getElementById("regex-test-replace").value = "bar";
    document.getElementById("regex-test-input").value = "foobar";
    document.getElementById("regex-test-btn").click();
    await flush();
    const call = mock.findCall("POST", "/api/regex/test");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ find: "foo", replace: "bar", input: "foobar" });
    expect(document.getElementById("regex-test-output").textContent).toBe("RESULT");
  });

  test("delete button confirms before DELETE-equivalent POST", async () => {
    mock.respond("/api/regex", () => ({
      status: 200,
      json: { scripts: [
        { name: "ToDel", find: "x", replace: "y", enabled: true, scope: "ai_output", order: 0 },
      ] },
    }));
    mock.respond("/api/regex/delete", () => ({ status: 200, json: { ok: true } }));
    const api = initRegex(makeDeps());
    await api.reload();
    await flush();
    const delBtn = document.querySelector(".regex-entry__delete");
    window.confirm = () => false;
    delBtn.click();
    await flush();
    expect(mock.findCall("POST", "/api/regex/delete")).toBeUndefined();

    window.confirm = () => true;
    delBtn.click();
    await flush();
    const call = mock.findCall("POST", "/api/regex/delete");
    expect(call).toBeDefined();
    expect(call.body).toEqual({ name: "ToDel" });
  });

  test("add button POSTs default new script", async () => {
    mock.respond("/api/regex", () => ({ status: 200, json: { scripts: [] } }));
    mock.respond("/api/regex/save", () => ({ status: 200, json: { ok: true } }));
    initRegex(makeDeps());
    document.getElementById("regex-add").click();
    await flush();
    const call = mock.findCall("POST", "/api/regex/save");
    expect(call).toBeDefined();
    expect(call.body.name).toBe("New Script");
    expect(call.body.scope).toBe("ai_output");
  });
});
