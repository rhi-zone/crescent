// Minimal markdown-to-HTML renderer for message content.
// Security: HTML entities are escaped before any markdown processing,
// so user input cannot inject raw HTML.

/**
 * Escape HTML entities in a string.
 * @param {string} s
 * @returns {string}
 */
function escapeHtml(s) {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * Process inline markdown: bold, italic, code, links, strikethrough.
 * Assumes input is already HTML-escaped.
 * @param {string} line
 * @returns {string}
 */
function renderInline(line) {
  // Inline code (must come first to prevent inner processing)
  line = line.replace(/`([^`\n]+?)`/g, '<code class="md-inline-code">$1</code>');

  // Bold+italic: ***text*** or ___text___
  line = line.replace(/\*\*\*(.+?)\*\*\*/g, "<strong><em>$1</em></strong>");
  line = line.replace(/___(.+?)___/g, "<strong><em>$1</em></strong>");

  // Bold: **text** or __text__
  line = line.replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>");
  line = line.replace(/__(.+?)__/g, "<strong>$1</strong>");

  // Italic: *text* or _text_ (but not mid-word underscores like foo_bar_baz)
  line = line.replace(/\*(.+?)\*/g, "<em>$1</em>");
  line = line.replace(/(^|[\s(])_(.+?)_([\s).,:;!?]|$)/g, "$1<em>$2</em>$3");

  // Strikethrough: ~~text~~
  line = line.replace(/~~(.+?)~~/g, "<del>$1</del>");

  // Links: [text](url)
  line = line.replace(
    /\[([^\]]+?)\]\(([^)]+?)\)/g,
    '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>'
  );

  // Auto-link bare URLs (http/https only, not already inside an href)
  line = line.replace(
    /(^|[^"=])(https?:\/\/[^\s<)]+)/g,
    '$1<a href="$2" target="_blank" rel="noopener noreferrer">$2</a>'
  );

  return line;
}

/**
 * Render a markdown string to safe HTML.
 * @param {string} text Raw markdown text
 * @returns {string} HTML string
 */
export function renderMarkdown(text) {
  if (!text) return "";

  // Normalize line endings
  text = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");

  // Escape HTML entities FIRST (security)
  text = escapeHtml(text);

  const lines = text.split("\n");
  const out = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    // Fenced code block: ```lang ... ```
    if (line.match(/^`{3,}/)) {
      // fence is non-null: the if-guard above already matched the same pattern
      const fence = /** @type {RegExpMatchArray} */ (line.match(/^(`{3,})(.*)/));
      const lang = fence[2].trim();
      const fenceLen = fence[1].length;
      const codeLines = [];
      i++;
      while (i < lines.length) {
        if (lines[i].match(new RegExp("^`{" + fenceLen + ",}\\s*$"))) {
          i++;
          break;
        }
        codeLines.push(lines[i]);
        i++;
      }
      const langAttr = lang ? ' data-lang="' + escapeHtml(lang) + '"' : "";
      out.push(
        '<pre class="md-code-block"' + langAttr + "><code>" +
        codeLines.join("\n") +
        "</code></pre>"
      );
      continue;
    }

    // Headings: # H1 through ###### H6
    const headingMatch = line.match(/^(#{1,6})\s+(.+)$/);
    if (headingMatch) {
      const level = headingMatch[1].length;
      out.push(
        "<h" + level + ' class="md-heading">' +
        renderInline(headingMatch[2]) +
        "</h" + level + ">"
      );
      i++;
      continue;
    }

    // Horizontal rule: --- or *** or ___ (3+ chars, optional spaces)
    if (line.match(/^(\s*[-*_]\s*){3,}$/)) {
      out.push('<hr class="md-hr">');
      i++;
      continue;
    }

    // Blockquote: > text (collect consecutive lines)
    if (line.match(/^&gt;\s?/)) {
      const quoteLines = [];
      while (i < lines.length && lines[i].match(/^&gt;\s?/)) {
        quoteLines.push(lines[i].replace(/^&gt;\s?/, ""));
        i++;
      }
      // Recursively render the blockquote content
      out.push(
        '<blockquote class="md-blockquote">' +
        renderMarkdown_inner(quoteLines.join("\n")) +
        "</blockquote>"
      );
      continue;
    }

    // Unordered list: - item or * item (collect consecutive)
    if (line.match(/^[\s]*[-*+]\s+/)) {
      const items = [];
      while (i < lines.length && lines[i].match(/^[\s]*[-*+]\s+/)) {
        items.push(lines[i].replace(/^[\s]*[-*+]\s+/, ""));
        i++;
      }
      out.push('<ul class="md-list">');
      for (const item of items) {
        out.push("<li>" + renderInline(item) + "</li>");
      }
      out.push("</ul>");
      continue;
    }

    // Ordered list: 1. item (collect consecutive)
    if (line.match(/^[\s]*\d+\.\s+/)) {
      const items = [];
      while (i < lines.length && lines[i].match(/^[\s]*\d+\.\s+/)) {
        items.push(lines[i].replace(/^[\s]*\d+\.\s+/, ""));
        i++;
      }
      out.push('<ol class="md-list">');
      for (const item of items) {
        out.push("<li>" + renderInline(item) + "</li>");
      }
      out.push("</ol>");
      continue;
    }

    // Empty line — paragraph break
    if (line.trim() === "") {
      i++;
      continue;
    }

    // Regular paragraph — collect consecutive non-empty, non-special lines
    const paraLines = [];
    while (i < lines.length) {
      const l = lines[i];
      if (l.trim() === "") break;
      if (l.match(/^`{3,}/)) break;
      if (l.match(/^#{1,6}\s+/)) break;
      if (l.match(/^&gt;\s?/)) break;
      if (l.match(/^[\s]*[-*+]\s+/) && paraLines.length > 0) break;
      if (l.match(/^[\s]*\d+\.\s+/) && paraLines.length > 0) break;
      if (l.match(/^(\s*[-*_]\s*){3,}$/)) break;
      paraLines.push(l);
      i++;
    }
    if (paraLines.length > 0) {
      out.push("<p>" + renderInline(paraLines.join("<br>")) + "</p>");
    }
  }

  return out.join("\n");
}

/**
 * Internal: render already-escaped markdown (for blockquote recursion).
 * Same as renderMarkdown but without the initial escapeHtml step.
 * @param {string} text
 * @returns {string}
 */
function renderMarkdown_inner(text) {
  if (!text) return "";
  text = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");

  const lines = text.split("\n");
  const out = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    if (line.match(/^`{3,}/)) {
      // fence is non-null: the if-guard above already matched the same pattern
      const fence = /** @type {RegExpMatchArray} */ (line.match(/^(`{3,})(.*)/));
      const lang = fence[2].trim();
      const fenceLen = fence[1].length;
      const codeLines = [];
      i++;
      while (i < lines.length) {
        if (lines[i].match(new RegExp("^`{" + fenceLen + ",}\\s*$"))) {
          i++;
          break;
        }
        codeLines.push(lines[i]);
        i++;
      }
      const langAttr = lang ? ' data-lang="' + escapeHtml(lang) + '"' : "";
      out.push(
        '<pre class="md-code-block"' + langAttr + "><code>" +
        codeLines.join("\n") +
        "</code></pre>"
      );
      continue;
    }

    const headingMatch = line.match(/^(#{1,6})\s+(.+)$/);
    if (headingMatch) {
      const level = headingMatch[1].length;
      out.push("<h" + level + ' class="md-heading">' + renderInline(headingMatch[2]) + "</h" + level + ">");
      i++;
      continue;
    }

    if (line.match(/^(\s*[-*_]\s*){3,}$/)) {
      out.push('<hr class="md-hr">');
      i++;
      continue;
    }

    if (line.match(/^&gt;\s?/)) {
      const quoteLines = [];
      while (i < lines.length && lines[i].match(/^&gt;\s?/)) {
        quoteLines.push(lines[i].replace(/^&gt;\s?/, ""));
        i++;
      }
      out.push('<blockquote class="md-blockquote">' + renderMarkdown_inner(quoteLines.join("\n")) + "</blockquote>");
      continue;
    }

    if (line.match(/^[\s]*[-*+]\s+/)) {
      const items = [];
      while (i < lines.length && lines[i].match(/^[\s]*[-*+]\s+/)) {
        items.push(lines[i].replace(/^[\s]*[-*+]\s+/, ""));
        i++;
      }
      out.push('<ul class="md-list">');
      for (const item of items) out.push("<li>" + renderInline(item) + "</li>");
      out.push("</ul>");
      continue;
    }

    if (line.match(/^[\s]*\d+\.\s+/)) {
      const items = [];
      while (i < lines.length && lines[i].match(/^[\s]*\d+\.\s+/)) {
        items.push(lines[i].replace(/^[\s]*\d+\.\s+/, ""));
        i++;
      }
      out.push('<ol class="md-list">');
      for (const item of items) out.push("<li>" + renderInline(item) + "</li>");
      out.push("</ol>");
      continue;
    }

    if (line.trim() === "") {
      i++;
      continue;
    }

    const paraLines = [];
    while (i < lines.length) {
      const l = lines[i];
      if (l.trim() === "") break;
      if (l.match(/^`{3,}/)) break;
      if (l.match(/^#{1,6}\s+/)) break;
      if (l.match(/^&gt;\s?/)) break;
      if (l.match(/^[\s]*[-*+]\s+/) && paraLines.length > 0) break;
      if (l.match(/^[\s]*\d+\.\s+/) && paraLines.length > 0) break;
      if (l.match(/^(\s*[-*_]\s*){3,}$/)) break;
      paraLines.push(l);
      i++;
    }
    if (paraLines.length > 0) {
      out.push("<p>" + renderInline(paraLines.join("<br>")) + "</p>");
    }
  }

  return out.join("\n");
}
