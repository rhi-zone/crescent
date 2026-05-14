import { defineConfig } from "vitepress";

// Vitepress runs the Vue template compiler over rendered markdown. Anything
// it sees as `{{ ... }}` (interpolation) or `<Foo>` (custom element) breaks
// the build — even when it's literal text. Docs here use `{{ char }}`,
// `Cdata<T>`, `$Newtype<T>` etc. as plain content.
//
// Two protections:
// 1. `markdown.html: false` — markdown-it escapes raw HTML in regular text, so
//    `<T>` in a heading becomes `&lt;T&gt;` instead of an unclosed tag.
// 2. Post-render hook — adds `v-pre` to every `<code>` and `<pre>` element so
//    Vue's compiler skips their content (covers `{{ }}` and `<T>` inside code).
function vPreCode(html: string): string {
  return html
    .replace(/<code(?![^>]*\bv-pre\b)([^>]*)>/g, "<code$1 v-pre>")
    .replace(/<pre(?![^>]*\bv-pre\b)([^>]*)>/g, "<pre$1 v-pre>");
}

export default defineConfig({
  title: "crescent",
  description: "An operating system in Lua. Zero-dependency, vendoring-first.",
  base: "/crescent/",
  markdown: {
    html: false,
    config: (md) => {
      const origRender = md.render.bind(md);
      md.render = (src: string, env?: unknown) => vPreCode(origRender(src, env));
    },
  },
});
