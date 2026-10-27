<!-- From mattpocock/skills at 5beb35b, MIT. Modified: the report is saved only where the user says; colours moved from Tailwind's stone/slate/emerald/amber/red to ayu light semantic tokens, each paired with its ayu dark value, and Mermaid themed from those tokens. -->

# HTML Report Format

The architectural review is rendered as a single self-contained HTML file, saved where the user says (the OS temp directory is the default to suggest). Tailwind and Mermaid both come from CDNs. Mermaid handles graph-shaped diagrams reliably; hand-built divs and inline SVG handle the more editorial visuals (mass diagrams, cross-sections). Mix the two: don't lean on Mermaid for everything, it'll start to look generic.

Colour comes only from the semantic tokens in the scaffold. Each token's light value is from ayu light and its dark value, under `prefers-color-scheme: dark`, is from ayu dark.

## Scaffold

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Architecture review for {{repo name}}</title>
    <style>
      /* Semantic tokens: ayu light, each paired with its ayu dark value below. */
      :root {
        color-scheme: light dark;
        --page: #f8f9fa;
        --surface: #fcfcfc;
        --ink: #5c6166;
        --muted: #8a9199;
        --line: #6b7d8f1f;
        --accent: #399ee6;
        --strong: #86b300;
        --warn: #f2ae49;
        --leak: #e65050;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --page: #0b0e14;
          --surface: #0d1017;
          --ink: #bfbdb6;
          --muted: #6c7380;
          --line: #47526640;
          --accent: #59c2ff;
          --strong: #aad94c;
          --warn: #ffb454;
          --leak: #d95757;
        }
      }
      /* small custom layer for things Tailwind doesn't cover cleanly:
         dashed seam lines, hand-drawn-feeling arrow heads, tinted badges, etc. */
      .seam { stroke-dasharray: 4 4; }
      .leak { stroke: var(--leak); }
      .deep { background: var(--ink); color: var(--surface); }
      .badge { border: 1px solid var(--tone); background: color-mix(in srgb, var(--tone) 18%, var(--surface)); color: var(--ink); }
      .badge-strong { --tone: var(--strong); }
      .badge-explore { --tone: var(--warn); }
      .badge-speculative { --tone: var(--muted); }
      .callout-warn { border-left: 4px solid var(--warn); background: color-mix(in srgb, var(--warn) 14%, var(--surface)); }
    </style>
    <script src="https://cdn.tailwindcss.com"></script>
    <script>
      // Tailwind colour names point at the tokens: bg-page, bg-surface, text-ink, border-line, text-leak.
      tailwind.config = {
        theme: {
          extend: {
            colors: {
              page: "var(--page)",
              surface: "var(--surface)",
              ink: "var(--ink)",
              muted: "var(--muted)",
              line: "var(--line)",
              accent: "var(--accent)",
              strong: "var(--strong)",
              warn: "var(--warn)",
              leak: "var(--leak)",
            },
          },
        },
      };
    </script>
    <script type="module">
      import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
      // Mermaid derives its shades from hex values, so hand it the tokens resolved for the current mode.
      const token = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
      // Mermaid's parser rejects parentheses in classDef, so swap each var(--name) in a diagram for its value first.
      for (const el of document.querySelectorAll("pre.mermaid")) {
        el.textContent = el.textContent.replace(/var\((--[\w-]+)\)/g, (_, name) => token(name));
      }
      mermaid.initialize({
        startOnLoad: false,
        theme: "base",
        securityLevel: "loose",
        themeVariables: {
          background: token("--surface"),
          primaryColor: token("--surface"),
          primaryTextColor: token("--ink"),
          primaryBorderColor: token("--muted"),
          lineColor: token("--muted"),
          textColor: token("--ink"),
        },
      });
      await mermaid.run();
    </script>
  </head>
  <body class="bg-page text-ink font-sans">
    <main class="max-w-5xl mx-auto px-6 py-12 space-y-12">
      <header>...</header>
      <section id="candidates" class="space-y-10">...</section>
      <section id="top-recommendation">...</section>
    </main>
  </body>
</html>
```

## Header

Repo name, date, and a compact legend: solid box = module, dashed line = seam, red arrow = leakage, thick filled box = deep module. No introduction paragraph. Straight into the candidates.

## Candidate card

The diagrams carry the weight. Prose is sparse, plain, and uses the glossary terms (from the `/codebase-design` skill) without ceremony.

Each candidate is one `<article>`:

- **Title**: short, names the deepening (e.g. "Collapse the Order intake pipeline").
- **Badge row**: recommendation strength as a `badge` (`Strong` = `badge-strong`, ayu green; `Worth exploring` = `badge-explore`, ayu yellow; `Speculative` = `badge-speculative`, ayu grey), plus a tag for the dependency category (`in-process`, `local-substitutable`, `ports & adapters`, `mock`).
- **Files**: monospaced list, `font-mono text-sm`.
- **Before / After diagram**: the centrepiece. Two columns, side by side. See patterns below.
- **Problem**: one sentence. What hurts.
- **Solution**: one sentence. What changes.
- **Wins**: bullets, ≤6 words each. e.g. "Tests hit one interface", "Pricing logic stops leaking", "Delete 4 shallow wrappers".
- **ADR callout** (if applicable): one line in a `callout-warn` box.

No paragraphs of explanation. If the diagram needs a paragraph to be understood, redraw the diagram.

## Diagram patterns

Pick the pattern that fits the candidate. Mix them. Don't make every diagram look the same. Variety is part of the point.

### Mermaid graph (the workhorse for dependencies / call flow)

Use a Mermaid `flowchart` or `graph` when the point is "X calls Y calls Z, and look at the mess." Wrap it in a Tailwind-styled card so it doesn't feel parachuted in. Style with classDef, pointing at the tokens (`var(--leak)`, `var(--ink)`, which the scaffold swaps for their values before Mermaid parses the diagram), to colour leakage edges red and the deep module heavy. Sequence diagrams work well for "before: 6 round-trips; after: 1."

```html
<div class="rounded-lg border border-line bg-surface p-4">
  <pre class="mermaid">
    flowchart LR
      A[OrderHandler] --> B[OrderValidator]
      B --> C[OrderRepo]
      C -.leak.-> D[PricingClient]
      classDef leak stroke:var(--leak),stroke-width:2px;
      class C,D leak
  </pre>
</div>
```

### Hand-built boxes-and-arrows (when Mermaid's layout fights you)

Modules as `<div>`s with borders and labels. Arrows as inline SVG `<line>` or `<path>` elements positioned absolutely over a relative container. Reach for this when you want the "after" diagram to feel like one thick-bordered deep module with greyed-out internals, since Mermaid won't render that with the right weight.

### Cross-section (good for layered shallowness)

Stack horizontal bands (`h-12 border-l-4`) to show layers a call passes through. Before: 6 thin layers each doing nothing. After: 1 thick band labelled with the consolidated responsibility.

### Mass diagram (good for "interface as wide as implementation")

Two rectangles per module: one for interface surface area, one for implementation. Before: interface rectangle is nearly as tall as the implementation rectangle (shallow). After: interface rectangle is short, implementation rectangle is tall (deep).

### Call-graph collapse

Before: a tree of function calls rendered as nested boxes. After: the same tree collapsed into one box, with the now-internal calls shown faded inside it.

## Style guidance

- Lean editorial, not corporate-dashboard. Generous whitespace. Serif optional for headings (`font-serif` works well on the ayu page).
- Colour sparingly: one accent (`accent`, ayu blue) plus `leak` (ayu red) for leakage and `warn` (ayu yellow) for warnings.
- Every colour is a token with both values: ayu light in `:root`, ayu dark in the `prefers-color-scheme: dark` block. A new colour gets a new token in both blocks; hex values live only there. Keep the tokens Mermaid reads (`--surface`, `--ink`, `--muted`) as plain six-digit hex, since Mermaid derives shades from them.
- Keep diagrams ~320px tall so before/after sits comfortably side by side without scrolling.
- Use `text-xs uppercase tracking-wider` for module labels inside diagrams, so they read as schematic, not as UI.
- The only scripts are the Tailwind CDN with its token config and the Mermaid ESM import. The report is otherwise static: no app code, no interactivity beyond Mermaid's own rendering.

## Top recommendation section

One larger card. Candidate name, one sentence on why, anchor link to its card. That's it.

## Tone

Plain English, concise, but the architectural nouns and verbs come straight from the `/codebase-design` skill. Concision is not an excuse to drift.

**Use exactly:** module, interface, implementation, depth, deep, shallow, seam, adapter, leverage, locality.

**Never substitute:** component, service, unit (for module) · API, signature (for interface) · boundary (for seam) · layer, wrapper (for module, when you mean module).

**Phrasings that fit the style:**

- "Order intake module is shallow: interface nearly matches the implementation."
- "Pricing leaks across the seam."
- "Deepen: one interface, one place to test."
- "Two adapters justify the seam: HTTP in prod, in-memory in tests."

**Wins bullets** name the gain in glossary terms: *"locality: bugs concentrate in one module"*, *"leverage: one interface, N call sites"*, *"interface shrinks; implementation absorbs the wrappers"*. Don't write *"easier to maintain"* or *"cleaner code"*, because those terms aren't in the glossary and don't earn their place.

No hedging, no throat-clearing, no "it's worth noting that…". If a sentence could be a bullet, make it a bullet. If a bullet could be cut, cut it. If a term isn't in the `/codebase-design` glossary, reach for one that is before inventing a new one.
