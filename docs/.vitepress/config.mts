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
  base: "/",
  cleanUrls: true,
  markdown: {
    html: false,
    config: (md) => {
      const origRender = md.render.bind(md);
      md.render = (src: string, env?: unknown) => vPreCode(origRender(src, env));
    },
  },
  themeConfig: {
    nav: [
      { text: "Install", link: "/install" },
      { text: "Inventory", link: "/inventory" },
      { text: "Conventions", link: "/conventions" },
      { text: "GitHub", link: "https://github.com/rhi-zone/crescent" },
    ],
    sidebar: [
      {
        text: "Getting started",
        items: [
          { text: "Install", link: "/install" },
          { text: "Inventory", link: "/inventory" },
          { text: "Inventory summary", link: "/inventory_summary" },
          { text: "Batteries", link: "/batteries" },
          { text: "Conventions", link: "/conventions" },
          { text: "Ecosystem design", link: "/ecosystem-design" },
        ],
      },
      {
        text: "Type system",
        items: [
          { text: "Overview", link: "/type-system" },
          { text: "Syntax", link: "/type-syntax" },
          { text: "Typechecker v2", link: "/typechecker-v2" },
          { text: "Typechecker v3", link: "/typechecker-v3" },
          { text: "Reference", link: "/typechecker-reference" },
          { text: "Param semantics", link: "/typechecker-param-semantics" },
          { text: "Tag matrix", link: "/type-tag-matrix" },
          { text: "Soundness audit", link: "/soundness-audit" },
          { text: "Semantics", link: "/semantics" },
          { text: "FFI types", link: "/ffi-types" },
        ],
      },
      {
        text: "Packages & platform",
        items: [
          { text: "Package manager", link: "/pkg-design" },
          { text: "Versioning", link: "/pkg-versioning" },
          { text: "Platform", link: "/platform-design" },
          { text: "Stdlib design", link: "/stdlib-design" },
          { text: "Stdlib roadmap", link: "/stdlib-roadmap" },
          { text: "Native tiers", link: "/native-tiers" },
          { text: "Access control", link: "/access-control" },
        ],
      },
      {
        text: "Runtime & daemons",
        items: [
          { text: "Daemon design", link: "/daemon-design" },
          { text: "Daemon isolation", link: "/daemon-isolation" },
          { text: "Daemon transport", link: "/daemon-transport" },
          { text: "Exec API", link: "/exec-api-design" },
          { text: "Effects", link: "/effects" },
          { text: "Shell design", link: "/shell-design" },
          { text: "Agent design", link: "/agent-design" },
          { text: "Agent impl", link: "/agent-impl" },
          { text: "Conversation tree", link: "/conversation-tree" },
        ],
      },
      {
        text: "Testing",
        items: [
          { text: "Fuzz suite spec", link: "/fuzz-suite-spec" },
          { text: "Fuzz redesign", link: "/fuzz-redesign-spec" },
          { text: "Fuzz gaps", link: "/fuzz-gaps" },
        ],
      },
      {
        text: "UI & apps",
        items: [
          { text: "UI design", link: "/ui-design" },
          { text: "CSS design", link: "/css-design" },
          { text: "Library app", link: "/library-app-design" },
          { text: "Card app", link: "/card-app-design" },
          { text: "System dashboard", link: "/system_dashboard" },
          { text: "Dashboard primitives", link: "/system_dashboard_primitives" },
          { text: "FP design", link: "/fp-design" },
          { text: "Typeclass design", link: "/typeclass-design" },
        ],
      },
    ],
    socialLinks: [
      { icon: "github", link: "https://github.com/rhi-zone/crescent" },
    ],
    search: {
      provider: "local",
    },
  },
});
