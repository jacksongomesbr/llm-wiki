# Changelog

All notable changes to LLM Wiki will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`/wiki-research <topic>`** — discover sources on the web and file them.
  Previously the skill could only ingest sources you had already found;
  `.raw/` had to be populated by hand. Three-round discovery (decompose into
  angles, rank and fetch, chase contradictions), source tiering that prefers
  primary documents, archival to `.raw/` with provenance, then handoff to the
  existing unmodified two-phase ingest.
- `scripts/archive-source.sh` — writes fetched content to
  `.raw/YYYY-MM-DD-{slug}.md` with provenance frontmatter and prints its
  SHA-256. This is what makes web sources idempotent: previously there was no
  way to hash fetched content, since `hash-files.sh` requires a path.
- `scripts/build-index.sh` — regenerates `index.md` and the staleness baseline
  deterministically. Index regeneration was previously LLM handwork on every
  ingest and save, at a token cost proportional to the whole wiki.
- `scripts/update-backlinks.sh` — maintains a generated `## Backlinks` section
  on every page, with `--check` for lint runs.
- `scripts/log-event.sh` and `.llm-wiki/log.md` — append-only chronological
  record of ingests, queries and lints, in the grep-friendly format the
  original LLM Wiki pattern describes.
- `tests/run-tests.sh` — 72 behavioural assertions, no external dependencies.
- CI now runs the test suite on both Ubuntu and macOS.

### Fixed

- **Orphan detection never reported anything.** `wiki/index.md` was a symlink
  to the generated index, which lists every page under "By Tag"; it was scanned
  as a link source, so every page appeared reachable. The symlink is gone and
  page enumeration now excludes non-regular files.
- **Only the last wikilink on a line was seen.** The extraction regex
  `.*\[\[\(...\)\]\].*` is greedy, so multi-link rows — which the schema
  mandates for evidence tables and "Related" lists — went almost entirely
  unchecked by both the broken-link and orphan checks.
- **`check-stale.sh` could never report "fresh".** Nothing ever wrote
  `cache/index-hash.txt`. `build-index.sh` now writes it, and `--store` records
  a baseline manually.
- **Hot cache was inert.** `session-stop.sh` overwrote it with a blank template
  on every session end, and `--with-hooks` never registered the end-of-session
  hook at all.
- **`--with-hooks` wrote an unrecognised hook shape.** Settings now use the
  `[{hooks: [{type, command}]}]` form Claude Code expects, and register
  `SessionEnd` (there is no `SessionStop` event).
- **`tags` was never validated.** `[ -z "$v" ] || [ "$v" = "[]" ] && [ "$f" != "tags" ]`
  parses as `(A||B) && C`, which is always false for `tags`.
- **Body text could parse as frontmatter.** A range `sed` re-triggers on every
  `---`, and a markdown horizontal rule is `---`.
- **`ci-local.sh` integration tests could not fail** — the failure flag was set
  inside a subshell the parent never read.
- **Banners printed literal `\033[1m`** in `quickstart.sh`, `uninstall.sh` and
  `ci-local.sh`; bash's `echo` does not interpret backslash escapes.
- **`install.sh --update` always failed** — it looked for `.git` inside the
  skill subdirectory rather than the repository root.
- **`Skill("llm-wiki")` did not resolve.** The skill registers as `wiki`, per
  its own frontmatter.
- `sha256sum` is not present on a stock macOS install; hashing now falls back
  to `shasum -a 256`.
- Pages in subdirectories such as `topics/` are no longer invisible to every
  lint script.
- `find_wiki_root` walks up from the current directory instead of only checking
  `./wiki`, so hooks and scripts work from a subdirectory.
- `review.json` is initialised with both `pending` and `resolved` arrays.
- ShellCheck now covers `quickstart.sh`, `scripts/` and `tests/`, which were
  excluded from both CI and the local runner.

### Changed

- **The skill is now English-only.** Every `English / 中文` dual heading has been
  removed from the templates, schema, workflows, hook output and generated
  files (index, log, hot cache, backlinks blocks). The `language` frontmatter
  field and its `en | zh | bilingual` enum are unchanged, and CJK detection
  during ingest still runs — page *content* can still be in any language, but
  the structural headings are English so pages stay comparable across a wiki.
  Existing pages with bilingual headings keep working; they are not rewritten.
- `setup-project.sh` no longer pastes instructions into your `CLAUDE.md` or
  adds it to `.gitignore`. It writes `WIKI.md` into the wiki and appends a
  single `@`-import line, so the file stays yours and the instructions stay
  updatable.

## [0.1.0] — 2026-05-03

### Added

- Initial release of LLM Wiki skill for Claude Code
- Two-phase source ingestion (`/wiki-ingest`) with SHA-256 idempotency
- Index-first knowledge retrieval (`/wiki-query`) for O(1) lookup
- Health check system (`/wiki-lint`) with quick (bash) and full (LLM) modes
- Answer-to-synthesis persistence (`/wiki-save`) for compounding knowledge
- D3.js knowledge graph visualization (`/wiki-graph`)
- Review queue processing (`/wiki-review`) for contradiction/quality management
- Wiki dashboard (`/wiki`)
- Bilingual support (en/zh/bilingual) with CJK auto-detection
- Session lifecycle hooks (start/stop) with hot-cache for context continuity
- Page templates for concept, article, person, and synthesis types
- Project setup script (`setup-project.sh`) with optional hooks configuration
- Wiki initialization script (`init-wiki.sh`)
- Global installation script (`install.sh`)
- Quickstart script (`quickstart.sh`) with demo content
- Uninstall script (`uninstall.sh`)
- Demo source files (Greek mythology)
- CI pipeline (ShellCheck + markdownlint + integration tests)
- Local CI runner (`scripts/ci-local.sh`)
- Community files (CoC, Contributing, Security, Support, PR/Issue templates)

### Fixed

- CI failures in initial workflow configuration
- Portability issues for non-Linux environments
