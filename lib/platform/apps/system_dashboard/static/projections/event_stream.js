// projections/event_stream.js
//
// Streaming projection for
// `{type: "event_stream", max_events?: number}`.
//
// Returns a StreamConsumer. Each frame has shape `{time, kind, body}` where
// `body` is a Primitive that recurses through `ctx.project`. The projection
// renders each frame as an event-row containing a <time> element, a kind
// label, and a body slot whose contents come from the registry.
//
// Visual: a scrollable <div class="prim-event-stream"> capped at `max_events`
// rows (default 500). Auto-scrolls to follow the tail unless the user has
// scrolled up — same sticky-bottom behaviour as log_stream.
//
// Errors append a synthetic event-row with kind "error" and a plain text
// body (no recursion through ctx.project for error strings — the error is
// a transport-level signal, not app data).

import { dom } from "../dom.js";
import { register } from "./registry.js";

function formatTime(t) {
  if (t == null) return "";
  if (typeof t === "number") {
    try { return new Date(t).toISOString(); } catch (_e) { return String(t); }
  }
  return String(t);
}

function projectEventStream(value, ctx) {
  const maxEvents = (typeof value.max_events === "number" && value.max_events > 0)
    ? value.max_events : 500;

  const wrap = dom.div({ class: "prim-event-stream" }, []);
  let count = 0;

  function appendRow(row) {
    const atBottom = (wrap.scrollTop + wrap.clientHeight + 4 >= wrap.scrollHeight);
    wrap.appendChild(row);
    count++;
    while (count > maxEvents) {
      wrap.removeChild(wrap.firstChild);
      count--;
    }
    if (atBottom) wrap.scrollTop = wrap.scrollHeight;
  }

  function onFrame(frame) {
    if (frame == null || typeof frame !== "object") return;
    const iso = formatTime(frame.time);
    const kind = frame.kind == null ? "" : String(frame.kind);
    const timeChildren = [iso];
    const timeProps = { class: "event-time" };
    // Only set datetime when it parses to a valid ISO string; dom.js does
    // not validate the attribute value, so we keep it permissive but skip
    // empty values to avoid littering the DOM with `datetime=""`.
    if (iso) timeProps.datetime = iso;
    const bodyChildren = (frame.body != null) ? [ctx.project(frame.body)] : [];
    appendRow(dom.div({ class: "event-row" }, [
      dom.time(timeProps, timeChildren),
      dom.span({ class: "event-kind" }, [kind]),
      dom.div({ class: "event-body" }, bodyChildren),
    ]));
  }

  function onError(err) {
    appendRow(dom.div({ class: "event-row event-row-error" }, [
      dom.time({ class: "event-time" }, [""]),
      dom.span({ class: "event-kind" }, ["error"]),
      dom.div({ class: "event-body" }, [String(err)]),
    ]));
  }

  return {
    __stream: true,
    el: wrap,
    onFrame: onFrame,
    onGap: function () {
      wrap.replaceChildren();
      count = 0;
    },
    onError: onError,
  };
}

register("event_stream", projectEventStream);
