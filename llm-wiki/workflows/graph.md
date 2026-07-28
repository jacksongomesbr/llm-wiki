# /wiki-graph — Knowledge Graph

**Purpose**: Generate an interactive graph of the wiki, with a detail panel.

**Invoked by**: `/wiki-graph` → SKILL.md routes here

---

## Design Rationale

`★ Insight ─────────────────────────────────────`

- The graph is **derived data**, like the index. It used to be hand-written by
  the LLM on every invocation, which made it non-deterministic, untestable,
  costly in proportion to wiki size, and free to disagree with the rest of the
  toolchain about what links to what. It is now a script plus a template.
- `build-graph.sh` reuses `extract_links` and the frontmatter helpers from
  `_utils.sh`, so the graph agrees with `build-index.sh` and `find-orphans.sh`
  **by construction**. The test suite asserts that agreement — three parsers
  disagreeing is exactly how this drifts.
- A hub is a page many others point **to**, not one that links out a lot. The
  latter is an index page. Hubs are `inDegree >= 5`.
`─────────────────────────────────────────────────`

---

## Procedure

### Step 1: Build

```bash
scripts/build-graph.sh "$WIKI_ROOT"
```

That is the whole operation. It writes:

- `$WIKI_ROOT/.llm-wiki/graph.json` — nodes, edges, degrees, components
- `$WIKI_ROOT/.llm-wiki/graph.html` — the interactive view

Options: `--quiet`, `--no-html` (data only).

**Do not hand-write either file.** To change how the graph looks or behaves,
edit `templates/graph.html` in the skill; the generated file is overwritten on
every build.

### Step 2: Offer to vendor D3

If the output reports `D3: CDN`, suggest:

```bash
scripts/vendor-d3.sh "$WIKI_ROOT"
```

An unpinned CDN script inside a file the user opens locally is remote code
execution in a trusted context, and the graph is useless without a network. The
CDN fallback is pinned with Subresource Integrity, but a local copy is better.

### Step 3: Present

```
# Knowledge Graph
**Pages:** {N} | **Links:** {N} | **Citations:** {N} | **Components:** {N}
Graph: {WIKI_ROOT}/.llm-wiki/graph.html
```

Offer to open it (`open` on macOS, `xdg-open` on Linux).

**Components is the number worth commenting on.** More than one means the wiki
has broken into islands with no path between them — usually a sign that a
topic was ingested without being cross-linked to anything already there.

---

## What the View Provides

| Feature | Notes |
|---------|-------|
| Colour by `type`, shape by `class` | The two model axes stay visible at once |
| Right panel | Graph stats; selected node's title, summary, frontmatter, backlinks, outlinks, sources |
| Search + type filters | Essential past ~40 nodes |
| Focus depth (0-3) | Dims everything beyond N hops from the selection |
| Citation layer | Toggles bibliography entries in as a second node layer |
| Pin / drag | Double-click pins; pinned positions survive a rebuild |
| Deep links | `graph.html#node=apple-inc` |
| Open page | Relative link to the actual `.md` |
| Light/dark | Follows the system, with a manual toggle |

Bibliography nodes are namespaced `bib:<citekey>` so they can never collide
with a page slug, and they appear only when the citation layer is on.

---

## Edge Cases

- **Empty wiki**: the script still writes a valid empty graph; say there is
  nothing to show and suggest ingesting a source.
- **Large wiki (>200 pages)**: the force simulation gets heavy. Suggest the type
  filters and focus depth rather than turning the graph off.
- **`prefers-reduced-motion`**: the view settles the simulation without
  animating; no action needed.
- **Stale graph**: always rebuild, never reuse `graph.json` as a source of
  truth for anything but pinned positions.
