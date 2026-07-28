# /wiki-graph — Knowledge Graph Visualization

**Purpose**: Generate an interactive D3.js force-directed graph showing the wiki's page network.

**Invoked by**: `/wiki-graph` → SKILL.md routes here

---

## Procedure

### Step 1: Extract Graph Data

List all pages and extract node/edge data:

```bash
find "$WIKI_ROOT" -maxdepth 1 -name "*.md" ! -path "*/.llm-wiki/*" ! -name "index.md"
```

Build structure:

```json
{
  "nodes": [{"id": "slug", "title": "Display Title", "type": "note|concept|entity|project|area|synthesis", "class": "person|organization|tool|place|work|event|null", "status": "active|reference|someday|archived|stub", "language": "en|zh|bilingual", "tags": ["tag1"], "incomingLinks": N, "outgoingLinks": N}],
  "edges": [{"source": "page-a", "target": "page-b"}]
}
```

### Step 2: Compute Derived Metrics

- `incomingLinks`, `outgoingLinks`, `isOrphan`, `isHub` (outgoingLinks > 5), `centrality`

### Step 3: Write graph.json

Write to `$WIKI_ROOT/.llm-wiki/graph.json`.

### Step 4: Generate graph.html

Create a self-contained HTML file at `$WIKI_ROOT/.llm-wiki/graph.html` with:

- Dark-themed D3.js v7 force-directed graph. **Load D3 in this order:**
  1. If `$WIKI_ROOT/.llm-wiki/vendor/d3.v7.min.js` exists, inline it or link it
     relatively — the graph then works offline and pulls in no third-party code.
  2. Otherwise fall back to the CDN **with Subresource Integrity pinned**:

     ```html
     <script src="https://d3js.org/d3.v7.min.js"
             integrity="sha384-CjloA8y00+1SDAUkjs099PVfnY2KmDC2BZnws9kh8D/lX1s46w6EPhpXdqMfjK6i"
             crossorigin="anonymous"></script>
     ```

  Suggest `scripts/vendor-d3.sh` to the user when falling back: an unpinned
  CDN script in a file they open locally is arbitrary remote code execution,
  and the graph is useless without a network.
- Color-coded nodes by `type`: concept=#5b9bd5, note=#ed7d31, entity=#70ad47,
  synthesis=#ffc000, project=#c0504d, area=#8064a2
- Entities are additionally shaped by `class` (person=circle, organization=square,
  tool=triangle, place=diamond, work=hexagon, event=star), so the two axes of the
  model stay visible in the graph
- Node radius: `5 + min(incomingLinks, 15)` px
- Tooltips on hover: title, type, language, link counts, tags
- Draggable nodes, zoom/pan on SVG
- Legend for type colors
- Graph data embedded as inline JavaScript variable

### Step 5: Present

```
# Knowledge Graph
**Nodes:** {N} | **Edges:** {N} | **Orphans:** {N} | **Hubs:** {N}
Graph: wiki/.llm-wiki/graph.html | Data: wiki/.llm-wiki/graph.json
```

Offer to open with `xdg-open` or `open`.

---

## Edge Cases

- **Empty wiki**: "No pages to graph. Ingest sources first."
- **Single page**: Generate single-node graph; suggest adding more pages
- **>50 pages**: Offer tag filtering; warn about simulation performance
- **Stale graph.json**: Always regenerate from live data, never reuse
